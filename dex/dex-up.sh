#!/usr/bin/env bash
#
# dex-up.sh — installs Dex as an OIDC broker in front of Keycloak, and prepares `kubectl`
# login over OIDC (kubelogin / `kubectl oidc-login`).
#
#   ./dex/dex-up.sh <talos|kubeadm>     (or ./install.sh <distro> dex)
#
# Standalone add-on: platform-up.sh only lays down the CNI + Envoy + metrics + wildcard TLS.
# Prerequisites: ../keycloak/ installed (the `lab` realm), platform in place.
#
# WHY DEX WHEN KEYCLOAK ALREADY SPEAKS OIDC. The API server only knows ONE issuer, frozen on
# its command line, and changing that value restarts the control plane. Dex is the
# indirection: the apiserver only ever knows `https://dex.$LAB_DOMAIN`, and everything that
# moves (adding a directory, switching realm, rotating a client secret) happens in a Dex
# ConfigMap, never on the control plane. That is also what a managed cluster (EKS/GKE) does
# behind its SSO.
#
# ⚠️ THIS SCRIPT DOES NOT TOUCH THE API SERVER. Wiring it to Dex is a CONTROL-PLANE operation:
#    it restarts it, and an unreachable `oidc-issuer-url` stops it from restarting at all —
#    an unadministrable cluster. An add-on has no business doing that quietly. So, as its last
#    step, the script prints the exact commands for the detected distribution (they come from
#    the profile: `talosctl patch mc` on Talos, the `kubeadm-config` ConfigMap +
#    `kubeadm init phase` on kubeadm). Nothing else in the component depends on it: Dex, its
#    Keycloak client and the RBAC install and can be tested without it.
#
# Order:
#   1. namespace + client secrets (generated, never versioned)
#   2. the `dex` OIDC client INSIDE Keycloak (KeycloakOIDCClient CRD)
#   3. the Dex chart (connector to the `lab` realm, `kubernetes` static client)
#   4. HTTPRoute dex.$LAB_DOMAIN + the group RBAC bindings
#   5. what is left to do by hand: wire the apiserver, then the kubeconfig
#
# Idempotent: `helm upgrade --install` + `kubectl apply`, and the client secrets are only
# generated when they do not exist — regenerating them would break the client already created
# on the Keycloak side with nothing to say so.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Pinned versions (overridable through an environment variable) -----------
DEX_VERSION="${DEX_VERSION:-0.24.1}"       # app v2.44.0
NS="${NS:-dex}"
KC_NS="${KC_NS:-keycloak}"
REALM="${REALM:-lab}"

# --- Prerequisites ----------------------------------------------------------
need kubectl helm openssl
require_apiserver
kubectl get crd keycloakoidcclients.k8s.keycloak.org >/dev/null 2>&1 \
  || fail "the Keycloak operator is missing (CRD keycloakoidcclients.k8s.keycloak.org).
        Install it first:  ./install.sh ${K8S_DISTRO} keycloak"
kubectl -n "$KC_NS" get keycloak keycloak >/dev/null 2>&1 \
  || fail "no Keycloak CR named 'keycloak' in namespace ${KC_NS}.
        Install it first:  ./install.sh ${K8S_DISTRO} keycloak"

# ============================================================================
log "[1/5] Namespace ${NS} + OIDC client secrets"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# The `dex` client secret is shared between TWO namespaces: Keycloak reads it in `keycloak`
# (the KeycloakOIDCClient CR lives there), Dex reads it in `dex`. A Secret does not cross
# namespaces — so we lay down two copies of the SAME value.
# The reference value is the one in the keycloak namespace: it is the one the operator has
# already pushed into the realm, and regenerating it would invalidate the client with no
# visible error.
if kubectl -n "$KC_NS" get secret dex-keycloak-client >/dev/null 2>&1; then
  echo "    'dex' client secret already present in ${KC_NS} — reused as is."
  KC_CLIENT_SECRET="$(kubectl -n "$KC_NS" get secret dex-keycloak-client \
    -o jsonpath='{.data.client-secret}' | base64 -d)"
else
  KC_CLIENT_SECRET="$(openssl rand -hex 32)"
  kubectl -n "$KC_NS" create secret generic dex-keycloak-client \
    --from-literal=client-secret="$KC_CLIENT_SECRET"
  echo "    'dex' client secret generated (32 bytes, never printed)."
fi
# `apply` and not `create`: the copy must converge onto the reference on every run.
kubectl -n "$NS" create secret generic dex-keycloak-client \
  --from-literal=client-secret="$KC_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

# `kubernetes` client secret: the one YOUR kubeconfig will carry. It is not strictly
# confidential (RFC 8252: a native application cannot keep a secret), but Dex requires a
# complete static client.
if kubectl -n "$NS" get secret dex-kubernetes-client >/dev/null 2>&1; then
  echo "    'kubernetes' client secret already present — reused as is."
else
  kubectl -n "$NS" create secret generic dex-kubernetes-client \
    --from-literal=client-secret="$(openssl rand -hex 32)"
  echo "    'kubernetes' client secret generated."
fi

# ============================================================================
log "[2/5] 'dex' OIDC client in the ${REALM} realm (KeycloakOIDCClient CRD)"
# The versioned manifest carries the neutral domain: substituted on the fly, as everywhere
# else in k8s-playground/ (see ../README.md).
render "${HERE}/01-keycloak-client.yaml" | kubectl apply -f -
# The `Ready` condition only shows up once the client really exists on the Keycloak side.
# `|| true`: the final summary tells the truth, and the object is reconciled continuously.
kubectl -n "$KC_NS" wait --for=condition=Ready keycloakoidcclient/dex --timeout=180s || true

# ============================================================================
log "[3/5] Dex chart ${DEX_VERSION} (connector to keycloak.${LAB_DOMAIN})"
helm repo add dex https://charts.dexidp.io >/dev/null 2>&1 || true
helm repo update dex >/dev/null
# values.yaml carries both public URLs (Dex issuer + realm issuer): rendered into a temp file,
# the versioned file is never rewritten.
VALUES="$(mktemp)"; trap 'rm -f "$VALUES"' EXIT
render "${HERE}/values.yaml" > "$VALUES"
helm upgrade --install dex dex/dex -n "$NS" \
  --version "${DEX_VERSION}" --values "$VALUES"
kubectl -n "$NS" rollout status deploy/dex --timeout=300s

# ============================================================================
log "[4/5] HTTPRoute dex.${LAB_DOMAIN} + group RBAC bindings"
render "${HERE}/httproute.yaml" | kubectl apply -f -
# rbac.yaml carries no domain: applied as is.
kubectl apply -f "${HERE}/rbac.yaml"

# ============================================================================
log "[5/5] What is left to do — wiring the API server to Dex"
echo "    ${K8S_DISTRO} mechanism : ${APISERVER_OIDC_MECHANISM}"
echo "    Patch provided          : dex/${APISERVER_OIDC_PATCH}"
echo
echo "    /!\\ These commands RESTART the API server. An unreachable issuer stops it from"
echo "        restarting. One control plane at a time, checking in between. Details and the"
echo "        SELF_SIGNED=true case: dex/README.md."
echo
apiserver_oidc_commands "${HERE}/${APISERVER_OIDC_PATCH}"

# ============================================================================
log "Dex installed."
echo "  Issuer     : https://dex.${LAB_DOMAIN}"
echo "  Discovery  : curl -s https://dex.${LAB_DOMAIN}/.well-known/openid-configuration | jq .issuer"
echo "  Upstream   : https://keycloak.${LAB_DOMAIN}/realms/${REALM}  ('dex' client)"
echo "  Groups     : oidc:k8s-admins -> cluster-admin · oidc:k8s-viewers -> view"
echo
echo "  Once the apiserver is wired, the kubectl context (kubelogin required):"
echo "    kubectl config set-credentials oidc \\"
echo "      --exec-api-version=client.authentication.k8s.io/v1beta1 \\"
echo "      --exec-command=kubectl \\"
echo "      --exec-arg=oidc-login --exec-arg=get-token \\"
echo "      --exec-arg=--oidc-issuer-url=https://dex.${LAB_DOMAIN} \\"
echo "      --exec-arg=--oidc-client-id=kubernetes \\"
echo "      --exec-arg=--oidc-client-secret=\$(kubectl -n ${NS} get secret dex-kubernetes-client -o jsonpath='{.data.client-secret}' | base64 -d) \\"
echo "      --exec-arg=--oidc-extra-scope=groups --exec-arg=--oidc-extra-scope=email"
echo "    kubectl config set-context oidc --cluster=<your-cluster> --user=oidc"
echo "    kubectl --context=oidc get nodes        # opens a browser: Keycloak, user 'demo'"
