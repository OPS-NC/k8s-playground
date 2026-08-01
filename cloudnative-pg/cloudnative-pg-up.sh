#!/usr/bin/env bash
#
# cloudnative-pg-up.sh — installs the CloudNativePG operator + a demo HA PostgreSQL cluster
# (3 nodes, 1Gi RWO on Longhorn).
#
#   ./cloudnative-pg/cloudnative-pg-up.sh <talos|kubeadm>
#
# Order:
#   1. CloudNativePG operator   (the Cluster CRD + the controller) through Helm
#   2. `pg-demo` demo cluster   (3 instances on Longhorn)
#
# Prerequisites: Longhorn installed (the `longhorn` StorageClass), see longhorn/.
# Idempotent: `helm upgrade --install` + `kubectl apply`. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Pinned versions (overridable through an environment variable) -----------
CNPG_VERSION="${CNPG_VERSION:-0.29.0}"          # app v1.30.0

need kubectl helm
require_apiserver
require_sc longhorn-r1

# ============================================================================
log "[1/2] CloudNativePG operator ${CNPG_VERSION}"
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update cnpg >/dev/null
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace \
  --version "${CNPG_VERSION}" \
  --values "${HERE}/values.yaml"
kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg --timeout=180s

log "[2/2] Demo PostgreSQL cluster (3 nodes, 1Gi RWO on Longhorn)"
kubectl apply -f "${HERE}/cluster-demo.yaml"
echo "    waiting for the cluster to become healthy (provisioning + replicas)..."
kubectl -n cnpg-demo wait --for=condition=Ready cluster/pg-demo --timeout=300s || true

# ============================================================================
log "CloudNativePG installed."
kubectl -n cnpg-demo get cluster pg-demo 2>/dev/null || true
echo "  Instances   : kubectl -n cnpg-demo get pods -l cnpg.io/cluster=pg-demo"
echo "  Services    : pg-demo-rw (primary) / pg-demo-ro (replicas) / pg-demo-r (all)"
echo "  Credentials : kubectl -n cnpg-demo get secret pg-demo-app -o jsonpath='{.data.uri}' | base64 -d"
echo "  Status      : kubectl cnpg status pg-demo -n cnpg-demo   (kubectl-cnpg plugin)"
