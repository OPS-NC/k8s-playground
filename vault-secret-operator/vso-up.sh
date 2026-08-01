#!/usr/bin/env bash
#
# vso-up.sh — installs the Vault Secrets Operator (VSO), and NOTHING ELSE.
#
#   ./vault-secret-operator/vso-up.sh <talos|kubeadm>   (or ./install.sh <distro> vso)
#
# ⚠️ THIS SCRIPT ONLY LAYS DOWN THE "OPERATOR" HALF OF THE SETUP, and that is deliberate.
#    The Vault ↔ Kubernetes integration is wired on BOTH sides, in this order:
#
#      1. VAULT side    — kubernetes auth, engines, policies, roles.  vault/*.sh
#         Needs VAULT_ADDR + an admin VAULT_TOKEN: a credential that has no business in an
#         install script `install.sh all` runs in a loop.
#      2. OPERATOR side — the chart. That is THIS script, and only that.
#      3. KUBERNETES side — the CRs (VaultConnection, VaultAuth, VaultStaticSecret…).
#         They are useless until step 1 has created the matching role: VSO connects, Vault
#         refuses, and the Secret is never filled.
#
#    The operator alone is inert and harmless: it waits for CRs. Laying it down here makes the
#    catalogue honest (`./install.sh list` shows it) without pretending the integration is
#    done. Steps 1 and 3 stay explicit commands, documented in vault/README.md and
#    k8s/README.md — and repeated at the end of this script.
#
# No distribution-specific behaviour: the operator is an ordinary controller. The component's
# only divergence is cosmetic — the name of the demo KV-v2 mount (`VAULT_KV_MOUNT`:
# talos-lab / kubeadm-lab), and it only comes into play at step 1.
#
# Prerequisites: a reachable cluster. The Vault server does NOT need to be up to lay down the
# operator — it will need to be for the CRs to succeed.
# Idempotent: `helm upgrade --install`. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Pinned version (overridable through an environment variable) ------------
VSO_VERSION="${VSO_VERSION:-1.5.0}"        # app 1.5.0
NS="${NS:-vault-secrets-operator}"

need kubectl helm
require_apiserver

# ============================================================================
log "[1/1] Vault Secrets Operator ${VSO_VERSION}"
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null
# values.yaml carries no domain (the default Vault address is the in-cluster Service): applied
# as is, without going through `render`.
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace "$NS" --create-namespace \
  --version "${VSO_VERSION}" \
  --values "${HERE}/values.yaml"
kubectl -n "$NS" rollout status deploy/vault-secrets-operator-controller-manager --timeout=300s

# ============================================================================
log "Vault Secrets Operator installed — the integration itself is still to be done."
echo "  CRDs         : kubectl api-resources --api-group=secrets.hashicorp.io"
echo "  Connection   : kubectl get vaultconnection -A     (the 'default' laid down by the chart)"
echo
echo "  The two other halves are missing, in this order:"
echo "    1. Vault side (needs an admin token):"
echo "         export VAULT_ADDR=https://vault.${LAB_DOMAIN}"
echo "         export VAULT_TOKEN=\$(jq -r .root_token ${LAB_DIR}/_out/vault-init.json)"
echo "         ./vault-secret-operator/vault/00-secrets-engines.sh ${K8S_DISTRO}"
echo "         ./vault-secret-operator/vault/01-kubernetes-auth.sh ${K8S_DISTRO}"
echo "         ./vault-secret-operator/vault/02-roles.sh ${K8S_DISTRO}"
echo "       (the MODE=incluster/external of 01- is a trap: see vault/README.md)"
echo "    2. Kubernetes side, the demo CRs:"
echo "         ./vault-secret-operator/vault/lab-kv.sh ${K8S_DISTRO}"
echo "         kubectl apply -f vault-secret-operator/k8s/nginx-test-vault/nginx-test-vault.yaml"
echo "       (details: vault-secret-operator/k8s/README.md)"
