#!/usr/bin/env bash
#
# minio-up.sh — deploys standalone MinIO (S3) and exposes it through main-gateway. Creates
# the root credentials Secret (outside the manifest), then applies minio-s3.yaml.
#
#   ./minio-s3/minio-up.sh <talos|kubeadm>     (or ./install.sh <distro> minio)
#
# Storage: MINIO_SC picks the StorageClass (default `local-path`, node-local). Point it at
# `longhorn` when the bucket has to survive the loss of the node holding it — which is what a
# Velero backup target is for: a backup sitting on the same disk as the workload it protects
# only covers the "I deleted a namespace" failure, not "the worker is gone".
#
# Credentials: MINIO_ROOT_USER (default admin) + MINIO_ROOT_PASSWORD (default: generated).
# Idempotent: the Secret is NOT overwritten if it already exists (the password stays stable).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

MINIO_SC="${MINIO_SC:-local-path}"

need kubectl
require_apiserver
require_sc "${MINIO_SC}"

# A PVC's storageClassName is IMMUTABLE. Re-running with a different MINIO_SC would have the
# apply below rejected on that one field, halfway through the install — so we say it here,
# where the fix (delete the PVC, losing the objects, or keep the current class) is still an
# informed choice.
CURRENT_SC="$(kubectl -n minio-s3 get pvc minio-data \
  -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
if [ -n "$CURRENT_SC" ] && [ "$CURRENT_SC" != "$MINIO_SC" ]; then
  fail "PVC minio-s3/minio-data already exists on StorageClass '${CURRENT_SC}', and a PVC
        cannot be moved to '${MINIO_SC}' (the field is immutable). Either keep the existing
        class (MINIO_SC=${CURRENT_SC}), or DESTROY the current bucket content:
          kubectl -n minio-s3 delete deploy/minio pvc/minio-data
        then run this script again."
fi

MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)}"

log "Namespace + credentials Secret (not overwritten if it exists)"
kubectl create namespace minio-s3 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl -n minio-s3 get secret minio-creds >/dev/null 2>&1; then
  kubectl -n minio-s3 create secret generic minio-creds \
    --from-literal=root-user="${MINIO_ROOT_USER}" \
    --from-literal=root-password="${MINIO_ROOT_PASSWORD}"
  echo "    Secret minio-creds created."
else
  echo "    Secret minio-creds already present (kept)."
fi

log "MinIO deployment (official image) + Service + HTTPRoutes on ${MINIO_SC}"
# The manifest carries the HTTPRoute hostnames + MINIO_BROWSER_REDIRECT_URL. The StorageClass
# is substituted on the fly rather than edited in place, so the versioned file keeps its
# neutral default and `git status` stays clean (same approach as velero-up.sh with its bucket).
render "${HERE}/minio-s3.yaml" \
  | sed -e "s#^\( *storageClassName: \).*#\1${MINIO_SC}#" \
  | kubectl apply -f -
kubectl -n minio-s3 rollout status deploy/minio --timeout=180s

# ============================================================================
log "MinIO installed."
echo "  S3 API   : https://minio.${LAB_DOMAIN}"
echo "  Console  : https://minio-console.${LAB_DOMAIN}  (full admin — pgsty/minio fork)"
echo "  Storage  : PVC minio-s3/minio-data on StorageClass ${MINIO_SC}"
echo "  In-cluster: http://minio.minio-s3.svc.cluster.local:9000   (what Velero uses)"
echo "  User     : $(kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-user}' | base64 -d)"
echo "  Password : $(kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-password}' | base64 -d)"
echo "  S3 test  : mc alias set lab https://minio.${LAB_DOMAIN} <user> <pass> --insecure   # staging cert"
