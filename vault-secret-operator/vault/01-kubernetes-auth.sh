#!/usr/bin/env bash
# Enables and configures Vault's Kubernetes auth method (auth/kubernetes).
# That is what lets VSO prove its identity to Vault through a ServiceAccount token, validated
# by the cluster's TokenReview API.
#
# TWO MODES, depending on where Vault runs:
#   A) Vault IN-CLUSTER: Vault uses its own SA (the delegator) as the reviewer. Minimal config.
#   B) Vault EXTERNAL  : kubernetes_host + kubernetes_ca_cert + token_reviewer_jwt must be
#      supplied.
#
# Prerequisites: VAULT_ADDR + VAULT_TOKEN (admin) exported. Pick the mode with
# MODE=incluster|external.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
. "${HERE}/../../lib/common.sh"
k8s_init "$@"

# The `vault` CLI talks to Vault's API: without it, nothing below works.
need vault

MODE="${MODE:-incluster}"
# The lab's apiserver VIP: keepalived on kubeadm, the Talos VIP (talos/patch-cp.yaml) on
# Talos — the same address in both labs, read from lab.env if it was changed.
KUBE_HOST="${KUBE_HOST:-https://$(read_param VIP "$DEFAULT_VIP"):6443}"

vault auth enable kubernetes 2>/dev/null || echo "  (auth/kubernetes already enabled)"

case "$MODE" in
  incluster)
    # Vault runs inside the cluster. Its ServiceAccount must have system:auth-delegator (the
    # hashicorp/vault chart does that through server.authDelegator.enabled=true, on by
    # default). Without token_reviewer_jwt/host/ca_cert, Vault uses ITS pod's token + the
    # CA/host mounted in the container (`disable_local_ca_jwt` stays false, its default: that
    # is exactly what allows Vault to read
    # /var/run/secrets/kubernetes.io/serviceaccount/ inside its container).
    #
    # We do NOT set `issuer=`: since Vault >= 1.9, `disable_iss_validation` defaults to true,
    # so the token's `iss` claim is not compared. That is the only sane configuration here,
    # because both distributions issue SA tokens with the issuer
    # `https://kubernetes.default.svc.cluster.local` (the `--service-account-issuer` default,
    # not overridden by the labs) while `kubernetes_host` is `https://kubernetes.default.svc`:
    # pinning `issuer=` to either one would break the login as soon as the upstream default
    # moved.
    echo "==> [in-cluster mode] configuring auth/kubernetes (Vault uses its own delegator SA)"
    # CAREFUL: this script runs from the HOST (the vault CLI), not inside a pod.
    # The "https://\$KUBERNETES_PORT_443_TCP_ADDR:443" form comes from the HashiCorp docs,
    # where it is executed INSIDE a `kubectl exec … sh -c`: it is the pod's shell that
    # interpolates the variable. Here, Vault received and stored the LITERAL string
    # (`$KUBERNETES_PORT_443_TCP_ADDR` unresolved) => every login through auth/kubernetes
    # failed on DNS resolution. So we use the stable service name, resolved by the Vault pod
    # itself (same as vault/lab-kv.sh).
    vault write auth/kubernetes/config \
      kubernetes_host="https://kubernetes.default.svc"
    ;;
  external)
    # Vault outside the cluster: it cannot work out host/CA/reviewer on its own.
    # 1) On the K8s side, create a "vault-auth" delegator SA + its long-lived token (see the
    #    notes below).
    # 2) Provide its JWT (SA_JWT), the K8s API CA (SA_CA_CRT) and the endpoint here.
    : "${SA_JWT:?export SA_JWT = token of the vault-auth delegator SA}"
    : "${SA_CA_CRT:?export SA_CA_CRT = CA of the Kubernetes API (PEM)}"
    echo "==> [external mode] configuring auth/kubernetes (explicit reviewer JWT)"
    vault write auth/kubernetes/config \
      kubernetes_host="$KUBE_HOST" \
      kubernetes_ca_cert="$SA_CA_CRT" \
      token_reviewer_jwt="$SA_JWT"
    # On the K8s side, prepare the reviewer (run with kubectl BEFORE this script):
    #   kubectl create sa vault-auth -n vault-secrets-operator
    #   kubectl create clusterrolebinding vault-auth-delegator \
    #     --clusterrole=system:auth-delegator \
    #     --serviceaccount=vault-secrets-operator:vault-auth
    #   SA_CA_CRT="$(kubectl get cm kube-root-ca.crt -n vault-secrets-operator -o jsonpath='{.data.ca\.crt}')"
    #   SA_JWT="$(kubectl create token vault-auth -n vault-secrets-operator --duration=8760h)"
    # ⚠️ Do NOT force `--audience` here: both labs leave `--api-audiences` at its default, i.e.
    #    the single value `https://kubernetes.default.svc.cluster.local` (the issuer). A token
    #    requested with any other audience is rejected at authentication time and Vault's
    #    TokenReview would then fail with a 401. Without `--audience`, kubectl issues the token
    #    on the apiserver's default audience: that is what is needed.
    ;;
  *) echo "unknown MODE: $MODE (incluster|external)"; exit 1 ;;
esac

# The effective host depends on the mode: in in-cluster mode, KUBE_HOST is not used (the old
# summary printed it anyway, which suggested the opposite).
case "$MODE" in
  incluster) echo "==> auth/kubernetes configured (mode=incluster, host=https://kubernetes.default.svc)." ;;
  external)  echo "==> auth/kubernetes configured (mode=external, host=$KUBE_HOST)." ;;
esac

# Check: the host actually registered on the Vault side.
vault read -field=kubernetes_host auth/kubernetes/config \
  | sed 's/^/    registered host: /'
