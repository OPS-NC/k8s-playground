#!/usr/bin/env bash
#
# node-problem-detector-up.sh — installs node-problem-detector (NPD), a DaemonSet that watches
# NODE HEALTH and surfaces problems as NodeConditions + Events.
#
#   ./node-problem-detector/node-problem-detector-up.sh <talos|kubeadm>
#
# The namespace is PodSecurity `privileged` (NPD runs privileged to read /dev/kmsg): MANDATORY
# on Talos (cluster default `baseline`), plain documentation of intent on kubeadm (no level
# enforced by default).
# Configuration reduced to the kernel-monitor (kmsg): the chart's docker/systemd monitors work
# on NEITHER of the lab's two distributions (containerd, and on Talos no systemd at all) —
# see values.yaml.
#
# Idempotent: `helm upgrade --install`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"
NPD_VERSION="${NPD_VERSION:-2.3.14}"        # app v0.8.19

need kubectl helm
require_apiserver

log "node-problem-detector namespace in PodSecurity 'privileged' (/dev/kmsg access)"
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

log "Installed."
echo "  Pods (1/node) : kubectl -n node-problem-detector get pods -o wide"
echo "  Conditions    : kubectl get nodes -o json | jq -r '.items[].status.conditions[] | select(.type|test(\"KernelDeadlock|ReadonlyFilesystem\"))'"
echo "  Node events   : kubectl get events -A --field-selector reason=OOMKilling,reason=TaskHung"
