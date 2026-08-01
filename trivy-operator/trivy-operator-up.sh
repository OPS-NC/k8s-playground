#!/usr/bin/env bash
#
# trivy-operator-up.sh — installe Trivy Operator (scanner de sécurité continu) et branche
# ses rapports dans l'UI Policy Reporter déjà déployée par l'addon kyverno/.
#
#   ./trivy-operator/trivy-operator-up.sh <talos|kubeadm>
#
# ⚠️ Les deux scanners « node » (infra assessment + cluster compliance) passent par un pod
#    `node-collector` qui bind-monte /etc/systemd, /lib/systemd, /etc/kubernetes :
#      kubeadm : ces chemins existent et sont lisibles  -> scanners ACTIVÉS
#      talos   : pas de systemd, / et /etc en lecture seule -> `CreateContainerError:
#                mkdir /etc/systemd: read-only file system` -> scanners DÉSACTIVÉS
#    (TRIVY_NODE_COLLECTOR du profil ; les scans images/config/secrets/RBAC continuent.)
#
# Ordre :
#   1. Trivy Operator     scanne images/configs/secrets/RBAC → CRDs de rapport
#   2. Policy Reporter     helm upgrade pour activer le plugin trivy (UI unifiée)
#
# Prérequis : l'addon kyverno/ doit être installé (Policy Reporter fournit l'UI).
# Idempotent : `helm upgrade --install`. Relançable sans casse.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Versions épinglées (overridables par variable d'env) -------------------
TRIVY_OPERATOR_VERSION="${TRIVY_OPERATOR_VERSION:-0.34.0}"        # app v0.32.0
POLICY_REPORTER_VERSION="${POLICY_REPORTER_VERSION:-3.9.1}"

need kubectl helm
require_apiserver

# ============================================================================
log "[1/2] Trivy Operator ${TRIVY_OPERATOR_VERSION} (scanners node : ${TRIVY_NODE_COLLECTOR})"
distro_summary
helm repo add aqua https://aquasecurity.github.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update aqua >/dev/null
# values.yaml porte les scanners « node » ACTIVÉS (cas kubeadm) ; le profil Talos les
# coupe ici plutôt que d'entretenir deux fichiers de values.
helm upgrade --install trivy-operator aqua/trivy-operator -n trivy-system --create-namespace \
  --version "${TRIVY_OPERATOR_VERSION}" \
  --values "${HERE}"/values.yaml \
  --set "operator.infraAssessmentScannerEnabled=${TRIVY_NODE_COLLECTOR}" \
  --set "operator.clusterComplianceEnabled=${TRIVY_NODE_COLLECTOR}"
kubectl -n trivy-system rollout status deploy/trivy-operator --timeout=180s

log "[2/2] Policy Reporter : activation du plugin trivy (UI unifiée)"
if helm -n kyverno status policy-reporter >/dev/null 2>&1; then
  helm repo add policy-reporter https://kyverno.github.io/policy-reporter >/dev/null 2>&1 || true
  helm repo update policy-reporter >/dev/null
  helm upgrade --install policy-reporter policy-reporter/policy-reporter -n kyverno \
    --version "${POLICY_REPORTER_VERSION}" \
    --values "${HERE}"/policy-reporter-values.yaml
  kubectl -n kyverno rollout status deploy/policy-reporter-trivy-plugin --timeout=180s || true
else
  echo "    /!\\ release policy-reporter absente du ns kyverno : installe d'abord ./kyverno/kyverno-up.sh"
  echo "        Trivy Operator fonctionne quand même ; l'UI unifiée n'aura pas la source trivy."
fi

# ============================================================================
log "Trivy Operator installé."
echo "  Scanne en continu → les rapports arrivent au fil des scans (quelques minutes) :"
echo "    kubectl get vulnerabilityreports -A"
echo "    kubectl get configauditreports -A"
echo "    kubectl get exposedsecretreports -A"
echo "  UI unifiée (source Trivy) : https://kyverno.${LAB_DOMAIN}"
