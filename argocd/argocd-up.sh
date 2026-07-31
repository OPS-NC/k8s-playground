#!/usr/bin/env bash
#
# argocd-up.sh — installe Argo CD (GitOps) et expose son UI/API en
# HTTPS sous argo.$LAB_DOMAIN via main-gateway (Envoy Gateway + cert wildcard).
#
#   ./argocd/argocd-up.sh <talos|kubeadm>     (ou ./install.sh <distro> argocd)
#
# Aucune spécificité de distribution ici : Argo CD ne touche ni à l'OS, ni aux nodes.
#
# N'est PLUS installé par platform-up.sh : Argo CD est un addon à part (comme longhorn/,
# vault-cluster/, kyverno/…). platform-up.sh ne pose que Cilium + Envoy + metrics + cert-manager.
#
# Prérequis : plateforme en place (main-gateway HTTPS + cert wildcard cert-manager).
# Idempotent : `helm upgrade --install` + `kubectl apply`. Relançable sans casse.
# À lancer depuis la racine du dépôt : ./argocd/argocd-up.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

ARGOCD_VERSION="${ARGOCD_VERSION:-10.2.2}"


need kubectl helm
exiger_apiserver

# ============================================================================
log "Argo CD ${ARGOCD_VERSION} + HTTPRoute (argo.${LAB_DOMAIN})"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
# values.yaml contient le domaine (global.domain + configs.cm.url) : rendu dans un temporaire.
VALUES="$(mktemp)"; trap 'rm -f "$VALUES"' EXIT
rendre "${HERE}"/values.yaml > "$VALUES"
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --version "${ARGOCD_VERSION}" --values "$VALUES"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
rendre "${HERE}"/httproute.yaml | kubectl apply -f -

# ============================================================================
log "Argo CD installé."
echo "  UI          : https://argo.${LAB_DOMAIN}   (user: admin)"
echo "  Mot de passe : kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo"
echo "  Test        : curl --resolve argo.${LAB_DOMAIN}:443:192.168.56.200 https://argo.${LAB_DOMAIN}/"
