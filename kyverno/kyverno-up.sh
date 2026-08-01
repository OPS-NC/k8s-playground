#!/usr/bin/env bash
#
# kyverno-up.sh — installs Kyverno (the policy engine) + Policy Reporter (UI) on a cluster
# that already has the platform (Cilium + Envoy Gateway + cert-manager, see platform-up.sh).
#
# Order:
#   1. Kyverno            controllers (admission/background/cleanup/reports) through Helm
#   2. Policies           teaching ClusterPolicies (validate Audit + mutate + generate)
#   3. Policy Reporter    PolicyReport aggregation + web UI
#   4. HTTPRoute          exposes the UI at kyverno.$LAB_DOMAIN (main-gateway)
#
# Idempotent: `helm upgrade --install` + `kubectl apply`. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Pinned versions (overridable through an environment variable) -----------
KYVERNO_VERSION="${KYVERNO_VERSION:-3.8.2}"            # app v1.18.2
POLICY_REPORTER_VERSION="${POLICY_REPORTER_VERSION:-3.9.1}"

# --- Prerequisites ----------------------------------------------------------
need kubectl helm
require_apiserver

# ============================================================================
log "[1/4] Kyverno ${KYVERNO_VERSION}"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace \
  --version "${KYVERNO_VERSION}" \
  --values "${HERE}/values.yaml"
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s

log "[2/4] Teaching policies (validate Audit + mutate + generate)"
kubectl apply -f "${HERE}/policies/"
echo "    policies loaded:"
kubectl get clusterpolicy

log "[3/4] Policy Reporter ${POLICY_REPORTER_VERSION} + UI + Kyverno plugin"
helm repo add policy-reporter https://kyverno.github.io/policy-reporter >/dev/null 2>&1 || true
helm repo update policy-reporter >/dev/null
helm upgrade --install policy-reporter policy-reporter/policy-reporter -n kyverno \
  --version "${POLICY_REPORTER_VERSION}" \
  --values "${HERE}/policy-reporter-values.yaml"
kubectl -n kyverno rollout status deploy/policy-reporter-ui --timeout=180s

log "[4/4] HTTPRoute (kyverno.${LAB_DOMAIN})"
render "${HERE}/httproute.yaml" | kubectl apply -f -

# ============================================================================
log "Kyverno installed."
echo "  Policies : $(kubectl get clusterpolicy --no-headers 2>/dev/null | wc -l) ClusterPolicy (validate in Audit)"
echo "  Reports  : kubectl get policyreport -A   /   kubectl get clusterpolicyreport"
echo "  UI       : https://kyverno.${LAB_DOMAIN}  (through main-gateway, wildcard cert)"
echo "  Test     : curl --resolve kyverno.${LAB_DOMAIN}:443:192.168.56.200 https://kyverno.${LAB_DOMAIN}/"
