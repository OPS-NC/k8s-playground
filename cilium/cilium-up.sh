#!/usr/bin/env bash
#
# cilium-up.sh — installs Cilium (CNI + LoadBalancer IPs + L2 announcement) on a cluster
# bootstrapped WITHOUT a CNI, Talos or kubeadm:
#   - kubeadm: `kubeadm init` installs no pod network (CNI=cilium or CNI=none);
#   - Talos  : `cluster.network.cni.name: none` set by the bootstrap (same thing).
# In both cases the nodes stay NotReady until this script has run.
#
#   ./cilium/cilium-up.sh <talos|kubeadm>     (or ./install.sh <distro> cilium)
#
# Does two things (the 2nd assumes the 1st):
#   1. Cilium through Helm: the CNI (=> nodes Ready), eBPF kube-proxy replacement per
#      KUBE_PROXY_REPLACEMENT (kubeadm only), L2 announcement enabled, and the host-only
#      interface pinned (otherwise Cilium picks the 10.0.2.15 NAT card, identical on every VM
#      => broken cross-node traffic and DNS).
#   2. L2 pool: CiliumLoadBalancerIPPool (.200-.230) + CiliumL2AnnouncementPolicy (ARP).
#
# Differences carried by the profile (lib/profiles/):
#   - talos  : ipam.mode=kubernetes, kube-proxy kept, + the values Cilium REQUIRES on Talos
#              (cgroup already mounted by the OS, explicit capabilities);
#   - kubeadm: ipam.mode=cluster-pool (pod CIDR handed to the operator), kube-proxy
#              replaceable in eBPF, chart defaults otherwise.
#
# Called by platform-up.sh (step 1), but runnable on its own.
# Idempotent: `helm upgrade --install` + `kubectl apply`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

CILIUM_VERSION="$(read_param CILIUM_VERSION 1.20.0)"

# LoadBalancer IP range (not in cluster.env: it is pure intent).
LB_POOL_START="$(read_param LB_POOL_START 192.168.56.200)"
LB_POOL_END="$(read_param LB_POOL_END 192.168.56.230)"

# kube-proxy replacement: MUST reflect what was actually done at bootstrap.
# kubeadm: `kubeadm init` ran with `--skip-phases=addon/kube-proxy` when the value is `true` —
# there is then NO kube-proxy in the cluster and Cilium has to take over in eBPF. Getting this
# value wrong breaks every Service in the cluster.
# Talos: kube-proxy is always installed by the bootstrap → the profile forces `false`.
if [ "$KUBE_PROXY_REPLACEABLE" = "true" ]; then
  KUBE_PROXY_REPLACEMENT="$(read_param KUBE_PROXY_REPLACEMENT "$DEFAULT_KUBE_PROXY_REPLACEMENT")"
  KUBE_PROXY_REPLACEMENT="$(printf '%s' "$KUBE_PROXY_REPLACEMENT" | tr '[:upper:]' '[:lower:]')"
  case "$KUBE_PROXY_REPLACEMENT" in
    true|false) ;;
    *) fail "unknown KUBE_PROXY_REPLACEMENT='${KUBE_PROXY_REPLACEMENT}' (true|false)." ;;
  esac
else
  KUBE_PROXY_REPLACEMENT=false
fi

# The apiserver contact point for the Cilium agent. We put the VIP there (the cluster's
# `controlPlaneEndpoint`), NOT cp1's real IP:
#   - the VIP survives losing cp1 (VRRP/Talos moves it), cp1's IP does not;
#   - it is already the address baked into the certificates and the kubeconfigs, so the only
#     one the apiserver certificate is guaranteed to cover.
VIP="$(read_param VIP "$DEFAULT_VIP")"

# The cluster's pod CIDR (kubeadm's `networking.podSubnet`, Talos'
# `cluster.network.podSubnets`).
POD_CIDR="$(read_param POD_CIDR "$DEFAULT_POD_CIDR")"

# Host-only interface. On kubeadm it is DETECTED inside the VM by cluster-up.sh
# (`_out/cluster.env`) because some boxes keep `eth1`; on Talos it is `enp0s8`.
HOSTONLY_IF="$(read_param HOSTONLY_IF "$DEFAULT_HOSTONLY_IF")"

need kubectl helm
require_apiserver

# --- Guard rail: a CNI already in place ---------------------------------------
# Laying Cilium on top of flannel gives you two competing CNIs and a broken pod network. The
# case happens on its own when `lab.env` was edited AFTER the bootstrap (cluster brought up
# with CNI=flannel — installed by Talos or by platform-up.sh — then Cilium run by hand).
# We match by pattern rather than by exact name: upstream the DaemonSet is called
# `kube-flannel-ds` in the `kube-flannel` namespace, but a chart may rename it.
flannel_ds="$(kubectl get daemonsets -A -o name 2>/dev/null | grep -i flannel || true)"
if [ -n "$flannel_ds" ]; then
  cat >&2 <<EOF
ERROR: flannel is already installed (${flannel_ds}).
  This cluster runs with CNI=flannel: adding Cilium on top breaks the pod network.
  Switching CNI at runtime is NOT supported. To move to Cilium:
    1. set CNI=cilium in lab.env (the default of both labs);
    2. ${CLUSTER_RESET_HINT}
  See cilium/README.md.
EOF
  exit 1
fi

# ============================================================================
log "Cilium ${CILIUM_VERSION} (CNI + L2, host-only interface ${HOSTONLY_IF})"
distro_summary
echo "    kube-proxy : $([ "$KUBE_PROXY_REPLACEMENT" = true ] && echo 'REPLACED in eBPF' || echo 'kept (Cilium on top)')"
echo "    pod CIDR   : ${POD_CIDR}   apiserver: ${VIP}:6443   ipam: ${CILIUM_IPAM_MODE}"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

# Values shared by both distributions.
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
# IPAM: `cluster-pool` (kubeadm) lets the Cilium operator carve the pod CIDR, so it has to be
# handed to it. `kubernetes` (Talos) follows the podCIDRs set by the kube-controller-manager:
# no CIDR to pass.
if [ "$CILIUM_IPAM_MODE" = "cluster-pool" ]; then
  sets+=(
    --set ipam.operator.clusterPoolIPv4PodCIDRList="{${POD_CIDR}}"
    --set ipam.operator.clusterPoolIPv4MaskSize=24
  )
fi
# Distribution-specific values (empty on kubeadm: the chart defaults are the right ones,
# forcing them would be HARMFUL there — see lib/profiles/kubeadm.sh).
while IFS= read -r extra; do
  [ -n "$extra" ] && sets+=("$extra")
done < <(cilium_specific_sets)

helm upgrade --install cilium cilium/cilium -n kube-system --create-namespace \
  --version "${CILIUM_VERSION}" "${sets[@]}"
echo "    waiting for nodes to become Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

log "Cilium L2 pool (LoadBalancer IPs ${LB_POOL_START}-${LB_POOL_END} + ARP announcement on ${HOSTONLY_IF})"
# The manifest carries the lab defaults; we replace them with the real lab's values (range
# from lab.env, interface detected for kubeadm / enp0s8 for Talos).
# The 1st IP of the range is the one the Envoy Gateway will take: it is the target of the
# `*.<LAB_DOMAIN>` wildcard DNS record (see ../README.md).
sed -e "s/192\.168\.56\.200/${LB_POOL_START}/g" \
    -e "s/192\.168\.56\.230/${LB_POOL_END}/g" \
    -e "s/enp0s8/${HOSTONLY_IF}/g" \
    "${HERE}/cilium-l2.yml" | kubectl apply -f -

log "Cilium installed (CNI + L2 pool)."
echo "  Diagnostics: kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose"
