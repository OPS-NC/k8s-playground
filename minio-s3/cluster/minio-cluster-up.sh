#!/usr/bin/env bash
#
# minio-cluster-up.sh — deploys DISTRIBUTED 4-node MinIO (erasure coding) on local-path,
# exposed through main-gateway. Creates the root credentials Secret, then applies the
# StatefulSet.
#
# Credentials: MINIO_ROOT_USER (default admin) + MINIO_ROOT_PASSWORD (default: generated).
# Idempotent: the Secret is not overwritten if it exists. Run it from the repository root.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
. "${HERE}/../../lib/common.sh"
k8s_init "$@"

need kubectl
require_apiserver
require_sc local-path
# 4 pods = 4 distinct nodes (anti-affinity): at least 4 schedulable workers are needed.
WK=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | grep -c ' Ready ' || true)
[ "${WK:-0}" -ge 4 ] || echo "  /!\\ Only ${WK} Ready worker(s) — 4 are needed (anti-affinity, 1 pod/node)."

MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)}"

log "Namespace + credentials Secret (not overwritten if it exists)"
kubectl create namespace minio-cluster --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl -n minio-cluster get secret minio-creds >/dev/null 2>&1; then
  kubectl -n minio-cluster create secret generic minio-creds \
    --from-literal=root-user="${MINIO_ROOT_USER}" \
    --from-literal=root-password="${MINIO_ROOT_PASSWORD}"
  echo "    Secret minio-creds created."
else
  echo "    Secret minio-creds already present (kept)."
fi

log "Distributed MinIO (4-node StatefulSet) + Services + HTTPRoutes"
# The manifest carries the HTTPRoute hostnames + MINIO_BROWSER_REDIRECT_URL.
render "${HERE}/minio-cluster.yaml" | kubectl apply -f -
kubectl -n minio-cluster rollout status statefulset/minio --timeout=300s

log "MinIO cluster installed."
echo "  S3 API   : https://minio-cluster.${LAB_DOMAIN}"
echo "  Console  : https://minio-cluster-console.${LAB_DOMAIN}"
echo "  User     : $(kubectl -n minio-cluster get secret minio-creds -o jsonpath='{.data.root-user}' | base64 -d)"
echo "  Password : $(kubectl -n minio-cluster get secret minio-creds -o jsonpath='{.data.root-password}' | base64 -d)"
echo "  Erasure  : mc admin info <alias>   (4 drives online, tolerates ~2 nodes down)"
