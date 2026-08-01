#!/usr/bin/env bash
#
# observability-up.sh — installs the lab's observability stack:
#   metrics (kube-prometheus-stack: Prometheus + Grafana + Alertmanager)
#   + logs (single-binary Loki + Grafana Alloy as the collector).
#
# Order:
#   1. kube-prometheus-stack   Prometheus (+ CRDs), Grafana, Alertmanager, exporters
#   2. Loki                    log storage (single binary, filesystem on Longhorn)
#   3. Alloy                   collects the pods' logs → Loki
#   4. HTTPRoutes              grafana / prometheus / alertmanager .$LAB_DOMAIN
#
# Prerequisites: platform in place (Cilium + Envoy Gateway + cert-manager), Longhorn + the
# `longhorn-r1` StorageClass (laid down by the longhorn/ add-on).
#   ./observability/observability-up.sh <talos|kubeadm>
#
# ⚠️ The control-plane monitors (etcd, scheduler, controller-manager) are only scrapable on
#    kubeadm in this lab (KPS_SCRAPE_CONTROL_PLANE from the profile):
#      kubeadm: `bind-address: 0.0.0.0` on scheduler/controller-manager and
#               `listen-metrics-urls: http://0.0.0.0:2381` on etcd, set at bootstrap;
#      talos  : components not exposed without dedicated TLS configuration -> monitors turned
#               off, otherwise Prometheus shows unexplainable "down" targets during training.
#
# Idempotent: `helm upgrade --install` + `kubectl apply`. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Pinned versions (overridable through an environment variable) -----------
KPS_VERSION="${KPS_VERSION:-88.0.1}"          # kube-prometheus-stack (app Prometheus Operator v0.93.0)
LOKI_VERSION="${LOKI_VERSION:-7.2.0}"          # app Loki v3.6.11
ALLOY_VERSION="${ALLOY_VERSION:-1.11.0}"       # app Alloy v1.18.0

need kubectl helm
require_apiserver
require_sc longhorn-r1

# ============================================================================
log "[0/4] monitoring namespace (PodSecurity privileged for node-exporter + Alloy)"
kubectl apply -f "${HERE}/namespace.yaml"

log "[1/4] kube-prometheus-stack ${KPS_VERSION} (Prometheus + Grafana + Alertmanager)"
distro_summary
echo "    control-plane monitors: ${KPS_SCRAPE_CONTROL_PLANE}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
# The values carry the domain (Grafana domain/root_url, externalUrl): rendered into a temp file.
KPS_VALUES="$(mktemp)"; trap 'rm -f "$KPS_VALUES"' EXIT
render "${HERE}/kube-prometheus-stack-values.yaml" > "$KPS_VALUES"
# The values carry the control-plane monitors ENABLED (the kubeadm case); on Talos the profile
# turns them off here — a single values file for both distributions.
kps_sets=()
if [ "$KPS_SCRAPE_CONTROL_PLANE" != "true" ]; then
  kps_sets=(--set kubeControllerManager.enabled=false
            --set kubeScheduler.enabled=false
            --set kubeEtcd.enabled=false)
fi
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --version "${KPS_VERSION}" \
  --values "$KPS_VALUES" ${kps_sets[@]+"${kps_sets[@]}"}
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana --timeout=300s

log "[2/4] Loki ${LOKI_VERSION} (single binary, filesystem on Longhorn)"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update grafana >/dev/null
helm upgrade --install loki grafana/loki -n monitoring \
  --version "${LOKI_VERSION}" \
  --values "${HERE}/loki-values.yaml"
kubectl -n monitoring rollout status statefulset/loki --timeout=300s || true

log "[3/4] Grafana Alloy ${ALLOY_VERSION} (collects /var/log/pods logs → Loki)"
helm upgrade --install alloy grafana/alloy -n monitoring \
  --version "${ALLOY_VERSION}" \
  --values "${HERE}/alloy-values.yaml"
kubectl -n monitoring rollout status daemonset/alloy --timeout=180s || true

log "[4/4] HTTPRoutes (grafana / prometheus / alertmanager .${LAB_DOMAIN})"
render "${HERE}/httproutes.yaml" | kubectl apply -f -

# ============================================================================
log "Observability installed."
echo "  Grafana      : https://grafana.${LAB_DOMAIN}  (admin / prom-operator — CHANGE IT)"
echo "  Prometheus   : https://prometheus.${LAB_DOMAIN}"
echo "  Alertmanager : https://alertmanager.${LAB_DOMAIN}"
echo "  Datasources  : Prometheus (auto) + Loki (http://loki-gateway) → Explore tab for the logs"
echo "  Test         : curl --resolve grafana.${LAB_DOMAIN}:443:192.168.56.200 https://grafana.${LAB_DOMAIN}/api/health"
