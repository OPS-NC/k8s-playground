#!/usr/bin/env bash
#
# calico-up.sh — installs Calico as the lab's CNI, through the Tigera operator, on a cluster
# bootstrapped WITHOUT a CNI (`CNI=calico` or `CNI=none` in lab.env):
#   - kubeadm: `kubeadm init` never installs a pod network;
#   - Talos  : the bootstrap sets `cluster.network.cni.name: none`.
# In both cases the nodes stay NotReady until this script has run.
#
#   ./calico/calico-up.sh <talos|kubeadm>     (or ./install.sh <distro> calico)
#
# ⚠️ On kubeadm, INCOMPATIBLE with KUBE_PROXY_REPLACEMENT=true: only Cilium knows how to
#    replace kube-proxy. `kubeadm/cluster-up.sh` already REFUSES to start on that pair, and
#    this script re-checks it — a cluster with neither kube-proxy nor a replacement has no
#    working ClusterIP left.
#    (On Talos the question does not arise: kube-proxy is always installed at bootstrap.)
#
# ⚠️ SCOPE: this script installs the CNI, NOTHING ELSE.
#    Calico brings the pod network, the routing and NetworkPolicies. It assigns and announces
#    NO `LoadBalancer` Service IP: Calico can only do that over BGP, which needs a peer router
#    — non-existent on a VirtualBox host-only network. It has no equivalent of Cilium's
#    L2/ARP announcement.
#    Direct consequence: the Envoy Gateway Service stays on `EXTERNAL-IP <pending>` and no lab
#    UI (Argo CD, Grafana, Vault, Longhorn…) is reachable until an L2 announcer — MetalLB — is
#    installed ALONGSIDE. How to do it: README.md.
#
# Order of the steps (each assumes the previous one):
#   1. guard rails: binaries, apiserver, no other CNI already in place, kube-proxy present,
#      pod CIDR consistent with the cluster's (kubeadm's `networking.podSubnet`, read from
#      `_out/cluster.env`; Talos' `cluster.network.podSubnets`, read from
#      `_out/controlplane.yaml`);
#   2. `tigera-operator` chart (Helm) => the operator + the `operator.tigera.io` CRDs;
#   3. wait for the `installations` and `apiservers.operator.tigera.io` CRDs to be Established
#      — the operator itself creates them (`-manage-crds=true`), so they do not exist before
#      its pod runs;
#   4. `installation.yaml` (CIDRs substituted) + `apiserver.yaml` => the operator deploys
#      calico-node and the calico-apiserver;
#   5. bounded waits: calico-node DaemonSet rolled out, then every node `Ready`;
#   6. summary + a reminder of what is still missing for the lab UIs to be reachable.
#
# Idempotent: `helm upgrade --install` + `kubectl apply`. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Pinned version (overridable through an environment variable) ------------
# Calico chart AND appVersion: `helm search repo projectcalico/tigera-operator --versions`.
CALICO_VERSION="${CALICO_VERSION:-v3.32.1}"

# --- Lab parameters ---------------------------------------------------------
# Host-only network: used to pin Calico's address autodetection (see installation.yaml).
NETWORK="$(read_param NETWORK 192.168.56)"
HOSTONLY_CIDR="${HOSTONLY_CIDR:-${NETWORK}.0/24}"
# Pod CIDR: must match the CIDR the cluster actually uses (default 10.244.0.0/16).
POD_CIDR="$(read_param POD_CIDR "$DEFAULT_POD_CIDR")"

# --- Prerequisites ----------------------------------------------------------
need kubectl helm
require_apiserver

# --- Guard rail: one CNI per cluster ----------------------------------------
# Two CNIs installed side by side fight over /etc/cni/net.d and the routes: the pod network
# becomes inconsistent and there is no clean way back. We refuse outright.
other_cni="$(kubectl get daemonsets -A -o name 2>/dev/null | grep -iE 'cilium|flannel' || true)"
if [ -n "$other_cni" ]; then
  fail "another CNI is already installed (${other_cni}).
        Switching CNI is NOT a runtime toggle: flatten the cluster, set CNI=calico in
        lab.env, then bootstrap again (${CLUSTER_RESET_HINT})."
fi

# --- Guard rail: Calico requires kube-proxy ---------------------------------
# Calico does not replace kube-proxy (its eBPF dataplane could, but it is turned off here —
# see installation.yaml). Without kube-proxy AND without a replacement no ClusterIP answers
# any more: CoreDNS itself cannot reach the apiserver.
# The KUBE_PROXY_REPLACEMENT=true + calico pair only exists on kubeadm (on Talos kube-proxy is
# always installed at bootstrap): cluster-up.sh already refuses it, but lab.env may have been
# edited since.
if [ "$KUBE_PROXY_REPLACEABLE" = "true" ] && [ "$(read_param KUBE_PROXY_REPLACEMENT false)" = "true" ]; then
  fail "KUBE_PROXY_REPLACEMENT=true is INCOMPATIBLE with CNI=calico.
        Only Cilium knows how to replace kube-proxy in this lab. Pick either:
          - CNI=cilium                    (keep the eBPF replacement), or
          - KUBE_PROXY_REPLACEMENT=false  (keep kube-proxy and Calico)
        then rebuild the cluster (${CLUSTER_RESET_HINT})."
fi
if ! kubectl -n kube-system get daemonset/kube-proxy >/dev/null 2>&1; then
  fail "no kube-proxy DaemonSet in kube-system: this cluster runs without kube-proxy
        (on kubeadm: \`kubeadm init --skip-phases=addon/kube-proxy\`, i.e.
        KUBE_PROXY_REPLACEMENT=true). Calico cannot replace it — rebuild the cluster with
        KUBE_PROXY_REPLACEMENT=false."
fi

# --- Guard rail: the Calico pool MUST cover the cluster's pod CIDR ----------
# Otherwise the kubelet allocates pod IPs in a CIDR Calico never programmed: routes and VXLAN
# tunnels point nowhere.
# The facts are not in the same place depending on the distribution:
#   - kubeadm: `_out/cluster.env` (the POD_CIDR actually passed to `kubeadm init`);
#   - Talos  : `_out/controlplane.yaml` (`cluster.network.podSubnets`).
actual_pod_cidr=""
if [ "$K8S_DISTRO" = "kubeadm" ]; then
  actual_pod_cidr="$(read_cluster_env POD_CIDR)"
  cidr_source="${CLUSTER_ENV_FILE}"
elif [ -f "${LAB_DIR}/_out/controlplane.yaml" ]; then
  actual_pod_cidr="$(awk '/podSubnets:/{f=1;next} f && $1=="-" {print $2; exit}' \
    "${LAB_DIR}/_out/controlplane.yaml" 2>/dev/null || true)"
  cidr_source="${LAB_DIR}/_out/controlplane.yaml"
fi
if [ -n "$actual_pod_cidr" ] && [ "$actual_pod_cidr" != "$POD_CIDR" ]; then
  fail "pod CIDR mismatch: the cluster advertises ${actual_pod_cidr}
        (${cidr_source}) while the Calico IPPool would be ${POD_CIDR}.
        Re-run with POD_CIDR=${actual_pod_cidr} ./calico/calico-up.sh ${K8S_DISTRO}"
fi

# ============================================================================
log "[1/4] Tigera operator ${CALICO_VERSION} (projectcalico/tigera-operator chart)"
# Namespace created BEFORE the chart: it carries the `privileged` PodSecurity labels the
# operator pod needs (hostNetwork + hostPath): REQUIRED on Talos (cluster default `baseline`),
# plain documentation of intent on kubeadm (no level enforced by default).
# `helm --create-namespace` would set no label at all. See namespace.yaml.
kubectl apply -f "${HERE}/namespace.yaml"
helm repo add projectcalico https://docs.tigera.io/calico/charts >/dev/null 2>&1 || true
helm repo update projectcalico >/dev/null
# All FOUR chart CRs (Installation, APIServer, Goldmane, Whisker) are turned off here, and
# that is structural: the chart ships no `crds/` directory, it is the operator that creates
# the `operator.tigera.io` CRDs when it starts (`-manage-crds=true`). Any CR rendered by Helm
# on a fresh cluster therefore fails with "no matches for kind ... ensure CRDs are installed
# first", before the namespace is even created.
# - installation.enabled=false: the Installation CR comes from our installation.yaml (a single
#   owner for the object, and a re-readable file rather than a pile of --set);
# - apiServer.enabled=false: same, the CR comes from our apiserver.yaml, applied at step [3/4]
#   once the CRDs are there. The calico-apiserver IS deployed — it exposes projectcalico.org/v3
#   (Calico IPPool / NetworkPolicy through kubectl, no calicoctl needed);
# - goldmane/whisker: Calico's flow UI, turned off to keep the lab light — turning it back on
#   means extracting its CRs the same way (see README.md).
helm upgrade --install calico projectcalico/tigera-operator \
  --namespace tigera-operator --create-namespace \
  --version "${CALICO_VERSION}" \
  --set installation.enabled=false \
  --set apiServer.enabled=false \
  --set goldmane.enabled=false \
  --set whisker.enabled=false
# The operator runs on hostNetwork: it starts even without a CNI (that is what makes the
# bootstrap possible). If it does not start, everything else is pointless => we fail.
kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=300s \
  || fail "the Tigera operator did not start (kubectl -n tigera-operator describe pods)."

log "[2/4] Waiting for the operator.tigera.io CRDs (created by the operator, -manage-crds=true)"
# The two CRDs whose CR we apply at the next step. Waiting for `installations` alone is not
# enough: `apiserver.yaml` would fail if its CRD were not there yet.
for crd in installations.operator.tigera.io apiservers.operator.tigera.io; do
  crd_ok=0
  for _ in $(seq 1 60); do
    kubectl get crd "$crd" >/dev/null 2>&1 && { crd_ok=1; break; }
    sleep 5
  done
  [ "$crd_ok" -eq 1 ] \
    || fail "CRD ${crd} missing after 5 min.
        Check the logs: kubectl -n tigera-operator logs deploy/tigera-operator"
  kubectl wait --for=condition=Established "crd/${crd}" --timeout=60s \
    || fail "CRD ${crd} present but never Established."
done

log "[3/4] Installation + APIServer CRs (IPPool ${POD_CIDR}, VXLAN, autodetection on ${HOSTONLY_CIDR})"
# The CIDRs versioned in installation.yaml are the lab defaults; we replace them with the ones
# computed above (NETWORK from lab.env / POD_CIDR), comments included.
sed -e "s#192\.168\.56\.0/24#${HOSTONLY_CIDR}#g" \
    -e "s#10\.244\.0\.0/16#${POD_CIDR}#g" \
    "${HERE}/installation.yaml" | kubectl apply -f -
# APIServer CR: taken out of the chart for the same reason as the Installation (see
# apiserver.yaml). It deploys the calico-apiserver => `kubectl get ippools.projectcalico.org`
# works.
kubectl apply -f "${HERE}/apiserver.yaml"

log "[4/4] Waiting for calico-node to roll out, then for the nodes to be Ready"
# The operator creates the DaemonSet in the calico-system namespace: it does not exist
# immediately after the apply, hence the bounded loop before the rollout status.
ds_ok=0
for _ in $(seq 1 60); do
  kubectl -n calico-system get daemonset/calico-node >/dev/null 2>&1 && { ds_ok=1; break; }
  sleep 5
done
[ "$ds_ok" -eq 1 ] \
  || fail "DaemonSet calico-system/calico-node never created after 5 min.
        Check the CR status: kubectl get tigerastatus
        and the logs: kubectl -n tigera-operator logs deploy/tigera-operator"
# 600 s: first pull of the calico/node images on every node (8 VMs, NAT network).
kubectl -n calico-system rollout status daemonset/calico-node --timeout=600s \
  || fail "calico-node is not ready on every node.
        kubectl -n calico-system get pods -o wide
        kubectl -n calico-system logs ds/calico-node -c calico-node --tail=50"
# It is the CNI that unblocks the nodes: without it they stay NotReady.
kubectl wait --for=condition=Ready nodes --all --timeout=300s \
  || fail "some nodes stayed NotReady even though calico-node is ready (kubectl get nodes)."

# ============================================================================
log "Calico ${CALICO_VERSION} installed (CNI + NetworkPolicy)."
echo "  Nodes        : $(kubectl get nodes --no-headers | grep -c ' Ready ')/$(kubectl get nodes --no-headers | wc -l) Ready"
ds_ready="$(kubectl -n calico-system get daemonset/calico-node \
  -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null || true)"
echo "  calico-node  : ${ds_ready} ready"
echo "  IPPool       : ${POD_CIDR} (VXLAN, natOutgoing) — must == the cluster's pod CIDR"
echo "  Autodetection: cidrs=${HOSTONLY_CIDR} (host-only network, NOT the NAT card)"
echo
printf '\033[1;33m  /!\\ Calico does NOT provide LoadBalancer Service IPs.\033[0m\n'
echo "      As it stands, the Envoy Gateway Service will stay on EXTERNAL-IP <pending>"
echo "      and no lab UI will be reachable. Two things are still missing:"
echo "        1. install an L2 announcer (MetalLB) on the ${NETWORK}.200-${NETWORK}.230 range;"
echo "        2. remove 'loadBalancerClass: io.cilium/l2-announcer' from"
echo "           envoy-gateway/Envoy-Proxy.yml (a Cilium-specific class)."
echo "      Detailed instructions: calico/README.md"
