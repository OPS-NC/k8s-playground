#!/usr/bin/env bash
# Loads the policies and creates the ROLES of the auth/kubernetes method.
# A role is a contract: "which SA, in which namespace, with which policy, for which audience".
# This is where least privilege is applied: we bind PRECISE SAs/namespaces (never "*").
#
# Prerequisites: VAULT_ADDR + VAULT_TOKEN (admin). Run after 00 and 01.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
. "${HERE}/../../lib/common.sh"
k8s_init "$@"

# The `vault` CLI talks to Vault's API: without it, nothing below works.
need vault

echo "==> Writing the policies"
vault policy write vso-static-kv    "$HERE/policies/vso-static-kv.hcl"
vault policy write vso-dynamic-db   "$HERE/policies/vso-dynamic-db.hcl"
vault policy write vso-pki          "$HERE/policies/vso-pki.hcl"
vault policy write vso-transit      "$HERE/policies/vso-transit-cache.hcl"

# Parameters shared by the application roles.
#  - bound_service_account_names/namespaces: WHO may log in (the pod's exact identity).
#  - audience: MUST match VaultAuth.spec.kubernetes.audiences on the K8s side (here "vault").
#  - a short token_ttl: an issued token is short-lived (less exposure).
APP_NS="demo"                 # namespace of the apps (k8s/00-namespace-rbac.yaml)
APP_SA="vso-app"              # ServiceAccount of the apps

echo "==> Role vso-static (KV-v2) -> SA $APP_SA / ns $APP_NS"
vault write auth/kubernetes/role/vso-static \
  bound_service_account_names="$APP_SA" \
  bound_service_account_namespaces="$APP_NS" \
  audience="vault" \
  token_policies="vso-static-kv" \
  token_ttl="15m"

echo "==> Role vso-dynamic (database)"
vault write auth/kubernetes/role/vso-dynamic \
  bound_service_account_names="$APP_SA" \
  bound_service_account_namespaces="$APP_NS" \
  audience="vault" \
  token_policies="vso-dynamic-db" \
  token_ttl="15m"

echo "==> Role vso-pki (certificates)"
vault write auth/kubernetes/role/vso-pki \
  bound_service_account_names="$APP_SA" \
  bound_service_account_namespaces="$APP_NS" \
  audience="vault" \
  token_policies="vso-pki" \
  token_ttl="15m"

# A role dedicated to THE OPERATOR, to encrypt its client cache through Transit.
# The operator's SA (VSO chart): vault-secrets-operator-controller-manager.
echo "==> Role vso-transit (the operator's client cache)"
vault write auth/kubernetes/role/vso-transit \
  bound_service_account_names="vault-secrets-operator-controller-manager" \
  bound_service_account_namespaces="vault-secrets-operator" \
  audience="vault" \
  token_policies="vso-transit" \
  token_ttl="15m"

echo "==> Roles created. Check with: vault list auth/kubernetes/role"
