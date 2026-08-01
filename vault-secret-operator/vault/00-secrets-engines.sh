#!/usr/bin/env bash
# Enables the secrets engines the VSO CRDs consume: KV-v2 (static), database (dynamic), pki
# (certificates), transit (client cache encryption).
# Idempotent: safe to re-run (the "already in use" errors are ignored).
#
# Prerequisites: VAULT_ADDR + VAULT_TOKEN (an admin token) exported, or run inside a Vault pod.
#   export VAULT_ADDR=https://vault.lab.example.io      # or http://127.0.0.1:8200 with a port-forward
#   export VAULT_TOKEN=<root-or-admin>
#   ./vault-secret-operator/vault/00-secrets-engines.sh <talos|kubeadm>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
. "${HERE}/../../lib/common.sh"
k8s_init "$@"
# LAB_DOMAIN (default <distro>.lab.example.io) is used as the `common_name` of the PKI root CA
# and as `allowed_domains` on the `demo` role.

# The `vault` CLI talks to Vault's API: without it, nothing below works.
need vault

enable() { vault secrets enable "$@" 2>/dev/null || echo "  (already enabled: $*)"; }

echo "==> [KV-v2] kvv2/ (static secrets)"
enable -path=kvv2 -version=2 kv
# Example secret the VaultStaticSecret will read (k8s/10-static-kv.yaml):
vault kv put kvv2/demo/app username="app" password="s3cr3t-demo-value"

echo "==> [database] db/ (ephemeral credentials)"
enable database
# NB: the connection + the role depend on YOUR database. PostgreSQL example (to adapt):
#   vault write db/config/demo-postgres \
#     plugin_name=postgresql-database-plugin \
#     allowed_roles="demo-app" \
#     connection_url="postgresql://{{username}}:{{password}}@postgres.demo.svc:5432/app?sslmode=disable" \
#     username="vault_admin" password="<pg_admin_pwd>"
#   vault write db/roles/demo-app \
#     db_name=demo-postgres \
#     creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
#     default_ttl=1h max_ttl=24h

echo "==> [pki] pki/ (TLS certificates)"
enable -path=pki pki
vault secrets tune -max-lease-ttl=87600h pki
# Demo root CA (in production: an intermediate CA signed by an offline root).
vault write -field=certificate pki/root/generate/internal \
  common_name="${LAB_DOMAIN}" ttl=87600h >/dev/null || echo "  (root CA already generated)"
vault write pki/config/urls \
  issuing_certificates="${VAULT_ADDR}/v1/pki/ca" \
  crl_distribution_points="${VAULT_ADDR}/v1/pki/crl"
# PKI role "demo": bounds the domains and the lifetime. The VaultPKISecret issues through it.
vault write pki/roles/demo \
  allowed_domains="${LAB_DOMAIN}" allow_subdomains=true \
  max_ttl=72h key_type=rsa key_bits=2048

echo "==> [transit] transit/ (VSO client cache encryption)"
enable transit
vault write -f transit/keys/vso-client-cache >/dev/null || echo "  (transit key already created)"

echo "==> Engines ready."
