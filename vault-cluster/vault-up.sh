#!/usr/bin/env bash
#
# vault-up.sh — installs HashiCorp Vault in HA (integrated Raft, 3 replicas) on the Talos or
# kubeadm cluster, on Longhorn storage, and exposes the UI/API over HTTPS at vault.$LAB_DOMAIN.
#
#   ./vault-cluster/vault-up.sh <talos|kubeadm>   (or ./install.sh <distro> vault)
#
# Standalone add-on: platform-up.sh only lays down Cilium + Envoy + metrics + the wildcard TLS.
#
# ⚠️ SECRETS. `vault operator init` produces 5 unseal keys + the root token. This script
# writes them to `_out/vault-init.json` (a gitignored directory, file mode 0600) and NEVER
# prints them — not on stdout, not in a log. It is the only copy: losing that file means Vault
# is permanently inaccessible. Moving it out of `_out/` means moving it out of the gitignore,
# hence a risk of committing it.
#
# Unsealing: the chart ALWAYS comes back sealed after a pod restart (upgrade, node reboot,
# `vagrant halt`/`vagrant up`, Talos reset). This script re-unseals whatever needs it on every
# run, as long as `_out/vault-init.json` is there. There is no auto-unseal in this lab (it
# would need an external Transit engine or a cloud KMS): so it has to be re-run after a reboot.
#
# Prerequisites: Longhorn (SC `longhorn`), platform in place (main-gateway + wildcard), jq.
# Idempotent: initialises only if Vault is not, unseals only the sealed pods.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Pinned versions (overridable through an environment variable) -----------
VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-0.34.0}"
NS="${NS:-vault}"
REPLICAS=3                       # aligned with values.yaml (server.ha.replicas)
INIT_FILE="${INIT_FILE:-${LAB_DIR}/_out/vault-init.json}"

# --- Prerequisites ----------------------------------------------------------
need kubectl helm jq
require_apiserver
# The `longhorn` StorageClass carries the 3 Raft PVCs: without it the pods stay Pending.
require_sc longhorn

# `vault status` exits 2 when Vault is sealed: hence `|| true`, otherwise `set -e` kills the
# script.
vault_status() { kubectl -n "$NS" exec "$1" -- vault status -format=json 2>/dev/null || true; }
# jq TRAP: the `//` operator treats `false` as empty, exactly like `null`. `.sealed // true`
# therefore returns `true` on an UNSEALED pod (.sealed=false) — we thought the pod was sealed,
# and the following `unseal` failed with a 400 "already unsealed". Hence `tostring`, which
# tells false apart from null. Returns "true" | "false" | "null".
vault_field() { vault_status "$1" | jq -r ".$2 | tostring" 2>/dev/null || echo null; }
# BOUNDED wait for the Raft `retry_join`: vault-1/2 start UNinitialised and only become
# initialised after joining the unsealed leader. Unsealing them before that fails with a 400
# "Vault is not initialized" — the race that broke the very first run.
wait_initialised() {
  local pod="$1" limit="${2:-180}" t=0
  until [ "$(vault_field "$pod" initialized)" = "true" ]; do
    t=$((t + 5)); [ "$t" -ge "$limit" ] && { echo "ERROR: ${pod} did not join the Raft after ${limit}s." >&2
      echo "        Check the retry_join: kubectl -n ${NS} logs ${pod} | tail -30" >&2; exit 1; }
    sleep 5
  done
}
# BOUNDED wait for a pod to reach Running (Vault pods NEVER become Ready while sealed: waiting
# for `condition=Ready` would block here for nothing).
wait_running() {
  local pod="$1" limit="${2:-180}" t=0
  until [ "$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ]; do
    t=$((t + 5)); [ "$t" -ge "$limit" ] && { echo "ERROR: ${pod} not Running after ${limit}s." >&2; \
      kubectl -n "$NS" get pod "$pod" >&2 || true; exit 1; }
    sleep 5
  done
}

# ============================================================================
log "[1/4] Vault chart ${VAULT_CHART_VERSION} (HA Raft ${REPLICAS} replicas, SC longhorn)"
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null
# NO --wait: the pods stay `0/1 Running` (readiness failing) as long as Vault is neither
# initialised nor unsealed — `--wait` would time out every single time.
helm upgrade --install vault hashicorp/vault \
  --namespace "$NS" --create-namespace \
  --version "${VAULT_CHART_VERSION}" \
  --values "${HERE}"/values.yaml
wait_running vault-0 300

# ============================================================================
log "[2/4] Initialisation (5 keys, threshold 3)"
if [ "$(vault_field vault-0 initialized)" = "true" ]; then
  echo "    Vault is already initialised — we touch nothing."
  [ -f "$INIT_FILE" ] || echo "    /!\\ ${INIT_FILE} missing: the unsealing below will have to be done by hand."
else
  [ -f "$INIT_FILE" ] && { echo "ERROR: Vault is not initialised but ${INIT_FILE} already exists." >&2
    echo "        Overwriting that file would lose the keys it holds. Move it, then re-run." >&2
    exit 1; }
  mkdir -p "$(dirname "$INIT_FILE")"
  # umask BEFORE the redirection: the file is born 0600, never readable as 0644 even for a
  # fraction of a second. The keys never transit through stdout.
  ( umask 077 && kubectl -n "$NS" exec vault-0 -- \
      vault operator init -key-shares=5 -key-threshold=3 -format=json > "$INIT_FILE" )
  echo "    Keys + root token written to ${INIT_FILE} (0600, _out/ is gitignored)."
  echo "    It is the ONLY copy: back it up outside the repository."
fi

# ============================================================================
log "[3/4] Unsealing the ${REPLICAS} pods"
if [ -f "$INIT_FILE" ]; then
  for n in $(seq 0 $((REPLICAS - 1))); do
    pod="vault-${n}"
    # vault-1/2 only exist once the StatefulSet has rolled out: we wait for them, then wait
    # for them to have joined the Raft (otherwise a 400 "not initialized").
    wait_running "$pod" 300
    wait_initialised "$pod" 300
    if [ "$(vault_field "$pod" sealed)" = "false" ]; then
      echo "    ${pod}: already unsealed"
      continue
    fi
    # 3 distinct keys = the threshold. `>/dev/null`: the output of `unseal` re-prints the seal
    # status, not the key — but we take no chances with that stream.
    for i in 0 1 2; do
      kubectl -n "$NS" exec "$pod" -- vault operator unseal \
        "$(jq -r ".unseal_keys_b64[$i]" "$INIT_FILE")" >/dev/null
    done
    echo "    ${pod}: unsealed"
  done
  kubectl -n "$NS" wait --for=condition=Ready pod -l app.kubernetes.io/name=vault --timeout=180s
else
  echo "    ${INIT_FILE} missing: manual unsealing required (3 keys out of 5) —"
  echo "      kubectl -n ${NS} exec vault-0 -- vault operator unseal <key>"
fi

# ============================================================================
log "[4/4] HTTPRoute vault.${LAB_DOMAIN}"
# The versioned manifest carries the neutral domain: substituted on the fly, as everywhere
# else in k8s-playground/ (see ../README.md).
render "${HERE}"/httproute.yaml | kubectl apply -f -

# ============================================================================
log "Vault installed."
echo "  UI/API   : https://vault.${LAB_DOMAIN}"
echo "  Storage  : integrated Raft, 3 PVCs of 2Gi on the longhorn SC"
echo "  Root token (do NOT paste it anywhere else):"
echo "    jq -r .root_token ${INIT_FILE}"
echo "  From the host:"
echo "    export VAULT_ADDR=https://vault.${LAB_DOMAIN}"
echo "    export VAULT_TOKEN=\$(jq -r .root_token ${INIT_FILE})"
echo
echo "  /!\\ No auto-unseal: after a reboot or an upgrade the pods come back SEALED."
echo "      Re-running this script unseals them again (as long as ${INIT_FILE} exists)."
