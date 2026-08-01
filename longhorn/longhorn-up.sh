#!/usr/bin/env bash
#
# longhorn-up.sh — installs Longhorn (replicated block storage) and exposes its UI over HTTPS
# at longhorn.$LAB_DOMAIN through main-gateway.
#
#   ./longhorn/longhorn-up.sh <talos|kubeadm>     (or ./install.sh <distro> longhorn)
#
# Standalone add-on: platform-up.sh only lays down Cilium + Envoy + metrics + the wildcard TLS.
#
# ⚠️ THE iSCSI prerequisite is NOT in the same place depending on the distribution — that is
#    this component's structuring difference:
#
#    Talos (LONGHORN_PREP_REQUIRED=true): two preliminary steps, handled here.
#      1. the `iscsi-tools` / `util-linux-tools` extensions are BAKED into the installer image
#         (`talosctl get extensions`): a node without them cannot be fixed without a
#         reinstall (`iscsiadm: not found` => CSI in CrashLoopBackOff), hence a failure BEFORE
#         the chart is laid down. Image to be generated from longhorn/schematic.yaml.
#      2. `rshared` kubelet mount on /var/lib/longhorn (longhorn/patch-longhorn.yaml,
#         `talosctl patch mc`): the Talos kubelet runs in a container with no bidirectional
#         mount propagation. Applied at runtime, without a reboot, and only where missing.
#
#    kubeadm (LONGHORN_PREP_REQUIRED=false): both fall away.
#      1. the iSCSI prerequisite is a PACKAGE: `kubeadm/provision.sh` runs
#         `apt-get install -y open-iscsi nfs-common`, `systemctl enable --now iscsid` and
#         loads `iscsi_tcp` on EVERY node, at provisioning time;
#      2. `/var/lib/longhorn` is an ordinary directory of the root filesystem and the kubelet
#         runs directly on the host: mount propagation is already fine.
#      => no `talosctl`, no `TALOSCONFIG`, no patch: the script goes from 5 steps to 3.
#
# Prerequisites: platform in place (HTTPS main-gateway + wildcard Secret), helm
#                (+ talosctl on Talos).
# Idempotent: `helm upgrade --install` + `kubectl apply` (+ the mc patch applied only when
# missing). Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Pinned version (overridable through an environment variable) ------------
LONGHORN_VERSION="${LONGHORN_VERSION:-1.12.0}"

# --- Prerequisites ----------------------------------------------------------
need kubectl helm
if [ "$LONGHORN_PREP_REQUIRED" = "true" ]; then
  need talosctl
  export TALOSCONFIG="${TALOSCONFIG:-${LAB_DIR}/_out/talosconfig}"
fi
require_apiserver

# --- Node preparation (Talos only) ------------------------------------------
# Longhorn volumes only live on schedulable nodes: we therefore address the workers, whose IPs
# are derived from the same keys as the lab's Vagrantfile.
if [ "$LONGHORN_PREP_REQUIRED" = "true" ]; then
  WORKERS="$(read_param WORKERS 3)"
  NETWORK="$(read_param NETWORK 192.168.56)"
  WK_IP_START="$(read_param WK_IP_START 101)"
  WK_IP_STEP="$(read_param WK_IP_STEP 1)"
  worker_ips=()
  for ((i = 1; i <= WORKERS; i++)); do
    worker_ips+=("${NETWORK}.$((WK_IP_START + (i - 1) * WK_IP_STEP))")
  done
  [ "${#worker_ips[@]}" -gt 0 ] || fail "WORKERS=0 — Longhorn has no storage node."

  log "[Talos 1/2] iscsi extensions on the ${WORKERS} worker(s): ${worker_ips[*]}"
  # An extension is baked into the installer: if it is missing, NOTHING can be done here (the
  # node has to be reinstalled/upgraded), so we fail before laying down the chart.
  for ip in "${worker_ips[@]}"; do
    if talosctl -n "$ip" get extensions 2>/dev/null | grep -q 'iscsi-tools'; then
      echo "    ${ip}: iscsi-tools OK"
    else
      fail "${ip} does not have the iscsi-tools extension.
        INSTALLER_IMAGE (lab.env) must point at the factory image of the
        longhorn/schematic.yaml schematic, then the node has to be (re)installed.
        Cluster already running: talosctl -n ${ip} upgrade --image <factory> --preserve"
    fi
  done

  log "[Talos 2/2] rshared kubelet mount on /var/lib/longhorn (patch-longhorn.yaml)"
  # `cluster-up.sh` only passes patch-all / patch-cp / cni-* to gen config: on a fresh cluster
  # this mount is always missing. Applied at runtime, without a reboot.
  for ip in "${worker_ips[@]}"; do
    if talosctl -n "$ip" get mc -o yaml 2>/dev/null | grep -q '/var/lib/longhorn'; then
      echo "    ${ip}: extraMounts already present, nothing to do"
    else
      echo "    ${ip}: applying the patch…"
      talosctl -n "$ip" patch mc --patch "@${HERE}/patch-longhorn.yaml"
    fi
  done
fi

# --- Number of storage nodes: DETECTED, not derived from lab.env ------------
# Longhorn volumes only live where pods can be scheduled — the workers in the normal case (the
# CPs carry `node-role.kubernetes.io/control-plane:NoSchedule`). So we query the cluster
# rather than trusting lab.env's WORKERS, which only expresses an intent.
# WORKERS=0 case: a SUPPORTED topology here (`UNTAINT_CP=auto` then untaints the control
# planes, see lab.env) — they become the only storage nodes, so we count them.
# `|| true`: under `pipefail` a failing pipeline would fail the assignment and, under
# `set -e`, kill the script — the same trap as `grep` above.
STORAGE_NODES="$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)"
if [ "${STORAGE_NODES:-0}" -eq 0 ]; then
  STORAGE_NODES="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)"
fi
[ "${STORAGE_NODES:-0}" -gt 0 ] || { echo "ERROR: no schedulable node — Longhorn has nowhere to store anything." >&2; exit 1; }

# Number of block replicas = number of storage nodes, capped at 3: a `defaultReplicaCount`
# greater than the node count leaves every volume "Degraded" forever (a documented pitfall of
# the README).
REPLICAS="${REPLICAS:-$STORAGE_NODES}"
[ "$REPLICAS" -gt 3 ] && REPLICAS=3

# ============================================================================
log "[1/3] Namespace longhorn-system (PodSecurity privileged)"
# Longhorn pods are privileged (iSCSI, hostPath). On Talos (PodSecurity `baseline` enforced
# cluster-wide) this label is MANDATORY: without it the pods are refused. On kubeadm no level
# is enforced by default — the label documents the intent and keeps the namespace working if
# the cluster is hardened later (--admission-control-config-file).
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite

# ============================================================================
log "[2/3] Longhorn chart ${LONGHORN_VERSION} (${REPLICAS} block replica(s), ${STORAGE_NODES} storage node(s)) + longhorn-r1 StorageClass"
helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
helm repo update longhorn >/dev/null
# values.yaml carries 3 replicas (the lab's "full" topology); we align it with the number of
# storage nodes actually present.
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version "${LONGHORN_VERSION}" \
  --values "${HERE}"/values.yaml \
  --set "defaultSettings.defaultReplicaCount=${REPLICAS}" \
  --set "persistence.defaultClassReplicaCount=${REPLICAS}" \
  --wait --timeout 10m
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=300s
kubectl apply -f "${HERE}"/longhorn-r1-storageclass.yaml

# ============================================================================
log "[3/3] HTTPRoute longhorn.${LAB_DOMAIN}"
# The versioned manifest carries the neutral domain: substituted on the fly, as everywhere
# else in k8s-playground/ (see ../README.md).
render "${HERE}"/httproute.yaml | kubectl apply -f -

# ============================================================================
log "Longhorn installed."
echo "  StorageClass : longhorn (${REPLICAS} replica(s), the cluster default) + longhorn-r1 (1 replica)"
echo "  UI           : https://longhorn.${LAB_DOMAIN}   (NO authentication at all!)"
echo "  Without expo : kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80"
echo "  Check        : kubectl -n longhorn-system get nodes.longhorn.io"
echo
echo "  /!\\ The Longhorn UI has no auth and allows DELETING volumes: only expose it on a"
echo "      trusted network, or put an Envoy SecurityPolicy in front (see README)."
