#!/usr/bin/env bash
#
# argocd-up.sh — installs Argo CD (GitOps) and exposes its UI/API over HTTPS at
# argo.$LAB_DOMAIN through main-gateway (Envoy Gateway + wildcard cert).
#
#   ./argocd/argocd-up.sh <talos|kubeadm>     (or ./install.sh <distro> argocd)
#
# No distribution-specific behaviour here: Argo CD touches neither the OS nor the nodes.
#
# NOT installed by platform-up.sh any more: Argo CD is a standalone add-on (like longhorn/,
# vault-cluster/, kyverno/…). platform-up.sh only lays down Cilium + Envoy + metrics +
# cert-manager.
#
# Prerequisites: platform in place (HTTPS main-gateway + cert-manager wildcard cert).
# Idempotent: `helm upgrade --install` + `kubectl apply`. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

ARGOCD_VERSION="${ARGOCD_VERSION:-10.2.2}"

need kubectl helm
require_apiserver

# ============================================================================
log "Argo CD ${ARGOCD_VERSION} + HTTPRoute (argo.${LAB_DOMAIN})"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
# values.yaml holds the domain (global.domain + configs.cm.url): rendered into a temp file.
VALUES="$(mktemp)"; trap 'rm -f "$VALUES"' EXIT
render "${HERE}"/values.yaml > "$VALUES"
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --version "${ARGOCD_VERSION}" --values "$VALUES"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
render "${HERE}"/httproute.yaml | kubectl apply -f -

# ============================================================================
log "Argo CD installed."
echo "  UI       : https://argo.${LAB_DOMAIN}   (user: admin)"
echo "  Password : kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo"
echo "  Test     : curl --resolve argo.${LAB_DOMAIN}:443:192.168.56.200 https://argo.${LAB_DOMAIN}/"
