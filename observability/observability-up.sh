#!/usr/bin/env bash
#
# observability-up.sh — installe la pile d'observabilité du lab :
#   métriques (kube-prometheus-stack : Prometheus + Grafana + Alertmanager)
#   + logs (Loki single-binary + Grafana Alloy comme collecteur).
#
# Ordre :
#   1. kube-prometheus-stack   Prometheus (+ CRDs), Grafana, Alertmanager, exporters
#   2. Loki                    stockage de logs (single binary, filesystem sur Longhorn)
#   3. Alloy                   collecte les logs des pods → Loki
#   4. HTTPRoutes              grafana / prometheus / alertmanager .$LAB_DOMAIN
#
# Prérequis : plateforme en place (Cilium + Envoy Gateway + cert-manager), Longhorn +
# StorageClass `longhorn-r1` (posée par l'addon longhorn/).
#   ./observability/observability-up.sh <talos|kubeadm>
#
# ⚠️ Les moniteurs du control plane (etcd, scheduler, controller-manager) ne sont scrutables
#    que sur kubeadm dans ce lab (KPS_SCRAPE_CONTROL_PLANE du profil) :
#      kubeadm : `bind-address: 0.0.0.0` sur scheduler/controller-manager et
#                `listen-metrics-urls: http://0.0.0.0:2381` sur etcd, posés au bootstrap ;
#      talos   : composants non exposés sans configuration TLS dédiée -> moniteurs coupés,
#                sinon Prometheus affiche des cibles « down » inexplicables en formation.
#
# Idempotent : `helm upgrade --install` + `kubectl apply`. Relançable sans casse.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Versions épinglées (overridables par variable d'env) -------------------
KPS_VERSION="${KPS_VERSION:-88.0.1}"          # kube-prometheus-stack (app Prometheus Operator v0.93.0)
LOKI_VERSION="${LOKI_VERSION:-7.2.0}"          # app Loki v3.6.11
ALLOY_VERSION="${ALLOY_VERSION:-1.11.0}"       # app Alloy v1.18.0

need kubectl helm
require_apiserver
require_sc longhorn-r1

# ============================================================================
log "[0/4] Namespace monitoring (PodSecurity privileged pour node-exporter + Alloy)"
kubectl apply -f "${HERE}/namespace.yaml"

log "[1/4] kube-prometheus-stack ${KPS_VERSION} (Prometheus + Grafana + Alertmanager)"
distro_summary
echo "    moniteurs control-plane : ${KPS_SCRAPE_CONTROL_PLANE}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
# Les values portent le domaine (Grafana domain/root_url, externalUrl) : rendu temporaire.
KPS_VALUES="$(mktemp)"; trap 'rm -f "$KPS_VALUES"' EXIT
render "${HERE}/kube-prometheus-stack-values.yaml" > "$KPS_VALUES"
# Les values portent les moniteurs control-plane ACTIVÉS (cas kubeadm) ; sur Talos le
# profil les coupe ici — un seul fichier de values pour les deux distributions.
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

log "[2/4] Loki ${LOKI_VERSION} (single binary, filesystem sur Longhorn)"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update grafana >/dev/null
helm upgrade --install loki grafana/loki -n monitoring \
  --version "${LOKI_VERSION}" \
  --values "${HERE}/loki-values.yaml"
kubectl -n monitoring rollout status statefulset/loki --timeout=300s || true

log "[3/4] Grafana Alloy ${ALLOY_VERSION} (collecte des logs /var/log/pods → Loki)"
helm upgrade --install alloy grafana/alloy -n monitoring \
  --version "${ALLOY_VERSION}" \
  --values "${HERE}/alloy-values.yaml"
kubectl -n monitoring rollout status daemonset/alloy --timeout=180s || true

log "[4/4] HTTPRoutes (grafana / prometheus / alertmanager .${LAB_DOMAIN})"
render "${HERE}/httproutes.yaml" | kubectl apply -f -

# ============================================================================
log "Observabilité installée."
echo "  Grafana      : https://grafana.${LAB_DOMAIN}  (admin / prom-operator — À CHANGER)"
echo "  Prometheus   : https://prometheus.${LAB_DOMAIN}"
echo "  Alertmanager : https://alertmanager.${LAB_DOMAIN}"
echo "  Datasources  : Prometheus (auto) + Loki (http://loki-gateway) → onglet Explore pour les logs"
echo "  Test         : curl --resolve grafana.${LAB_DOMAIN}:443:192.168.56.200 https://grafana.${LAB_DOMAIN}/api/health"
