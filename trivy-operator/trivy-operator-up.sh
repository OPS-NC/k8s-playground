#!/usr/bin/env bash
#
# trivy-operator-up.sh — installs Trivy Operator (continuous security scanner) and wires its
# reports into the Policy Reporter UI already deployed by the kyverno/ add-on.
#
#   ./trivy-operator/trivy-operator-up.sh <talos|kubeadm>
#
# ⚠️ Both "node" scanners (infra assessment + cluster compliance) go through a
#    `node-collector` pod that bind-mounts /etc/systemd, /lib/systemd, /etc/kubernetes:
#      kubeadm: those paths exist and are readable  -> scanners ENABLED
#      talos  : no systemd, / and /etc read-only    -> `CreateContainerError:
#               mkdir /etc/systemd: read-only file system` -> scanners DISABLED
#    (TRIVY_NODE_COLLECTOR from the profile; the image/config/secret/RBAC scans carry on.)
#
# Order:
#   1. Trivy Operator     scans images/configs/secrets/RBAC → report CRDs
#   2. Policy Reporter    helm upgrade to enable the trivy plugin (unified UI)
#
# Prerequisites: the kyverno/ add-on must be installed (Policy Reporter provides the UI).
# Idempotent: `helm upgrade --install`. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Pinned versions (overridable through an environment variable) -----------
TRIVY_OPERATOR_VERSION="${TRIVY_OPERATOR_VERSION:-0.34.0}"        # app v0.32.0
POLICY_REPORTER_VERSION="${POLICY_REPORTER_VERSION:-3.9.1}"

need kubectl helm
require_apiserver

# ============================================================================
log "[1/2] Trivy Operator ${TRIVY_OPERATOR_VERSION} (node scanners: ${TRIVY_NODE_COLLECTOR})"
distro_summary
helm repo add aqua https://aquasecurity.github.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update aqua >/dev/null
# values.yaml carries the "node" scanners ENABLED (the kubeadm case); the Talos profile turns
# them off here rather than maintaining two values files.
helm upgrade --install trivy-operator aqua/trivy-operator -n trivy-system --create-namespace \
  --version "${TRIVY_OPERATOR_VERSION}" \
  --values "${HERE}"/values.yaml \
  --set "operator.infraAssessmentScannerEnabled=${TRIVY_NODE_COLLECTOR}" \
  --set "operator.clusterComplianceEnabled=${TRIVY_NODE_COLLECTOR}"
kubectl -n trivy-system rollout status deploy/trivy-operator --timeout=180s

log "[2/2] Policy Reporter: enabling the trivy plugin (unified UI)"
if helm -n kyverno status policy-reporter >/dev/null 2>&1; then
  helm repo add policy-reporter https://kyverno.github.io/policy-reporter >/dev/null 2>&1 || true
  helm repo update policy-reporter >/dev/null
  helm upgrade --install policy-reporter policy-reporter/policy-reporter -n kyverno \
    --version "${POLICY_REPORTER_VERSION}" \
    --values "${HERE}"/policy-reporter-values.yaml
  kubectl -n kyverno rollout status deploy/policy-reporter-trivy-plugin --timeout=180s || true
else
  echo "    /!\\ no policy-reporter release in the kyverno ns: install ./kyverno/kyverno-up.sh first"
  echo "        Trivy Operator still works; the unified UI just will not have the trivy source."
fi

# ============================================================================
log "Trivy Operator installed."
echo "  Scans continuously → reports arrive as the scans complete (a few minutes):"
echo "    kubectl get vulnerabilityreports -A"
echo "    kubectl get configauditreports -A"
echo "    kubectl get exposedsecretreports -A"
echo "  Unified UI (Trivy source): https://kyverno.${LAB_DOMAIN}"
