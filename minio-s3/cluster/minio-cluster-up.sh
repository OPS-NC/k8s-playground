#!/usr/bin/env bash
#
# minio-cluster-up.sh — déploie MinIO DISTRIBUÉ 4 nœuds (erasure coding) sur local-path,
# exposé via main-gateway. Crée le Secret des identifiants root puis applique le StatefulSet.
#
# Identifiants : MINIO_ROOT_USER (défaut admin) + MINIO_ROOT_PASSWORD (défaut : généré).
# Idempotent : le Secret n'est pas écrasé s'il existe. À lancer depuis la racine du dépôt.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
. "${HERE}/../../lib/common.sh"
k8s_init "$@"

need kubectl
require_apiserver
require_sc local-path
# 4 pods = 4 nœuds distincts (anti-affinité) : il faut au moins 4 workers schedulables.
WK=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | grep -c ' Ready ' || true)
[ "${WK:-0}" -ge 4 ] || echo "  /!\\ Seulement ${WK} worker(s) Ready — il en faut 4 (anti-affinité 1 pod/node)."

MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)}"

log "Namespace + Secret identifiants (non écrasé s'il existe)"
kubectl create namespace minio-cluster --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl -n minio-cluster get secret minio-creds >/dev/null 2>&1; then
  kubectl -n minio-cluster create secret generic minio-creds \
    --from-literal=root-user="${MINIO_ROOT_USER}" \
    --from-literal=root-password="${MINIO_ROOT_PASSWORD}"
  echo "    Secret minio-creds créé."
else
  echo "    Secret minio-creds déjà présent (conservé)."
fi

log "MinIO distribué (StatefulSet 4 nœuds) + Services + HTTPRoutes"
# Le manifeste porte les hostnames des HTTPRoutes + MINIO_BROWSER_REDIRECT_URL.
render "${HERE}/minio-cluster.yaml" | kubectl apply -f -
kubectl -n minio-cluster rollout status statefulset/minio --timeout=300s

log "MinIO cluster installé."
echo "  API S3   : https://minio-cluster.${LAB_DOMAIN}"
echo "  Console  : https://minio-cluster-console.${LAB_DOMAIN}"
echo "  User     : $(kubectl -n minio-cluster get secret minio-creds -o jsonpath='{.data.root-user}' | base64 -d)"
echo "  Password : $(kubectl -n minio-cluster get secret minio-creds -o jsonpath='{.data.root-password}' | base64 -d)"
echo "  Erasure  : mc admin info <alias>   (4 drives online, tolère ~2 nœuds down)"
