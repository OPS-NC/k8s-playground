#!/usr/bin/env bash
# Vault-side configuration for PostgreSQL PASSWORD ROTATION (database engine, static role).
#
# Vault connects to the CloudNativePG `pg-demo` cluster with the ADMIN user (postgres) and
# takes over the password of the fixed PG user `vault-rotate`, which it rotates periodically.
# VSO reads `database/static-creds/vault-rotate` -> a K8s Secret -> the app (see
# ../k8s/pg-dynamic-rotate/pg-dynamic-rotate.yaml).
#
# STATIC ROLE (≠ dynamic role): the username stays `vault-rotate`, ONLY the password changes.
# The application's connection string is therefore stable, only the password is rotated.
#
# Prerequisites:
#   - A CloudNativePG `pg-demo` cluster (ns cnpg-demo) with enableSuperuserAccess=true
#     (kubectl -n cnpg-demo patch cluster pg-demo --type=merge -p '{"spec":{"enableSuperuserAccess":true}}')
#   - The `vault` database and the `vault-rotate` role (LOGIN) created in PG (see the README).
#   - VAULT_ADDR + VAULT_TOKEN (root/admin) exported; KUBECONFIG to read the admin secret.
#     export VAULT_ADDR=http://127.0.0.1:8200      # port-forward svc/vault-active
#     export VAULT_TOKEN=<root-token>
#   ./vault-secret-operator/vault/pg-dynamic-rotate.sh <talos|kubeadm>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
. "${HERE}/../../lib/common.sh"
k8s_init "$@"
# The `vault` CLI talks to Vault's API: without it, nothing below works.
need vault

: "${VAULT_ADDR:?export VAULT_ADDR}"
: "${VAULT_TOKEN:?export VAULT_TOKEN (root/admin)}"

# Tunable: the rotation frequency. Every rotation restarts the consuming pod
# (rolloutRestartTargets). Lower it (e.g. 2m) to watch the loop live.
ROTATION_PERIOD="${ROTATION_PERIOD:-3h}"

# --- Admin password (postgres) from the CNPG Secret --------------------------
SUPW="$(kubectl -n cnpg-demo get secret pg-demo-superuser -o jsonpath='{.data.password}' | base64 -d)"
[ -n "$SUPW" ] || { echo "ERROR: secret pg-demo-superuser not found (enableSuperuserAccess=true?)." >&2; exit 1; }

echo "==> 1. database/ engine"
vault secrets enable database 2>/dev/null || echo "   (database/ already enabled)"

echo "==> 2. Admin connection -> CNPG (pg-demo-rw, user postgres)"
# {{username}}/{{password}} are substituted by Vault (it could also rotate ITS OWN admin
# password through database/rotate-root/ if wanted — not done here).
vault write database/config/pg-demo \
  plugin_name=postgresql-database-plugin \
  allowed_roles="vault-rotate" \
  connection_url="postgresql://{{username}}:{{password}}@pg-demo-rw.cnpg-demo.svc.cluster.local:5432/postgres?sslmode=require" \
  username="postgres" password="$SUPW" \
  password_authentication="scram-sha-256" >/dev/null
echo "   database/config/pg-demo written"

echo "==> 3. Static role vault-rotate (rotation_period=${ROTATION_PERIOD})"
# db_name = the name of the CONNECTION (not of the database). username = the existing PG user
# to manage.
vault write database/static-roles/vault-rotate \
  db_name=pg-demo \
  username="vault-rotate" \
  rotation_period="${ROTATION_PERIOD}" >/dev/null
echo "   database/static-roles/vault-rotate written"

echo "==> 4. Policy (read access to the static-creds only)"
echo 'path "database/static-creds/vault-rotate" { capabilities = ["read"] }' \
  | vault policy write pg-rotate-demo -

echo "==> 5. auth/kubernetes role 'pg-rotate-demo' -> SA pg-rotate / ns pg-rotate-demo"
vault write auth/kubernetes/role/pg-rotate-demo \
  bound_service_account_names="pg-rotate" \
  bound_service_account_namespaces="pg-rotate-demo" \
  audience="vault" \
  token_policies="pg-rotate-demo" \
  token_ttl="15m" >/dev/null

echo "==> OK. Checks:"
echo "   vault read database/static-creds/vault-rotate     # username + current password + ttl"
echo "   vault write -f database/rotate-role/vault-rotate  # force an immediate rotation"
