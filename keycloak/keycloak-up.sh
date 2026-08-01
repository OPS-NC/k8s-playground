#!/usr/bin/env bash
#
# keycloak-up.sh — installe Keycloak par son OPÉRATEUR (CRD `Keycloak`), avec une base
# PostgreSQL CloudNativePG, et expose la console + les endpoints OIDC en HTTPS sous
# keycloak.$LAB_DOMAIN via main-gateway.
#
#   ./keycloak/keycloak-up.sh <talos|kubeadm>   (ou ./install.sh <distro> keycloak)
#
# Addon à part : platform-up.sh ne pose que le CNI + Envoy + metrics + le wildcard TLS.
#
# POURQUOI L'OPÉRATEUR ET PAS UN CHART. Le chart Bitnami déploie un StatefulSet et vous
# laisse avec : la génération du keystore, les options de proxy, la migration de schéma à
# chaque montée de version, le cache Infinispan. L'opérateur, lui, prend un objet
# `Keycloak` de trente lignes et en dérive tout — et il tient la promesse qui compte ici :
# un realm DÉCLARÉ (`KeycloakRealmImport`) que l'on peut versionner, donc reproduire.
# C'est aussi ce qui permet à `../dex/` de déclarer son client OIDC avec un CR au lieu
# d'un script `kcadm.sh`.
#
# Ordre :
#   1. namespace + base PostgreSQL CNPG   (Keycloak ne démarre pas sans base)
#   2. opérateur Keycloak                 (4 CRD + RBAC + Deployment)
#   3. CR Keycloak                        (l'opérateur en dérive StatefulSet + Service)
#   4. realm `lab`                        (CRD KeycloakRealmImport)
#   5. HTTPRoute keycloak.$LAB_DOMAIN
#
# Aucune spécificité de distribution : les pods sont ordinaires (pas de hostPath, pas de
# hostNetwork, pas de privilège), donc conformes au `baseline` que Talos applique au
# niveau cluster — le namespace n'a pas besoin d'être étiqueté `privileged`.
#
# Prérequis : plateforme en place (main-gateway HTTPS + wildcard), Longhorn (SC
#             `longhorn-r1`), opérateur CloudNativePG, openssl.
# Idempotent : `kubectl apply` partout, et le Secret du mot de passe de démo n'est généré
# que s'il n'existe pas. Relançable sans casse.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Version épinglée (overridable par variable d'env) ----------------------
# Une seule version pour tout : les manifestes de l'opérateur portent l'image du
# serveur (`RELATED_IMAGE_KEYCLOAK`), donc opérateur et serveur avancent ensemble.
KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-26.7.0}"
NS="${NS:-keycloak}"
BASE_URL="https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes"

# --- Pré-requis -------------------------------------------------------------
need kubectl openssl
require_apiserver
# La base vit sur la SC socle des bases de ce dépôt.
require_sc longhorn-r1
# L'opérateur CloudNativePG est un composant à part : sans lui, le `Cluster` posé plus
# bas est un objet inerte que personne ne reconcilie, et Keycloak attend une base qui
# n'arrivera jamais.
kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 \
  || fail "l'opérateur CloudNativePG est absent (CRD clusters.postgresql.cnpg.io).
        Installe-le d'abord :  ./install.sh ${K8S_DISTRO} cnpg"

# ============================================================================
log "[1/5] Namespace ${NS} + base PostgreSQL CloudNativePG"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${HERE}/01-postgres.yaml"
echo "    attente du cluster keycloak-db (initdb + premier démarrage)..."
kubectl -n "$NS" wait --for=condition=Ready cluster/keycloak-db --timeout=300s

# ============================================================================
log "[2/5] Opérateur Keycloak ${KEYCLOAK_VERSION} (CRD + RBAC + Deployment)"
# `--server-side` n'est PAS une coquetterie : la CRD `keycloaks` fait plus de 500 Kio, et
# un `kubectl apply` classique la recopie dans l'annotation
# `kubectl.kubernetes.io/last-applied-configuration` — plafonnée à 262 144 octets par
# l'apiserver. L'apply côté client échoue donc avec « metadata.annotations: Too long ».
# L'apply côté serveur ne pose pas cette annotation.
for crd in keycloaks keycloakrealmimports keycloakoidcclients keycloaksamlclients; do
  kubectl apply --server-side -f "${BASE_URL}/${crd}.k8s.keycloak.org-v1.yml"
done
# Les quatre CRD sont posées même si ce composant n'en utilise que deux : l'opérateur
# démarre un contrôleur par CRD et son informer plante en boucle si l'une manque.
kubectl wait --for=condition=Established crd/keycloaks.k8s.keycloak.org --timeout=60s

# `kubernetes.yml` ne porte pas de namespace sur ses objets namespacés, mais son
# ClusterRoleBinding désigne le ServiceAccount `keycloak-operator` du namespace
# `keycloak` EN DUR : installer l'opérateur ailleurs le laisserait sans droits.
kubectl apply -n "$NS" -f "${BASE_URL}/kubernetes.yml"
kubectl -n "$NS" rollout status deploy/keycloak-operator --timeout=300s

# ============================================================================
log "[3/5] CR Keycloak (l'opérateur en dérive StatefulSet, Service et configuration)"
# Le manifeste versionné porte le domaine neutre : substitué à la volée, comme partout
# ailleurs dans k8s-playground/ (cf. ../README.md).
render "${HERE}/02-keycloak.yaml" | kubectl apply -f -
echo "    attente de Keycloak (migration du schéma au premier démarrage : ~2 min)..."
# La condition `Ready` du CR n'apparaît qu'une fois le StatefulSet déroulé ET le serveur
# joignable. `|| true` : on préfère continuer et laisser le résumé final dire la vérité
# plutôt que planter sur un timeout, la suite étant de toute façon rejouable.
kubectl -n "$NS" wait --for=condition=Ready keycloak/keycloak --timeout=600s || true

# ============================================================================
log "[4/5] Realm 'lab' (KeycloakRealmImport) + utilisateur de démonstration"
# Le mot de passe est généré UNE FOIS et ne quitte jamais le cluster. `get || create` et
# non `create --dry-run | apply` : ce dernier régénérerait le mot de passe à chaque
# passage, alors que le realm, lui, a déjà importé l'ancien — l'utilisateur `demo` ne
# pourrait plus se connecter et rien ne le dirait.
if kubectl -n "$NS" get secret keycloak-demo-user >/dev/null 2>&1; then
  echo "    Secret keycloak-demo-user déjà présent — on ne le régénère pas."
else
  kubectl -n "$NS" create secret generic keycloak-demo-user \
    --from-literal=password="$(openssl rand -base64 18)"
  echo "    Secret keycloak-demo-user créé (mot de passe aléatoire, jamais affiché)."
fi
render "${HERE}/03-realm-lab.yaml" | kubectl apply -f -
echo "    attente du Job d'import..."
kubectl -n "$NS" wait --for=condition=Done keycloakrealmimport/lab --timeout=300s || true

# ============================================================================
log "[5/5] HTTPRoute keycloak.${LAB_DOMAIN}"
render "${HERE}/httproute.yaml" | kubectl apply -f -

# ============================================================================
log "Keycloak installé."
echo "  Console admin : https://keycloak.${LAB_DOMAIN}/admin/"
echo "  Compte admin  : kubectl -n ${NS} get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d ; echo"
echo "                  kubectl -n ${NS} get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d ; echo"
echo "  Realm         : lab   —   https://keycloak.${LAB_DOMAIN}/realms/lab"
echo "  Découverte    : curl -s https://keycloak.${LAB_DOMAIN}/realms/lab/.well-known/openid-configuration | jq .issuer"
echo "  Utilisateur   : demo  (groupe k8s-admins)"
echo "                  kubectl -n ${NS} get secret keycloak-demo-user -o jsonpath='{.data.password}' | base64 -d ; echo"
echo "  Base          : kubectl -n ${NS} get cluster keycloak-db"
echo
echo "  /!\\ Le compte 'keycloak-initial-admin' est un admin COMPLET, en clair dans un"
echo "      Secret. Crée ton propre admin dans le realm master, puis supprime-le :"
echo "      kubectl -n ${NS} delete secret keycloak-initial-admin"
echo
echo "  Suite logique : ./install.sh ${K8S_DISTRO} dex   (connexion kubectl par OIDC)"
