#!/usr/bin/env bash
#
# kyverno-up.sh — installe Kyverno (policy engine) + Policy Reporter (UI) sur un cluster
# kubeadm déjà doté de la plateforme (Cilium + Envoy Gateway + cert-manager, cf. platform-up.sh).
#
# Ordre :
#   1. Kyverno            contrôleurs (admission/background/cleanup/reports) via Helm
#   2. Policies           ClusterPolicy pédagogiques (validate Audit + mutate + generate)
#   3. Policy Reporter    agrégation des PolicyReport + UI web
#   4. HTTPRoute          expose l'UI sous kyverno.$LAB_DOMAIN (main-gateway)
#
# Idempotent : `helm upgrade --install` + `kubectl apply`. Relançable sans casse.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Versions épinglées (overridables par variable d'env) -------------------
KYVERNO_VERSION="${KYVERNO_VERSION:-3.8.2}"            # app v1.18.2
POLICY_REPORTER_VERSION="${POLICY_REPORTER_VERSION:-3.9.1}"

# --- Pré-requis -------------------------------------------------------------
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

log "[2/4] Policies pédagogiques (validate Audit + mutate + generate)"
kubectl apply -f "${HERE}/policies/"
echo "    policies chargées :"
kubectl get clusterpolicy

log "[3/4] Policy Reporter ${POLICY_REPORTER_VERSION} + UI + plugin Kyverno"
helm repo add policy-reporter https://kyverno.github.io/policy-reporter >/dev/null 2>&1 || true
helm repo update policy-reporter >/dev/null
helm upgrade --install policy-reporter policy-reporter/policy-reporter -n kyverno \
  --version "${POLICY_REPORTER_VERSION}" \
  --values "${HERE}/policy-reporter-values.yaml"
kubectl -n kyverno rollout status deploy/policy-reporter-ui --timeout=180s

log "[4/4] HTTPRoute (kyverno.${LAB_DOMAIN})"
render "${HERE}/httproute.yaml" | kubectl apply -f -

# ============================================================================
log "Kyverno installé."
echo "  Policies    : $(kubectl get clusterpolicy --no-headers 2>/dev/null | wc -l) ClusterPolicy (validate en Audit)"
echo "  Rapports    : kubectl get policyreport -A   /   kubectl get clusterpolicyreport"
echo "  UI          : https://kyverno.${LAB_DOMAIN}  (via main-gateway, cert wildcard)"
echo "  Test        : curl --resolve kyverno.${LAB_DOMAIN}:443:192.168.56.200 https://kyverno.${LAB_DOMAIN}/"
