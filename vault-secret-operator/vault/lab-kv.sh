#!/usr/bin/env bash
# Vault server-side configuration for the lab: Kubernetes auth + the "$VAULT_KV_MOUNT/" KV-v2
# engine (one subfolder per application) + the policy/role of the "nginx-test-vault" demo app.
#
# Idempotent: safe to re-run. Run it from the host with the vault CLI:
#   export VAULT_ADDR=https://vault.lab.example.io
#   export VAULT_TOKEN=<root-token>
#   ./vault-secret-operator/vault/lab-kv.sh <talos|kubeadm>
#
# (Vault runs IN-CLUSTER — the vault-cluster/ chart — so k8s auth is configured in in-cluster
#  mode: Vault validates SA tokens through its own delegator SA.)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
. "${HERE}/../../lib/common.sh"
k8s_init "$@"

# Name of the lab's KV-v2 engine: `talos-lab/` or `kubeadm-lab/` depending on the profile (so
# both labs can coexist inside a single Vault). The versioned files carry the NEUTRAL name
# `lab-kv` — substituted here, exactly like the domain (see lib/common.sh, `render`).
MOUNT="${VAULT_KV_MOUNT}"
# The `vault` CLI talks to Vault's API: without it, nothing below works.
need vault

: "${VAULT_ADDR:?export VAULT_ADDR (e.g. https://vault.lab.example.io)}"
: "${VAULT_TOKEN:?export VAULT_TOKEN (root token, see vault-cluster/)}"

echo "==> 1. Kubernetes auth"
vault auth enable kubernetes 2>/dev/null || echo "   (auth/kubernetes already enabled)"
# Vault being in-cluster, it reaches the API through the internal service address and uses the
# token/CA mounted in its pod + its delegator SA (vault chart: authDelegator enabled).
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" >/dev/null
echo "   auth/kubernetes configured (host=https://kubernetes.default.svc)"

echo "==> 2. KV-v2 engine ${MOUNT}/"
vault secrets enable -path="${MOUNT}" -version=2 kv 2>/dev/null \
  || echo "   (engine ${MOUNT}/ already enabled)"

echo "==> 3. Demo secrets (one subfolder per application)"
# Convention: ${MOUNT}/<app>/<logical-key>. Here, the nginx-test-vault app.
vault kv put "${MOUNT}/nginx-test-vault/config" \
  APP_GREETING="Hello from Vault" \
  APP_COLOR="blue" \
  APP_SECRET_TOKEN="s3cr3t-v1" >/dev/null
echo "   ${MOUNT}/nginx-test-vault/config written"

echo "==> 4. Policy (read access to the nginx-test-vault subfolder only)"
# The versioned policy carries the NEUTRAL mount `lab-kv`: substituted on the fly, so the
# policy is named and scoped on the profile's real mount.
sed "s/lab-kv/${MOUNT}/g" "$HERE/policies/lab-kv-nginx-test-vault.hcl" \
  | vault policy write "${MOUNT}-nginx-test-vault" -

echo "==> 5. auth/kubernetes role 'nginx-test-vault' -> SA nginx-test-vault / ns nginx-test-vault"
# bound_service_account_* = WHO may log in (the application pod's exact identity).
# The "vault" audience MUST match VaultAuth.spec.kubernetes.audiences on the K8s side.
vault write auth/kubernetes/role/nginx-test-vault \
  bound_service_account_names="nginx-test-vault" \
  bound_service_account_namespaces="nginx-test-vault" \
  audience="vault" \
  token_policies="${MOUNT}-nginx-test-vault" \
  token_ttl="15m" >/dev/null

echo "==> OK. Checks:"
echo "   vault kv get ${MOUNT}/nginx-test-vault/config"
echo "   vault read auth/kubernetes/role/nginx-test-vault"
