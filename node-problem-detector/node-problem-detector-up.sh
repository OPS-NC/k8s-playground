#!/usr/bin/env bash
#
# node-problem-detector-up.sh — installe node-problem-detector (NPD), un DaemonSet qui
# surveille la SANTÉ DES NODES et remonte les problèmes en NodeConditions + Events.
#
#   ./node-problem-detector/node-problem-detector-up.sh <talos|kubeadm>
#
# Namespace en PodSecurity `privileged` (NPD tourne en privileged pour lire /dev/kmsg) :
# INDISPENSABLE sur Talos (défaut cluster `baseline`), simple documentation d'intention sur
# kubeadm (aucun niveau appliqué par défaut).
# Config réduite au kernel-monitor (kmsg) : les moniteurs docker/systemd du chart ne
# fonctionnent sur AUCUNE des deux distributions du lab (containerd et, sur Talos, pas de
# systemd du tout) — cf. values.yaml.
#
# Idempotent : `helm upgrade --install`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"
NPD_VERSION="${NPD_VERSION:-2.3.14}"        # app v0.8.19

need kubectl helm
exiger_apiserver

log "Namespace node-problem-detector en PodSecurity 'privileged' (accès /dev/kmsg)"
kubectl create namespace node-problem-detector --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace node-problem-detector \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged --overwrite

log "node-problem-detector ${NPD_VERSION}"
helm repo add deliveryhero https://charts.deliveryhero.io/ >/dev/null 2>&1 || true
helm repo update deliveryhero >/dev/null
helm upgrade --install node-problem-detector deliveryhero/node-problem-detector \
  -n node-problem-detector --version "${NPD_VERSION}" \
  --values "${HERE}/values.yaml"
kubectl -n node-problem-detector rollout status daemonset/node-problem-detector --timeout=120s

log "Installé."
echo "  Pods (1/node) : kubectl -n node-problem-detector get pods -o wide"
echo "  Conditions    : kubectl get nodes -o json | jq -r '.items[].status.conditions[] | select(.type|test(\"KernelDeadlock|ReadonlyFilesystem\"))'"
echo "  Events node   : kubectl get events -A --field-selector reason=OOMKilling,reason=TaskHung"
