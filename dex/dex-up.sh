#!/usr/bin/env bash
#
# dex-up.sh — installe Dex en broker OIDC devant Keycloak, et prépare la connexion
# `kubectl` par OIDC (kubelogin / `kubectl oidc-login`).
#
#   ./dex/dex-up.sh <talos|kubeadm>     (ou ./install.sh <distro> dex)
#
# Addon à part : platform-up.sh ne pose que le CNI + Envoy + metrics + le wildcard TLS.
# Prérequis : ../keycloak/ installé (realm `lab`), plateforme en place.
#
# POURQUOI DEX ALORS QUE KEYCLOAK EST DÉJÀ UN ÉMETTEUR OIDC. Le serveur d'API ne sait
# parler qu'à UN émetteur, figé dans sa ligne de commande, et changer cette valeur
# redémarre le control plane. Dex est le point d'indirection : l'apiserver ne connaît que
# `https://dex.$LAB_DOMAIN`, et tout ce qui bouge (ajouter un annuaire, changer de realm,
# faire tourner un secret de client) se fait dans un ConfigMap Dex, sans jamais toucher au
# control plane. C'est aussi ce que fait un cluster managé (EKS/GKE) derrière son SSO.
#
# ⚠️ CE SCRIPT NE TOUCHE PAS AU SERVEUR D'API. Le brancher sur Dex est une opération de
#    CONTROL PLANE : elle le redémarre, et un `oidc-issuer-url` injoignable l'empêche de
#    redémarrer — cluster inadministrable. Un addon n'a pas à faire ça en douce. Le script
#    affiche donc, en dernière étape, les commandes exactes pour la distribution détectée
#    (elles viennent du profil : `talosctl patch mc` sur Talos, ConfigMap `kubeadm-config`
#    + `kubeadm init phase` sur kubeadm). Rien d'autre du composant n'en dépend : Dex,
#    son client Keycloak et le RBAC s'installent et se testent sans.
#
# Ordre :
#   1. namespace + secrets de client (générés, jamais versionnés)
#   2. client OIDC `dex` DANS Keycloak (CRD KeycloakOIDCClient)
#   3. chart Dex (connecteur vers le realm `lab`, client statique `kubernetes`)
#   4. HTTPRoute dex.$LAB_DOMAIN + liaisons RBAC des groupes
#   5. ce qu'il reste à faire à la main : câbler l'apiserver, puis le kubeconfig
#
# Idempotent : `helm upgrade --install` + `kubectl apply`, et les secrets de client ne
# sont générés que s'ils n'existent pas — les régénérer casserait le client déjà créé
# côté Keycloak sans que rien ne le dise.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Versions épinglées (overridables par variable d'env) -------------------
DEX_VERSION="${DEX_VERSION:-0.24.1}"       # app v2.44.0
NS="${NS:-dex}"
KC_NS="${KC_NS:-keycloak}"
REALM="${REALM:-lab}"

# --- Pré-requis -------------------------------------------------------------
need kubectl helm openssl
require_apiserver
kubectl get crd keycloakoidcclients.k8s.keycloak.org >/dev/null 2>&1 \
  || fail "l'opérateur Keycloak est absent (CRD keycloakoidcclients.k8s.keycloak.org).
        Installe-le d'abord :  ./install.sh ${K8S_DISTRO} keycloak"
kubectl -n "$KC_NS" get keycloak keycloak >/dev/null 2>&1 \
  || fail "aucun CR Keycloak nommé 'keycloak' dans le namespace ${KC_NS}.
        Installe-le d'abord :  ./install.sh ${K8S_DISTRO} keycloak"

# ============================================================================
log "[1/5] Namespace ${NS} + secrets des clients OIDC"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Le secret du client `dex` est partagé entre DEUX namespaces : Keycloak le lit dans
# `keycloak` (le CR KeycloakOIDCClient y vit), Dex le lit dans `dex`. Un Secret ne
# franchit pas les namespaces — on en pose donc deux copies de la MÊME valeur.
# La valeur de référence est celle du namespace keycloak : c'est elle que l'opérateur a
# déjà poussée dans le realm, la régénérer invaliderait le client sans erreur visible.
if kubectl -n "$KC_NS" get secret dex-keycloak-client >/dev/null 2>&1; then
  echo "    secret du client 'dex' déjà présent dans ${KC_NS} — réutilisé tel quel."
  KC_CLIENT_SECRET="$(kubectl -n "$KC_NS" get secret dex-keycloak-client \
    -o jsonpath='{.data.client-secret}' | base64 -d)"
else
  KC_CLIENT_SECRET="$(openssl rand -hex 32)"
  kubectl -n "$KC_NS" create secret generic dex-keycloak-client \
    --from-literal=client-secret="$KC_CLIENT_SECRET"
  echo "    secret du client 'dex' généré (32 octets, jamais affiché)."
fi
# `apply` et non `create` : la copie doit converger vers la référence à chaque passage.
kubectl -n "$NS" create secret generic dex-keycloak-client \
  --from-literal=client-secret="$KC_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

# Secret du client `kubernetes` : celui que portera TON kubeconfig. Il n'a rien de
# confidentiel au sens strict (RFC 8252 : une application native ne peut pas garder un
# secret), mais Dex exige un client statique complet.
if kubectl -n "$NS" get secret dex-kubernetes-client >/dev/null 2>&1; then
  echo "    secret du client 'kubernetes' déjà présent — réutilisé tel quel."
else
  kubectl -n "$NS" create secret generic dex-kubernetes-client \
    --from-literal=client-secret="$(openssl rand -hex 32)"
  echo "    secret du client 'kubernetes' généré."
fi

# ============================================================================
log "[2/5] Client OIDC 'dex' dans le realm ${REALM} (CRD KeycloakOIDCClient)"
# Le manifeste versionné porte le domaine neutre : substitué à la volée, comme partout
# ailleurs dans k8s-playground/ (cf. ../README.md).
render "${HERE}/01-keycloak-client.yaml" | kubectl apply -f -
# La condition `Ready` n'apparaît qu'une fois le client réellement créé côté Keycloak.
# `|| true` : le résumé final dit la vérité, et l'objet est reconcilié en continu.
kubectl -n "$KC_NS" wait --for=condition=Ready keycloakoidcclient/dex --timeout=180s || true

# ============================================================================
log "[3/5] Chart Dex ${DEX_VERSION} (connecteur vers keycloak.${LAB_DOMAIN})"
helm repo add dex https://charts.dexidp.io >/dev/null 2>&1 || true
helm repo update dex >/dev/null
# values.yaml porte les deux URL publiques (issuer Dex + issuer du realm) : rendu dans un
# temporaire, le fichier versionné n'est jamais réécrit.
VALUES="$(mktemp)"; trap 'rm -f "$VALUES"' EXIT
render "${HERE}/values.yaml" > "$VALUES"
helm upgrade --install dex dex/dex -n "$NS" \
  --version "${DEX_VERSION}" --values "$VALUES"
kubectl -n "$NS" rollout status deploy/dex --timeout=300s

# ============================================================================
log "[4/5] HTTPRoute dex.${LAB_DOMAIN} + liaisons RBAC des groupes"
render "${HERE}/httproute.yaml" | kubectl apply -f -
# rbac.yaml ne porte aucun domaine : appliqué tel quel.
kubectl apply -f "${HERE}/rbac.yaml"

# ============================================================================
log "[5/5] Ce qu'il reste à faire — câbler le serveur d'API sur Dex"
echo "    Mécanisme ${K8S_DISTRO} : ${APISERVER_OIDC_MECHANISM}"
echo "    Patch fourni            : dex/${APISERVER_OIDC_PATCH}"
echo
echo "    /!\\ Ces commandes REDÉMARRENT le serveur d'API. Un émetteur injoignable"
echo "        l'empêche de redémarrer. Un control plane à la fois, en vérifiant entre"
echo "        chaque. Détails et cas SELF_SIGNED=true : dex/README.md."
echo
apiserver_oidc_commands "${HERE}/${APISERVER_OIDC_PATCH}"

# ============================================================================
log "Dex installé."
echo "  Émetteur     : https://dex.${LAB_DOMAIN}"
echo "  Découverte   : curl -s https://dex.${LAB_DOMAIN}/.well-known/openid-configuration | jq .issuer"
echo "  Amont        : https://keycloak.${LAB_DOMAIN}/realms/${REALM}  (client 'dex')"
echo "  Groupes      : oidc:k8s-admins -> cluster-admin · oidc:k8s-viewers -> view"
echo
echo "  Une fois l'apiserver câblé, le contexte kubectl (kubelogin requis) :"
echo "    kubectl config set-credentials oidc \\"
echo "      --exec-api-version=client.authentication.k8s.io/v1beta1 \\"
echo "      --exec-command=kubectl \\"
echo "      --exec-arg=oidc-login --exec-arg=get-token \\"
echo "      --exec-arg=--oidc-issuer-url=https://dex.${LAB_DOMAIN} \\"
echo "      --exec-arg=--oidc-client-id=kubernetes \\"
echo "      --exec-arg=--oidc-client-secret=\$(kubectl -n ${NS} get secret dex-kubernetes-client -o jsonpath='{.data.client-secret}' | base64 -d) \\"
echo "      --exec-arg=--oidc-extra-scope=groups --exec-arg=--oidc-extra-scope=email"
echo "    kubectl config set-context oidc --cluster=<ton-cluster> --user=oidc"
echo "    kubectl --context=oidc get nodes        # ouvre un navigateur : Keycloak, user 'demo'"
