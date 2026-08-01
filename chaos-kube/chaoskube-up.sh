#!/usr/bin/env bash
#
# chaoskube-up.sh — installs chaoskube (chaos engineering) on the cluster.
#
#   ./chaos-kube/chaoskube-up.sh <talos|kubeadm>
# Kills ONE random pod every hour, everywhere EXCEPT kube-system and longhorn-system.
#
# Standalone add-on: platform-up.sh only lays down Cilium + Envoy + metrics + wildcard TLS.
# No UI, hence no HTTPRoute: chaoskube is only observable through its logs (and the Events it
# creates on the deleted pods).
#
# ⚠️ THIS ADD-ON DELETES PODS CONTINUOUSLY. That is its job, but it has a price:
#   - anything not driven by a controller (a bare pod) NEVER comes back;
#   - Vault comes back SEALED every time a pod is killed (no auto-unseal in this lab) — you
#     have to re-run ../vault-cluster/vault-up.sh to unseal it again.
# To stop the bleeding without uninstalling: see the end of this script.
#
# Prerequisites: a Ready cluster, kubectl + helm. No storage, no Gateway.
# Idempotent: `helm upgrade --install`, safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Pinned versions (overridable through an environment variable) -----------
CHAOSKUBE_VERSION="${CHAOSKUBE_VERSION:-0.6.0}"
NS="${NS:-chaos-kube}"
# CHAOS_DRY_RUN=1: installs chaoskube in observation mode (it logs "would kill …" and deletes
# nothing). Useful to check what it WOULD target before letting it loose.
CHAOS_DRY_RUN="${CHAOS_DRY_RUN:-0}"

# --- Prerequisites ----------------------------------------------------------
need kubectl helm
require_apiserver

# ============================================================================
log "chaoskube ${CHAOSKUBE_VERSION} (namespace ${NS})"
helm repo add chaoskube https://linki.github.io/chaoskube/ >/dev/null 2>&1 || true
helm repo update chaoskube >/dev/null

# Going back to dry-run means REMOVING the `no-dry-run` key, not setting it to false: the
# chart template does `range $key, $value` and emits `--$key` as soon as the value is empty OR
# null. So `--set …no-dry-run=null` leaves the flag in place (verified with `helm template`),
# and `--no-dry-run=false` does not exist on the chaoskube side. So we render the values into
# a temp file, one line short.
VALUES="$(mktemp)"; trap 'rm -f "$VALUES"' EXIT
if [ "$CHAOS_DRY_RUN" = "1" ]; then
  sed '/^ *no-dry-run:/d' "${HERE}"/values.yaml > "$VALUES"
  echo "    CHAOS_DRY_RUN=1: observation mode, no pod will be deleted."
else
  cat "${HERE}"/values.yaml > "$VALUES"
fi

helm upgrade --install chaoskube chaoskube/chaoskube \
  --namespace "$NS" --create-namespace \
  --version "${CHAOSKUBE_VERSION}" \
  --values "$VALUES" \
  --wait --timeout 5m
kubectl -n "$NS" rollout status deploy/chaoskube --timeout=180s

# ============================================================================
# We re-read the flags ACTUALLY in place rather than echoing values.yaml back: that is the
# only proof the exclusion and the no-dry-run really landed in the pod. Everything below
# derives from THOSE flags — a hard-coded summary would start lying the moment values.yaml is
# edited.
active_args="$(kubectl -n "$NS" get deploy chaoskube \
  -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}')"
exclusions="$(printf '%s\n' "$active_args" | sed -n 's/^--namespaces=//p')"
interval="$(printf '%s\n' "$active_args" | sed -n 's/^--interval=//p')"

log "Active flags (read from the Deployment)"
printf '    %s\n' $active_args

# ============================================================================
log "chaoskube installed."
echo "  Target   : every namespace, filter '${exclusions}'"
echo "  Cadence  : 1 pod deleted every ${interval:-?}"
echo "  Logs     : kubectl -n ${NS} logs -f deploy/chaoskube"
echo "  Victims  : kubectl get events -A --field-selector reason=Killing --sort-by=.lastTimestamp"
echo
echo "  Pause it (without uninstalling):"
echo "    kubectl -n ${NS} scale deploy/chaoskube --replicas=0"
echo "  Back to observation only:"
echo "    CHAOS_DRY_RUN=1 ./chaos-kube/chaoskube-up.sh"
echo "  Uninstall:"
echo "    helm -n ${NS} uninstall chaoskube"
echo
# Guard rail, off the same source as the summary above: we warn when a fragile namespace of
# the lab exists in the cluster without being excluded.
# vault: comes back sealed. cnpg-demo: the demo Postgres. Both are excluded by default.
for fragile in vault cnpg-demo; do
  kubectl get ns "$fragile" >/dev/null 2>&1 || continue
  case ",${exclusions}," in
    *",!${fragile},"*) continue ;;
  esac
  echo "  /!\\ Namespace '${fragile}' exists and is NOT excluded (${exclusions})."
  [ "$fragile" = "vault" ] && \
    echo "      Every Vault pod killed comes back SEALED: ./vault-cluster/vault-up.sh to unseal."
  echo "      To spare it: add ',!${fragile}' to chaoskube.args.namespaces in"
  echo "      chaos-kube/values.yaml, then re-run this script."
done
