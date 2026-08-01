#!/usr/bin/env bash
#
# cilium-up.sh — installe Cilium (CNI + IP LoadBalancer + annonce L2) sur un cluster
# bootstrapé SANS CNI, Talos ou kubeadm :
#   - kubeadm : `kubeadm init` n'installe aucun réseau pod (CNI=cilium ou CNI=none) ;
#   - Talos   : `cluster.network.cni.name: none` posé par le bootstrap (idem).
# Dans les deux cas les nodes restent NotReady tant que ce script n'est pas passé.
#
#   ./cilium/cilium-up.sh <talos|kubeadm>     (ou ./install.sh <distro> cilium)
#
# Fait deux choses (la 2e suppose la 1re) :
#   1. Cilium en Helm : CNI (=> nodes Ready), remplacement eBPF de kube-proxy selon
#      KUBE_PROXY_REPLACEMENT (kubeadm uniquement), annonce L2 activée, et interface
#      host-only épinglée (sinon Cilium prend la carte NAT 10.0.2.15, identique sur chaque
#      VM => trafic cross-node et DNS cassés).
#   2. Pool L2 : CiliumLoadBalancerIPPool (.200-.230) + CiliumL2AnnouncementPolicy (ARP).
#
# Différences portées par le profil (lib/profiles/) :
#   - talos   : ipam.mode=kubernetes, kube-proxy conservé, + les valeurs EXIGÉES par Cilium
#               sur Talos (cgroup déjà monté par l'OS, capabilities explicites) ;
#   - kubeadm : ipam.mode=cluster-pool (CIDR pod passé à l'opérateur), kube-proxy
#               remplaçable en eBPF, defaults du chart sinon.
#
# Appelé par platform-up.sh (étape 1), mais lançable seul.
# Idempotent : `helm upgrade --install` + `kubectl apply`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

CILIUM_VERSION="$(read_param CILIUM_VERSION 1.20.0)"

# Plage d'IP LoadBalancer (pas dans cluster.env : c'est une pure intention).
LB_POOL_START="$(read_param LB_POOL_START 192.168.56.200)"
LB_POOL_END="$(read_param LB_POOL_END 192.168.56.230)"

# Remplacement de kube-proxy : DOIT refléter ce qui a réellement été fait au bootstrap.
# kubeadm : `kubeadm init` a tourné avec `--skip-phases=addon/kube-proxy` quand la valeur
# est `true` — il n'y a alors AUCUN kube-proxy dans le cluster et Cilium doit prendre le
# relais en eBPF. Se tromper de valeur casse tous les Services du cluster.
# Talos : kube-proxy est toujours posé par le bootstrap → le profil force `false`.
if [ "$KUBE_PROXY_REPLACEABLE" = "true" ]; then
  KUBE_PROXY_REPLACEMENT="$(read_param KUBE_PROXY_REPLACEMENT "$DEFAULT_KUBE_PROXY_REPLACEMENT")"
  KUBE_PROXY_REPLACEMENT="$(printf '%s' "$KUBE_PROXY_REPLACEMENT" | tr '[:upper:]' '[:lower:]')"
  case "$KUBE_PROXY_REPLACEMENT" in
    true|false) ;;
    *) fail "KUBE_PROXY_REPLACEMENT='${KUBE_PROXY_REPLACEMENT}' inconnu (true|false)." ;;
  esac
else
  KUBE_PROXY_REPLACEMENT=false
fi

# Point de contact de l'apiserver pour l'agent Cilium. On y met la VIP
# (`controlPlaneEndpoint` du cluster), PAS l'IP réelle de cp1 :
#   - la VIP survit à la perte de cp1 (VRRP/Talos la déplace), l'IP de cp1 non ;
#   - c'est déjà l'adresse figée dans les certificats et les kubeconfig, donc la seule
#     que le certificat de l'apiserver couvre à coup sûr.
VIP="$(read_param VIP "$DEFAULT_VIP")"

# CIDR des pods du cluster (`networking.podSubnet` de kubeadm,
# `cluster.network.podSubnets` de Talos).
POD_CIDR="$(read_param POD_CIDR "$DEFAULT_POD_CIDR")"

# Interface host-only. Sur kubeadm elle est DÉTECTÉE dans la VM par cluster-up.sh
# (`_out/cluster.env`) car certaines box gardent `eth1` ; sur Talos c'est `enp0s8`.
HOSTONLY_IF="$(read_param HOSTONLY_IF "$DEFAULT_HOSTONLY_IF")"

need kubectl helm
require_apiserver

# --- Garde-fou : un CNI déjà en place -----------------------------------------
# Poser Cilium par-dessus flannel donne deux CNI concurrents et un réseau pod cassé.
# Le cas arrive tout seul quand `lab.env` a été édité APRÈS le bootstrap (cluster monté en
# CNI=flannel — posé par Talos ou par platform-up.sh — puis Cilium relancé à la main).
# On cherche par motif et non par nom exact : le DaemonSet s'appelle `kube-flannel-ds`
# dans le namespace `kube-flannel` chez l'upstream, mais un chart peut le renommer.
flannel_ds="$(kubectl get daemonsets -A -o name 2>/dev/null | grep -i flannel || true)"
if [ -n "$flannel_ds" ]; then
  cat >&2 <<EOF
ERREUR : flannel est déjà installé (${flannel_ds}).
  Ce cluster tourne avec CNI=flannel : ajouter Cilium par-dessus casse le réseau pod.
  Changer de CNI à chaud n'est PAS supporté. Pour repartir sur Cilium :
    1. mettre CNI=cilium dans lab.env (le défaut des deux labs) ;
    2. ${CLUSTER_RESET_HINT}
  Cf. cilium/README.md.
EOF
  exit 1
fi

# ============================================================================
log "Cilium ${CILIUM_VERSION} (CNI + L2, interface host-only ${HOSTONLY_IF})"
distro_summary
echo "    kube-proxy : $([ "$KUBE_PROXY_REPLACEMENT" = true ] && echo 'REMPLACÉ en eBPF' || echo 'conservé (Cilium par-dessus)')"
echo "    pod CIDR   : ${POD_CIDR}   apiserver : ${VIP}:6443   ipam : ${CILIUM_IPAM_MODE}"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

# Valeurs communes aux deux distributions.
sets=(
  --set envoy.enabled=false
  --set kubeProxyReplacement="${KUBE_PROXY_REPLACEMENT}"
  --set k8sServiceHost="${VIP}"
  --set k8sServicePort=6443
  --set routingMode=tunnel
  --set tunnelProtocol=vxlan
  --set l2announcements.enabled=true
  --set externalIPs.enabled=true
  --set hubble.enabled=true
  --set hubble.relay.enabled=true
  --set hubble.ui.enabled=true
  --set bandwidthManager.enabled=true
  --set devices="${HOSTONLY_IF}"
  --set ipam.mode="${CILIUM_IPAM_MODE}"
)
# IPAM : `cluster-pool` (kubeadm) laisse l'opérateur Cilium découper le CIDR pod, il faut
# donc le lui donner. `kubernetes` (Talos) suit les podCIDR posés par le
# kube-controller-manager : aucun CIDR à passer.
if [ "$CILIUM_IPAM_MODE" = "cluster-pool" ]; then
  sets+=(
    --set ipam.operator.clusterPoolIPv4PodCIDRList="{${POD_CIDR}}"
    --set ipam.operator.clusterPoolIPv4MaskSize=24
  )
fi
# Valeurs propres à la distribution (vide sur kubeadm : les défauts du chart sont les bons ;
# les forcer y serait NUISIBLE, cf. lib/profiles/kubeadm.sh).
while IFS= read -r extra; do
  [ -n "$extra" ] && sets+=("$extra")
done < <(cilium_specific_sets)

helm upgrade --install cilium cilium/cilium -n kube-system --create-namespace \
  --version "${CILIUM_VERSION}" "${sets[@]}"
echo "    attente des nodes Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

log "Pool L2 Cilium (IP LoadBalancer ${LB_POOL_START}-${LB_POOL_END} + annonce ARP sur ${HOSTONLY_IF})"
# Le manifeste porte les valeurs par défaut du lab ; on les remplace par celles du lab
# réel (plage de lab.env, interface détectée pour kubeadm / enp0s8 pour Talos).
# La 1re IP de la plage est celle que prendra le Gateway Envoy : c'est la cible du
# DNS wildcard `*.<LAB_DOMAIN>` (cf. ../README.md).
sed -e "s/192\.168\.56\.200/${LB_POOL_START}/g" \
    -e "s/192\.168\.56\.230/${LB_POOL_END}/g" \
    -e "s/enp0s8/${HOSTONLY_IF}/g" \
    "${HERE}/cilium-l2.yml" | kubectl apply -f -

log "Cilium installé (CNI + pool L2)."
echo "  Diagnostic : kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose"
