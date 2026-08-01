#!/usr/bin/env bash
#
# minio-up.sh — deploys standalone MinIO (S3) on local-path and exposes it through
# main-gateway. Creates the root credentials Secret (outside the manifest), then applies
# minio-s3.yaml.
#
# Credentials: MINIO_ROOT_USER (default admin) + MINIO_ROOT_PASSWORD (default: generated).
# Idempotent: the Secret is NOT overwritten if it already exists (the password stays stable).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

need kubectl
require_apiserver
require_sc local-path

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

log "MinIO deployment (official image) + Service + HTTPRoutes"
# The manifest carries the HTTPRoute hostnames + MINIO_BROWSER_REDIRECT_URL.
render "${HERE}/minio-s3.yaml" | kubectl apply -f -
kubectl -n minio-s3 rollout status deploy/minio --timeout=180s

# ============================================================================
log "MinIO installed."
echo "  S3 API   : https://minio.${LAB_DOMAIN}"
echo "  Console  : https://minio-console.${LAB_DOMAIN}  (full admin — pgsty/minio fork)"
echo "  User     : $(kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-user}' | base64 -d)"
echo "  Password : $(kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-password}' | base64 -d)"
echo "  S3 test  : mc alias set lab https://minio.${LAB_DOMAIN} <user> <pass> --insecure   # staging cert"
