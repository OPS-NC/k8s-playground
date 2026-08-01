#!/usr/bin/env bash
#
# local-path-up.sh — installs the Rancher local-path-provisioner: a DEFAULT `local-path`
# StorageClass that provisions PVs on the workers' local disks. NODE-LOCAL storage, with no
# replication: it survives a pod restart, it is lost if the node dies. This is the
# "without Longhorn" alternative for this lab's add-ons (CloudNativePG…).
#
#   ./local-path-storage/local-path-up.sh <talos|kubeadm>
#
# ⚠️ The provisioning PATH depends on the distribution (LOCAL_PATH_DIR from the profile):
#      kubeadm: /opt/local-path-provisioner   (the UPSTREAM path; /opt is writable)
#      talos  : /var/local-path-provisioner   (on Talos only /var is writable — a helper pod
#               can create NOTHING under /opt, it fails at mount time)
#    The versioned manifest carries the upstream path; it is substituted on the fly here.
#
# Idempotent: `kubectl apply`. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

need kubectl
require_apiserver

# ============================================================================
log "local-path-provisioner (path ${LOCAL_PATH_DIR})"
distro_summary
sed "s#/opt/local-path-provisioner#${LOCAL_PATH_DIR}#g" "${HERE}/local-path-storage.yaml" \
  | kubectl apply -f -
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=120s

# ============================================================================
log "Installed."
echo "  StorageClass : $(kubectl get storageclass local-path -o jsonpath='{.metadata.name}{" (default="}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{")"}' 2>/dev/null)"
echo "  Test         : kubectl create -f - <<'EOF'"
echo "    (a PVC with storageClassName: local-path -> Bound as soon as a pod consumes it)"
echo "  Host path    : ${LOCAL_PATH_DIR} on the worker hosting the PV"
if [ "$K8S_DISTRO" = "talos" ]; then
  echo "                 (talosctl -n <worker-ip> ls ${LOCAL_PATH_DIR})"
else
  echo "                 (vagrant ssh k8s-w1 -c 'sudo ls -l ${LOCAL_PATH_DIR}')"
fi
