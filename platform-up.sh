#!/usr/bin/env bash
#
# platform-up.sh — installe la couche « plateforme » sur un cluster DÉJÀ bootstrapé, que
# celui-ci vienne du lab Talos ou du lab kubeadm.
#
#   ./platform-up.sh <talos|kubeadm>          (ou ./install.sh <distro> platform)
#
# ⚠️ Aucun des deux labs ne pose de réseau pod utilisable AVANT cette couche :
#    - kubeadm : `kubeadm init` n'installe AUCUN CNI, les nodes restent NotReady jusqu'à
#      l'étape [1/4] ;
#    - Talos   : avec CNI=cilium/calico, le bootstrap met `cni.name: none` — même situation.
#      (Seul CNI=flannel est déjà posé par Talos au bootstrap : l'étape [1/4] ne fait alors
#      rien, cf. FLANNEL_PRE_INSTALLED dans lib/profiles/talos.sh.)
#
# Ordre (chaque maillon suppose le précédent) :
#   1. CNI                 selon `CNI` (cluster.env, puis lab.env) — cilium (défaut,
#                          + pool L2 => IP LB), calico (CNI seul), flannel (CNI seul), none
#   2. Envoy Gateway       contrôleur + CRD Gateway API + main-gateway (HTTP/HTTPS)
#   3. metrics-server      metrics.k8s.io (kubectl top)
#   4. wildcard TLS        selon `SELF_SIGNED` de lab.env :
#                          true  -> AC locale + cert openssl (self-signed/), PAS de cert-manager
#                          false -> cert-manager + secret Cloudflare + ClusterIssuers (ACME)
#                          Les deux chemins remplissent le MÊME Secret que sert la Gateway.
#
# EXCLUS volontairement (à installer à part, chacun son README + up.sh) :
#   argocd/ · longhorn/ · vault-cluster/ · vault-secret-operator/ · kyverno/ ·
#   trivy-operator/ · cloudnative-pg/ · observability/ · minio-s3/ · chaos-kube/
#
# Domaine : les manifestes versionnés portent le domaine NEUTRE `lab.example.io` (dépôt
# public). Il est remplacé à la volée par `LAB_DOMAIN` (env ou lab.env ; défaut
# `<distro>.lab.example.io`) — idem `LAB_DNS_ZONE` (zone du solveur DNS-01),
# `LAB_ACME_EMAIL` (compte Let's Encrypt) et `LAB_ACME_ISSUER` (staging par défaut / prod
# sur demande). Ces trois dernières ne servent QUE sur le chemin ACME (SELF_SIGNED=false).
#
# Idempotent : `helm upgrade --install` + `kubectl apply`. Relançable sans casse.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${HERE}/lib/common.sh"
k8s_init "$@"

# --- Versions épinglées (overridables par variable d'env) -------------------
ENVOY_GW_VERSION="${ENVOY_GW_VERSION:-1.8.3}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.1}"

# Garde-fou kubeadm : sans `_out/cluster.env`, on retombe sur des valeurs DEVINÉES. Mieux
# vaut le dire ici que laisser Cilium s'épingler sur la mauvaise carte réseau trois étapes
# plus loin. Non bloquant : un cluster monté à la main reste utilisable via lab.env.
# (Sur Talos ce fichier n'existe pas : les faits se lisent dans _out/controlplane.yaml.)
if [ "$K8S_DISTRO" = "kubeadm" ] && [ ! -f "$CLUSTER_ENV_FILE" ]; then
  warn "${CLUSTER_ENV_FILE} absent : ./kubeadm/cluster-up.sh n'a pas (ou pas jusqu'au bout)
    été lancé. On continue avec lab.env et les défauts, mais l'interface host-only, le
    CIDR pod et le choix kube-proxy ne sont alors PAS vérifiés."
fi

CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-$(lire_lab_env CLOUDFLARE_API_TOKEN)}"

# Zone DNS Cloudflare hébergeant LAB_DOMAIN (selector `dnsZones` du ClusterIssuer) :
# par défaut les deux derniers labels (talos.lab.example.io -> example.io).
LAB_DNS_ZONE="${LAB_DNS_ZONE:-$(lire_lab_env LAB_DNS_ZONE)}"
LAB_DNS_ZONE="${LAB_DNS_ZONE:-$(printf '%s\n' "$LAB_DOMAIN" | awk -F. '{ print (NF>1) ? $(NF-1)"."$NF : $NF }')}"
# E-mail du compte ACME (Let's Encrypt refuse certains domaines d'exemple).
LAB_ACME_EMAIL="${LAB_ACME_EMAIL:-$(lire_lab_env LAB_ACME_EMAIL)}"
LAB_ACME_EMAIL="${LAB_ACME_EMAIL:-admin@${LAB_DNS_ZONE}}"

# --- Mode TLS : auto-signé (défaut) ou cert-manager + Let's Encrypt ----------
# Le défaut versionné est un domaine d'exemple : sans domaine RÉEL et sans token
# Cloudflare, le chemin ACME ne peut de toute façon rien émettre et le lab reste sans TLS.
# L'auto-signé, lui, marche partout et hors-ligne — c'est donc le bon défaut « ça démarre ».
SELF_SIGNED="${SELF_SIGNED:-$(lire_lab_env SELF_SIGNED)}"
SELF_SIGNED="${SELF_SIGNED:-true}"
SELF_SIGNED="$(printf '%s' "$SELF_SIGNED" | tr '[:upper:]' '[:lower:]')"
case "$SELF_SIGNED" in
  true|false) ;;
  *) fail "SELF_SIGNED='${SELF_SIGNED}' inconnu (true|false)." ;;
esac

# --- Émetteur ACME : staging par défaut, production sur demande --------------
# (ignoré quand SELF_SIGNED=true : aucun ACME n'entre en jeu)
# Le wildcard ne vit QUE dans etcd : détruire le lab le détruit, et le rebuild en redemande
# un neuf. Or Let's Encrypt PRODUCTION plafonne à 5 certificats par semaine pour un même jeu
# d'identifiants (`*.<LAB_DOMAIN>`) — un lab jetable épuise ce quota en 5 rebuilds, puis se
# retrouve sans TLS pendant des heures (erreur 429). Le staging a un quota ~30 000/semaine.
LAB_ACME_ISSUER="${LAB_ACME_ISSUER:-$(lire_lab_env LAB_ACME_ISSUER)}"
LAB_ACME_ISSUER="${LAB_ACME_ISSUER:-staging}"
case "$LAB_ACME_ISSUER" in
  staging|prod) ;;
  *) fail "LAB_ACME_ISSUER='${LAB_ACME_ISSUER}' inconnu (staging|prod)." ;;
esac
ACME_ISSUER="letsencrypt-${LAB_ACME_ISSUER}"

# --- CNI : qui pose le réseau, et est-ce qu'on aura une IP LoadBalancer ? -----
#   cilium  -> Cilium + son pool L2 (annonce ARP)                         => IP LB ✅
#   calico  -> Calico via l'opérateur Tigera (CNI seul)                   => IP LB ❌
#   flannel -> flannel (CNI seul) — DÉJÀ posé au bootstrap sur Talos      => IP LB ❌
#   none    -> personne ne pose de CNI, c'est à toi                       => IP LB ❌
CNI="$(lire_param CNI cilium)"
case "$CNI" in
  cilium|calico|flannel|none) ;;
  *) fail "CNI='${CNI}' inconnu (cilium|calico|flannel|none)." ;;
esac
# Seul Cilium annonce les IP de Service en L2 dans ce lab.
if [ "$CNI" = "cilium" ]; then LB_L2=1 ; else LB_L2=0 ; fi

# Plage d'IP LoadBalancer : la 1re IP est celle que prend le Gateway (cible du DNS wildcard).
LB_POOL_START="$(lire_param LB_POOL_START 192.168.56.200)"

# Paramètres réseau relus du cluster réel — ne servent qu'à la branche flannel ci-dessous
# (cilium-up.sh et calico-up.sh les relisent eux-mêmes).
POD_CIDR="$(lire_param POD_CIDR "$DEFAULT_POD_CIDR")"
HOSTONLY_IF="$(lire_param HOSTONLY_IF "$DEFAULT_HOSTONLY_IF")"
KUBE_PROXY_REPLACEMENT="$(lire_param KUBE_PROXY_REPLACEMENT "$DEFAULT_KUBE_PROXY_REPLACEMENT")"
KUBE_PROXY_REPLACEMENT="$(printf '%s' "$KUBE_PROXY_REPLACEMENT" | tr '[:upper:]' '[:lower:]')"

# ⚠️ Le couple interdit (kubeadm uniquement). Avec KUBE_PROXY_REPLACEMENT=true, `kubeadm
# init` a tourné avec `--skip-phases=addon/kube-proxy` : il n'y a AUCUN kube-proxy dans le
# cluster. Seul Cilium sait le remplacer — avec calico/flannel/none, plus aucune ClusterIP
# ne répondrait (CoreDNS compris). cluster-up.sh refuse déjà ce couple au bootstrap ; on le
# revérifie parce que lab.env a pu être édité depuis, et que la panne serait illisible.
# Sur Talos, kube-proxy est toujours posé par le bootstrap : la question ne se pose pas.
if [ "$KUBE_PROXY_REPLACEABLE" = "true" ] && [ "$KUBE_PROXY_REPLACEMENT" = "true" ] && [ "$CNI" != "cilium" ]; then
  fail "KUBE_PROXY_REPLACEMENT=true exige CNI=cilium (ici CNI=${CNI}).
        Choisis CNI=cilium, ou KUBE_PROXY_REPLACEMENT=false + reconstruction du cluster
        (${CLUSTER_RESET_HINT})."
fi

# --- Pré-requis -------------------------------------------------------------
need kubectl helm
# openssl n'est nécessaire que pour fabriquer le wildcard auto-signé.
[ "$SELF_SIGNED" = "true" ] && need openssl
exiger_apiserver

log "Plateforme — profil ${K8S_DISTRO}"
resume_distro

# ============================================================================
log "[1/4] CNI = ${CNI}"
case "$CNI" in
  cilium)
    echo "    -> cilium/cilium-up.sh (CNI + pool L2)"
    bash "${REPO_ROOT}/cilium/cilium-up.sh" "$K8S_DISTRO"
    ;;
  calico)
    echo "    -> calico/calico-up.sh (CNI seul)"
    bash "${REPO_ROOT}/calico/calico-up.sh" "$K8S_DISTRO"
    echo "    /!\\ Calico n'annonce PAS les IP de Service LoadBalancer (BGP uniquement)."
    echo "        Le Gateway restera en EXTERNAL-IP <pending> et aucune UI ne sera"
    echo "        joignable tant que MetalLB n'est pas installé. Voir calico/README.md."
    ;;
  flannel)
    if [ "$FLANNEL_PRE_INSTALLED" = "true" ]; then
      # Talos : `cluster.network.cni.name: flannel` est son défaut, le bootstrap l'a posé.
      echo "    Talos a installé flannel au bootstrap : rien à poser ici."
    else
      # kubeadm : flannel n'a pas de dossier dédié — c'est le chemin DÉGRADÉ du lab (aucune
      # IP LoadBalancer, donc aucune UI joignable), il tient en quelques lignes ici.
      # Deux valeurs sont vitales et c'est tout l'intérêt de passer par le chart :
      #   - podCidr DOIT valoir le `networking.podSubnet` de kubeadm (le défaut du chart est
      #     10.244.0.0/16, qui se trouve être le nôtre — on ne PARIE pas là-dessus) ;
      #   - `--iface=<host-only>` épingle la bonne carte. Sans lui, flannel suit la route par
      #     défaut et prend la NAT 10.0.2.15, identique sur toutes les VM : les VTEP VXLAN
      #     pointent vers un NAT isolé et le trafic pod cross-node est cassé.
      # Version NON épinglée par défaut : ce chemin n'a ni dossier ni README à maintenir.
      # `FLANNEL_VERSION=v0.28.8 ./platform-up.sh kubeadm` si tu veux de la reproductibilité.
      echo "    -> chart flannel/flannel (CNI seul, pas d'IP LoadBalancer)"
      helm repo add flannel https://flannel-io.github.io/flannel/ >/dev/null 2>&1 || true
      helm repo update flannel >/dev/null
      args_flannel=(upgrade --install flannel flannel/flannel
        -n kube-flannel --create-namespace
        --set "podCidr=${POD_CIDR}"
        --set-json "flannel.args=[\"--ip-masq\",\"--kube-subnet-mgr\",\"--iface=${HOSTONLY_IF}\"]")
      if [ -n "${FLANNEL_VERSION:-}" ]; then
        args_flannel+=(--version "${FLANNEL_VERSION}")
      fi
      helm "${args_flannel[@]}"
      echo "    attente des nodes Ready..."
      kubectl wait --for=condition=Ready nodes --all --timeout=300s
    fi
    echo "    /!\\ flannel n'attribue aucune IP de Service LoadBalancer : le Gateway"
    echo "        restera en EXTERNAL-IP <pending>. Pour les UI HTTPS, utilise CNI=cilium."
    ;;
  none)
    echo "    CNI=none : aucun CNI installé, ni par le bootstrap ni ici."
    kubectl get nodes --no-headers | grep -q ' Ready ' \
      || fail "aucun node Ready — installe ton CNI avant de continuer."
    ;;
esac

log "[2/4] Envoy Gateway ${ENVOY_GW_VERSION} + main-gateway"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GW_VERSION}" -n envoy-gateway-system --create-namespace
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=180s
# Rend le manifeste : hostname de l'écouteur https + nom du Secret TLS depuis LAB_DOMAIN,
# et l'émetteur ACME depuis LAB_ACME_ISSUER (le manifeste versionné porte `staging`).
# En auto-signé, on RETIRE le bloc `annotations:` du Gateway (commentaires compris) :
# l'annotation `cert-manager.io/cluster-issuer` est ce qui déclenche la création d'un
# Certificate. La laisser en place ferait écraser notre Secret par cert-manager dès
# qu'il serait installé pour une autre raison.
rendre_envoy_proxy() {
  if [ "$SELF_SIGNED" = "true" ]; then
    remplacer_issuer='/^  annotations:/,\|^    cert-manager\.io/cluster-issuer:|d'
  else
    remplacer_issuer="s|\(cert-manager\.io/cluster-issuer:\)[[:space:]]*letsencrypt-[a-z]*|\1 ${ACME_ISSUER}|"
  fi
  rendre "${REPO_ROOT}/envoy-gateway/Envoy-Proxy.yml" | sed -e "$remplacer_issuer"
}
ip_gateway() {
  kubectl -n envoy-gateway-system get svc \
    -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' \
    2>/dev/null || true
}

if [ "$LB_L2" = "1" ]; then
  rendre_envoy_proxy | kubectl apply -f -
else
  # `loadBalancerClass: io.cilium/l2-announcer` est spécifique à Cilium : la laisser
  # empêcherait tout autre annonceur (MetalLB avec Calico) de servir ce Service.
  rendre_envoy_proxy | sed '/loadBalancerClass:/d' | kubectl apply -f -
fi

if [ "$LB_L2" = "1" ]; then
  echo "    attente de l'IP LoadBalancer (annonce L2, attendu ${LB_POOL_START})..."
  for _ in $(seq 1 30); do
    ip="$(ip_gateway)"
    [ -n "$ip" ] && break
    sleep 5
  done
  if [ -n "${ip:-}" ]; then
    echo "    Gateway EXTERNAL-IP = $ip"
  else
    echo "    /!\\ toujours en <pending> après 150 s. Vérifier le pool et l'annonce L2 :"
    echo "        kubectl get ciliumloadbalancerippool ; kubectl get ciliuml2announcementpolicy"
  fi
else
  echo "    Pas d'annonceur L2 avec CNI=${CNI} : le Service restera en <pending>."
  echo "    C'est attendu — installe MetalLB (cf. calico/README.md) pour l'obtenir."
fi

log "[3/4] metrics-server (--kubelet-insecure-tls : certificats kubelet auto-signés)"
kubectl apply -f "${REPO_ROOT}/metric-server.yaml"

if [ "$SELF_SIGNED" = "true" ]; then

log "[4/4] Wildcard TLS auto-signé (openssl) — cert-manager NON installé"
echo "    -> self-signed/selfsigned-up.sh (AC locale + cert *.${LAB_DOMAIN})"
bash "${REPO_ROOT}/self-signed/selfsigned-up.sh" "$K8S_DISTRO"

else

log "[4/4] cert-manager ${CERT_MANAGER_VERSION} + Cloudflare + ClusterIssuers"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --set config.apiVersion="controller.config.cert-manager.io/v1alpha1" \
  --set config.kind="ControllerConfiguration" \
  --set config.enableGatewayAPI=true
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  kubectl create secret generic cloudflare-api-token -n cert-manager \
    --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "    /!\\ CLOUDFLARE_API_TOKEN vide (ni env ni lab.env) : secret NON créé."
  echo "        Le certificat wildcard restera en attente jusqu'à sa création."
fi
# ClusterIssuers : e-mail ACME + zone DNS du solveur substitués (cf. en-tête du script).
for issuer in 02-clusterissuer-staging 03-clusterissuer-prod; do
  rendre "${REPO_ROOT}/cert-manager/${issuer}.yaml" \
    | sed -e "s/admin@example\.io/${LAB_ACME_EMAIL}/g" \
          -e "s/^\([[:space:]]*-[[:space:]]\)example\.io/\1${LAB_DNS_ZONE}/" \
    | kubectl apply -f -
done

# --- Attente de l'émission du cert wildcard (DNS-01) pour un résumé fiable --
# Le cert + le Secret vivent dans le ns envoy-gateway-system (porté par main-gateway).
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  log "Attente de l'émission du certificat wildcard (DNS-01, ~1-2 min)..."
  for _ in $(seq 1 24); do
    r="$(kubectl -n envoy-gateway-system get certificate "${WILDCARD_TLS}" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [ "$r" = "True" ] && { echo "    cert Ready=True"; break; }
    sleep 10
  done
fi

fi   # fin de la bascule SELF_SIGNED

# ============================================================================
log "Plateforme installée (${K8S_DISTRO})."
echo "  CNI          : ${CNI}$([ "$LB_L2" = 1 ] && echo ' (annonce L2 des IP LoadBalancer)' || echo ' (pas d IP LoadBalancer)')"
if [ "$KUBE_PROXY_REPLACEABLE" = "true" ]; then
  echo "  kube-proxy   : $([ "$KUBE_PROXY_REPLACEMENT" = true ] && echo 'REMPLACÉ par Cilium (eBPF)' || echo 'installé par kubeadm')"
else
  echo "  kube-proxy   : installé par Talos (non remplaçable dans ce lab)"
fi
echo "  Nodes        : $(kubectl get nodes --no-headers | grep -c ' Ready ')/$(kubectl get nodes --no-headers | wc -l) Ready"
echo "  Gateway      : $(kubectl -n envoy-gateway-system get gateway main-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)"
if [ "$SELF_SIGNED" = "true" ]; then
  echo "  Cert wildcard: $(kubectl -n envoy-gateway-system get secret "${WILDCARD_TLS}" -o jsonpath='{.metadata.name}' 2>/dev/null || echo 'ABSENT') (auto-signé) [${WILDCARD_TLS}]"
  echo "  Mode TLS     : SELF_SIGNED=true — AC locale _out/self-signed/ca.crt, pas de cert-manager"
  echo "  Domaine      : *.${LAB_DOMAIN}  (aucun DNS public requis)"
  echo "                 Le navigateur avertit tant que l'AC n'est pas importée :"
  echo "                 sudo cp _out/self-signed/ca.crt /usr/local/share/ca-certificates/${CA_FILE_NAME}"
  echo "                 sudo update-ca-certificates"
  echo "                 Pour un cert publiquement trusté : SELF_SIGNED=false + CLOUDFLARE_API_TOKEN."
else
  echo "  Cert wildcard: $(kubectl -n envoy-gateway-system get certificate "${WILDCARD_TLS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '?') (Ready) [${WILDCARD_TLS}]"
  echo "  Émetteur ACME: ${ACME_ISSUER}$([ "$LAB_ACME_ISSUER" = "staging" ] && echo '  (cert NON trusté : avertissement navigateur attendu)' || echo '  (cert trusté — quota 5/semaine !)')"
  echo "  Domaine      : *.${LAB_DOMAIN}  (zone DNS ${LAB_DNS_ZONE})"
  if [ "$LAB_ACME_ISSUER" = "staging" ]; then
    echo "                 Pour un cert trusté : LAB_ACME_ISSUER=prod dans lab.env, puis"
    echo "                 kubectl -n envoy-gateway-system delete secret ${WILDCARD_TLS}"
  fi
fi
echo
echo "  Addons à installer ensuite (chacun son dossier + up.sh + README pas-à-pas) :"
echo "    ./install.sh ${K8S_DISTRO} longhorn        (stockage bloc)"
echo "    ./install.sh ${K8S_DISTRO} vault           (secrets HA)"
echo "    ./install.sh ${K8S_DISTRO} argocd          (GitOps, argo.${LAB_DOMAIN})"
echo "    ./install.sh ${K8S_DISTRO} list            (le catalogue complet)"
echo
gw_ip="$(ip_gateway || true)"
gw_ip="${gw_ip:-$LB_POOL_START}"
if [ "$SELF_SIGNED" = "true" ]; then
  # Pas de contrainte ACME en auto-signé : le domaine n'a jamais besoin d'exister
  # publiquement, une résolution locale suffit à joindre les UI.
  echo "  Résolution des noms — à faire UNE FOIS pour joindre les UI :"
  echo "    ligne /etc/hosts (le plus simple, un sous-domaine par ligne) :"
  echo "      ${gw_ip}  argo.${LAB_DOMAIN} grafana.${LAB_DOMAIN} vault.${LAB_DOMAIN}"
  echo "    ou un enregistrement A wildcard  *.${LAB_DOMAIN} -> ${gw_ip}  si tu as une zone DNS."
else
  echo "  DNS — à faire UNE FOIS chez ton registrar/Cloudflare pour joindre les UI :"
  echo "    enregistrement A  *.${LAB_DOMAIN}  ->  ${gw_ip}"
  echo "    en DNS-only (nuage GRIS) : le proxy Cloudflare ne peut pas joindre une IP privée."
fi
