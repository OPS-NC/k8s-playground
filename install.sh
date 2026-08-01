#!/usr/bin/env bash
#
# install.sh — the single entry point for this repository's Kubernetes resources.
#
#   ./install.sh <talos|kubeadm> <component...>
#
# Examples:
#   ./install.sh talos platform                 # the base platform on the Talos lab
#   ./install.sh kubeadm platform longhorn      # platform, then block storage
#   ./install.sh talos list                     # what can be installed
#   ./install.sh kubeadm all                    # platform + every add-on, in order
#
# The distribution is the FIRST argument, because it is the only thing that genuinely changes
# from one lab to the other (see lib/profiles/). It is forwarded to every component script,
# each of which stays runnable on its own:
#   ./longhorn/longhorn-up.sh talos
#
# Nothing is installed behind your back: every component has its directory, its script and its
# README with the STEP-BY-STEP version of the very same commands (useful for training).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${HERE}/lib/common.sh"

# --- Catalogue ---------------------------------------------------------------
# alias|script|description  — the order is the recommended install order (`all`).
CATALOGUE=(
  "platform|platform-up.sh|CNI + Envoy Gateway + metrics-server + wildcard TLS (the base)"
  "cilium|cilium/cilium-up.sh|Cilium CNI + LoadBalancer IP pool + L2 announcement (ARP)"
  "calico|calico/calico-up.sh|Calico CNI through the Tigera operator (alternative, no L2)"
  "metallb|metallb/metallb-up.sh|MetalLB in L2 mode: LoadBalancer IPs when the CNI is NOT Cilium"
  "self-signed|self-signed/selfsigned-up.sh|local CA + self-signed wildcard TLS (openssl)"
  "longhorn|longhorn/longhorn-up.sh|replicated block storage + longhorn-r1 StorageClass"
  "local-path|local-path-storage/local-path-up.sh|dynamic local storage (hostPath)"
  "minio|minio-s3/minio-up.sh|standalone MinIO (S3 + console)"
  "minio-cluster|minio-s3/cluster/minio-cluster-up.sh|distributed 4-node MinIO (backup target)"
  "velero|velero/velero-up.sh|Velero: backs up the K8s objects AND the PV data to MinIO"
  "cnpg|cloudnative-pg/cloudnative-pg-up.sh|PostgreSQL HA operator + demo cluster"
  "keycloak|keycloak/keycloak-up.sh|Keycloak through its operator + 'lab' realm (OIDC IdP)"
  "dex|dex/dex-up.sh|Dex in front of Keycloak: kubectl login over OIDC (oidc-login)"
  "vault|vault-cluster/vault-up.sh|HashiCorp Vault HA (Raft) + HTTPS UI"
  "vso|vault-secret-operator/vso-up.sh|Vault Secrets Operator (the operator ONLY, see its README)"
  "observability|observability/observability-up.sh|kube-prometheus-stack + Loki + Alloy"
  "npd|node-problem-detector/node-problem-detector-up.sh|node-problem-detector (node health)"
  "kyverno|kyverno/kyverno-up.sh|Kyverno + Policy Reporter (policies in Audit)"
  "trivy|trivy-operator/trivy-operator-up.sh|Trivy Operator (CVEs, config, secrets, RBAC)"
  "argocd|argocd/argocd-up.sh|Argo CD (GitOps) + HTTPS UI"
  "chaos|chaos-kube/chaoskube-up.sh|chaoskube: deletes 1 random pod every hour"
)

usage() {
  cat <<EOF
Usage: ./install.sh <talos|kubeadm> <component...>
       ./install.sh <talos|kubeadm> list
       ./install.sh <talos|kubeadm> all

Components:
$(for e in "${CATALOGUE[@]}"; do printf '  %-14s %s\n' "${e%%|*}" "${e##*|}"; done)

Useful variables:
  LAB_DOMAIN=...     domain of the UIs (default: <distro>.lab.example.io)
  LAB_ENV=...        path to the Vagrant lab's lab.env (default: detected in ../<lab>/)
  KUBECONFIG=...     default: <lab>/kubeconfig
  SELF_SIGNED=false  wildcard TLS through cert-manager + Let's Encrypt instead of self-signed

Documentation: README.md (EN) · LISEZ-MOI.md (FR) — plus one README per directory, with the
STEP-BY-STEP install as manual commands.
EOF
}

resolve() {  # resolve ALIAS -> path of the script, or empty
  local e
  for e in "${CATALOGUE[@]}"; do
    [ "${e%%|*}" = "$1" ] && { printf '%s' "$(printf '%s' "$e" | cut -d'|' -f2)"; return; }
  done
}

# --- Arguments ---------------------------------------------------------------
[ $# -ge 1 ] || { usage; exit 1; }
k8s_init "$@"           # consumes the distro, leaves the rest in K8S_ARGS
set -- ${K8S_ARGS[@]+"${K8S_ARGS[@]}"}
[ -n "${1:-}" ] || { usage; exit 1; }

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  list)
    log "Components installable on ${K8S_DISTRO} (${DISTRO_LABEL})"
    for e in "${CATALOGUE[@]}"; do printf '  %-14s %s\n' "${e%%|*}" "${e##*|}"; done
    exit 0 ;;
esac

targets=("$@")
if [ "${1}" = "all" ]; then
  targets=()
  for e in "${CATALOGUE[@]}"; do
    case "${e%%|*}" in
      # Alternatives, not steps of `all`. `metallb` is in there for a second reason: on the
      # default CNI=cilium it REFUSES to install (two ARP announcers on one range), so an
      # unconditional `all` would always stop right there. `platform` installs it by itself
      # when — and only when — the CNI calls for it.
      calico|metallb|local-path|self-signed) continue ;;
    esac
    targets+=("${e%%|*}")
  done
fi

# Validation BEFORE installing anything: better a typo rejected right away than an `all` that
# stops halfway through.
for target in "${targets[@]}"; do
  [ -n "$(resolve "$target")" ] || { echo "ERROR: unknown component '${target}'." >&2; usage >&2; exit 1; }
done

log "Target: ${K8S_DISTRO} (${DISTRO_LABEL}) — ${#targets[@]} component(s): ${targets[*]}"
distro_summary

for target in "${targets[@]}"; do
  script="$(resolve "$target")"
  log "▶ ${target} — ${script}"
  bash "${REPO_ROOT}/${script}" "$K8S_DISTRO"
done

log "Done: ${targets[*]}"
