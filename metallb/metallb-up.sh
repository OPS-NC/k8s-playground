#!/usr/bin/env bash
#
# metallb-up.sh — installs MetalLB in LAYER 2 mode: it hands `type: LoadBalancer` Services a
# real IP from the host-only network and announces it over ARP.
#
#   ./metallb/metallb-up.sh <talos|kubeadm>     (or ./install.sh <distro> metallb)
#
# ⚠️ WHY this component exists: Cilium is the only CNI of this lab that plays "cloud provider"
#    on its own (CiliumLoadBalancerIPPool + CiliumL2AnnouncementPolicy). Calico announces
#    Service IPs over BGP only — which needs a peer router, non-existent on a VirtualBox
#    host-only network — and flannel does not do it at all. Without an announcer the Envoy
#    Gateway Service stays at `EXTERNAL-IP <pending>` and NO lab UI is reachable.
#    MetalLB fills exactly that hole, and nothing else: it is NOT a CNI.
#
# ⚠️ NEVER alongside Cilium's L2 announcement. Two announcers on the same range means two nodes
#    answering ARP for 192.168.56.200: the host's ARP cache flaps between them and the entry
#    point breaks intermittently — the hardest failure of this lab to read. The guard rail
#    below refuses outright.
#
# The announcement is the SAME as Cilium's, read from the SAME lab.env keys — that is the whole
# point: changing CNI must change the CNI, not the address the wildcard DNS points at.
#
#   lab.env key     Cilium object                 MetalLB object
#   LB_POOL_START   CiliumLoadBalancerIPPool      IPAddressPool     (first IP = the Gateway)
#   LB_POOL_END     idem                          idem
#   HOSTONLY_IF     CiliumL2AnnouncementPolicy    L2Advertisement   (`interfaces:`)
#   (workers only)  nodeSelector                  nodeSelectors
#
# Called by platform-up.sh (step [1/4], right after the CNI) when `CNI != cilium` and
# `METALLB != false`, but runnable on its own.
# Idempotent: `helm upgrade --install` + `kubectl apply`. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Pinned version (overridable through an environment variable) ------------
# Chart AND appVersion move together: `helm search repo metallb/metallb --versions`.
METALLB_VERSION="$(read_param METALLB_VERSION 0.16.1)"

# --- Lab parameters: the very same keys cilium/cilium-up.sh reads ------------
# LoadBalancer IP range (not in cluster.env: it is pure intent). The FIRST IP is the one the
# Envoy Gateway takes — the target of the `*.<LAB_DOMAIN>` wildcard DNS record.
LB_POOL_START="$(read_param LB_POOL_START 192.168.56.200)"
LB_POOL_END="$(read_param LB_POOL_END 192.168.56.230)"
# Host-only interface. On kubeadm it is DETECTED inside the VM by cluster-up.sh
# (`_out/cluster.env`) because some boxes keep `eth1`; on Talos it is `enp0s8`.
HOSTONLY_IF="$(read_param HOSTONLY_IF "$DEFAULT_HOSTONLY_IF")"

need kubectl helm
require_apiserver

# --- Guard rail: never two L2 announcers -------------------------------------
# Two signals, because neither is sufficient on its own:
#   - the LIVE objects are the truth, but the Cilium CRDs do not exist yet if this script is
#     run before the CNI;
#   - `CNI` in lab.env is the intent, and it is available even on an empty cluster.
# `kubectl get <crd-kind>` on a missing CRD exits non-zero: `|| true` keeps `set -e` out of it.
cilium_l2=""
for kind in ciliuml2announcementpolicies.cilium.io ciliumloadbalancerippools.cilium.io; do
  found="$(kubectl get "$kind" -o name 2>/dev/null || true)"
  [ -n "$found" ] && cilium_l2="${cilium_l2}${found} "
done
CNI="$(read_param CNI cilium)"
if [ -n "$cilium_l2" ] || [ "$CNI" = "cilium" ]; then
  fail "Cilium already announces the LoadBalancer IPs of this lab — MetalLB must NOT be added.
        $([ -n "$cilium_l2" ] \
            && printf 'live objects: %s' "$cilium_l2" \
            || printf 'CNI resolves to cilium (env > cluster.env > %s > lab default)' "$LAB_ENV_FILE")
        Two announcers on the same range = two nodes answering ARP for ${LB_POOL_START}:
        the host's ARP cache flaps and the entry point breaks intermittently.
        MetalLB is for CNI=calico, CNI=flannel or CNI=none. See metallb/README.md."
fi

# --- Guard rail: an announcer with no pod network announces nothing ----------
# MetalLB is not a CNI: the controller is an ordinary pod and needs an IP to run. On a cluster
# bootstrapped without a CNI the nodes are still NotReady and it would hang in Pending — with
# a `rollout status` timeout as the only clue five minutes later.
if ! kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready '; then
  fail "no Ready node: this cluster has NO CNI yet, and MetalLB is not one.
        Install the CNI first (./install.sh ${K8S_DISTRO} calico, or CNI=flannel through
        ./platform-up.sh), then come back here."
fi

# ============================================================================
log "MetalLB ${METALLB_VERSION} (L2 announcement of ${LB_POOL_START}-${LB_POOL_END} on ${HOSTONLY_IF})"
distro_summary
echo "    CNI        : ${CNI} (no LoadBalancer IP of its own — that is why MetalLB is here)"
echo "    announcers : workers only (nodeSelectors), like the Cilium policy"

log "[1/3] Namespace (PodSecurity privileged) + metallb/metallb chart"
# Namespace created BEFORE the chart: it carries the `privileged` PodSecurity labels the
# speaker needs (hostNetwork + NET_RAW) — MANDATORY on Talos (cluster default `baseline`),
# documentation of intent on kubeadm. `helm --create-namespace` would set no label at all.
# See namespace.yaml for the silent failure it prevents.
kubectl apply -f "${HERE}/namespace.yaml"
helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
helm repo update metallb >/dev/null
# Two values, and both matter:
#   - frrk8s.enabled=false: since chart 0.15 the FRR-K8s subchart is enabled by DEFAULT. It is
#     the BGP backend — a full FRR routing daemon on every node. This lab announces over L2
#     only (no peer router on a VirtualBox host-only network), so it is pure dead weight.
#   - speaker.frr.enabled=false: the other, deprecated, way to get FRR into the speaker pod.
#     The chart REFUSES both at once, so we turn both off explicitly rather than relying on
#     which one happens to default to false in the version of the day.
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system \
  --version "${METALLB_VERSION}" \
  --set frrk8s.enabled=false \
  --set speaker.frr.enabled=false

log "[2/3] Waiting for the controller and the speakers"
# The controller ALLOCATES the addresses, the speakers ANNOUNCE them: an IP without a speaker
# is an EXTERNAL-IP nobody answers ARP for — assigned and unreachable (see namespace.yaml).
kubectl -n metallb-system rollout status deploy/metallb-controller --timeout=300s \
  || fail "the MetalLB controller did not start (kubectl -n metallb-system describe deploy/metallb-controller)."
kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=300s \
  || fail "the MetalLB speakers are not ready on every node.
        If \`get pods\` shows NO speaker at all, it is PodSecurity: check the DaemonSet events
        with  kubectl -n metallb-system describe ds/metallb-speaker"

log "[3/3] IPAddressPool ${LB_POOL_START}-${LB_POOL_END} + L2Advertisement on ${HOSTONLY_IF}"
# The manifest carries the lab defaults; we replace them with the real lab's values — the same
# substitution cilium-up.sh does on cilium-l2.yml, from the same variables.
apply_l2_config() {
  sed -e "s/192\.168\.56\.200/${LB_POOL_START}/g" \
      -e "s/192\.168\.56\.230/${LB_POOL_END}/g" \
      -e "s/enp0s8/${HOSTONLY_IF}/g" \
      "${HERE}/metallb-l2.yml" | kubectl apply -f -
}
# Retry, and this is not belt-and-braces: MetalLB validates its CRs through a webhook served by
# the controller, whose TLS certificate the controller itself injects into the
# ValidatingWebhookConfiguration. Between "the Deployment is rolled out" and "the webhook
# answers with a certificate the apiserver trusts" there is a window of a few seconds where
# every apply fails with `connection refused` or `x509`. Failing there would be a false
# negative — the install is fine, it is just early.
applied=0
for _ in $(seq 1 30); do
  if out="$(apply_l2_config 2>&1)"; then applied=1; printf '%s\n' "$out"; break; fi
  sleep 5
done
[ "$applied" -eq 1 ] || fail "IPAddressPool/L2Advertisement refused after 150 s.
        Last error: ${out}
        The validating webhook is served by the controller:
          kubectl -n metallb-system logs deploy/metallb-controller"

# ============================================================================
log "MetalLB ${METALLB_VERSION} installed (L2 announcement)."
echo "  Pool         : ${LB_POOL_START}-${LB_POOL_END}  (the Gateway takes ${LB_POOL_START})"
echo "  Interface    : ${HOSTONLY_IF}  (host-only — never the NAT card)"
echo "  Speakers     : $(kubectl -n metallb-system get daemonset/metallb-speaker \
  -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null || echo '?') ready"
echo "  Announcing   : workers only (nodeSelectors: control-plane DoesNotExist)"
echo
echo "  Who announces what, once a LoadBalancer Service exists:"
echo "    kubectl get servicel2status -A -o wide"
echo "    kubectl -n envoy-gateway-system get svc      # EXTERNAL-IP = ${LB_POOL_START}"
echo
echo "  /!\\ An EXTERNAL-IP does NOT answer ping (no interface really carries it)."
echo "      The proof of the L2 announcement is the ARP entry:"
echo "        ip neigh flush ${LB_POOL_START}; curl -s -o /dev/null --max-time 5 http://${LB_POOL_START}/"
echo "        ip neigh show ${LB_POOL_START}     # lladdr = MAC of the elected worker"
