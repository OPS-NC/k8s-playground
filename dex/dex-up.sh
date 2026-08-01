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
# shellcheck source=../lib/keycloak.sh
. "${HERE}/../lib/keycloak.sh"
k8s_init "$@"

# --- Pinned versions (overridable through an environment variable) -----------
DEX_VERSION="${DEX_VERSION:-0.24.1}"       # app v2.44.0
NS="${NS:-dex}"
KC_NS="${KC_NS:-keycloak}"
REALM="${REALM:-lab}"

# --- Prerequisites ----------------------------------------------------------
need kubectl helm openssl
require_apiserver
# `keycloaks` and not `keycloakoidcclients`: the client CRD is no longer used (see step 2), so
# its presence proves nothing we depend on. The core CRD is the real "operator installed" signal.
kubectl get crd keycloaks.k8s.keycloak.org >/dev/null 2>&1 \
  || fail "the Keycloak operator is missing (CRD keycloaks.k8s.keycloak.org).
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
log "[2/5] 'dex' OIDC client in the ${REALM} realm (kcadm)"
# ⚠️ NOT the `KeycloakOIDCClient` CRD, and that is a deliberate step BACKWARDS. Keycloak 26.7
#    ships that CRD and it would be the natural way to declare this client — it simply does not
#    work, and it fails silently: the CR applies, `kubectl apply` says `configured`, the object
#    exists, and it is never reconciled. Two independent blockers, measured on 26.7.0:
#      1. the server needs the `client-admin-api:v2` feature (see ../keycloak/02-keycloak.yaml),
#         AND the operator caches the feature list — it keeps reporting the feature as missing
#         until it is itself restarted;
#      2. past that, `KeycloakClientBaseController` looks up a Secret named
#         `<keycloak-cr-name>-admin`, while the operator's own bootstrap Secret is
#         `keycloak-initial-admin`. Supplying username/password under the expected name is not
#         enough either: the controller dies on a NullPointerException, so it wants other keys.
#    The whole failure is invisible until login time, where it surfaces as `invalid_client`.
#    A working non-reconciled client beats a declarative one that is never created; when
#    upstream fixes the CRD, this block goes away. Details: README.md.
#
# Idempotent, and it has to be: the client secret is generated once (above) and the realm may
# already hold a client carrying it. We create on first run, and re-align the mutable fields
# afterwards — never touching the secret of an existing client, which would silently
# invalidate the copy Dex reads.
DEX_REDIRECT="https://dex.${LAB_DOMAIN}/callback"
kc_wait_ready
dex_uuid="$(kc_client_uuid "$REALM" dex)"
if [ -z "$dex_uuid" ]; then
  printf '%s' "{
    \"clientId\": \"dex\",
    \"name\": \"Dex (the lab OIDC broker)\",
    \"description\": \"Confidential client used by Dex to federate the lab realm\",
    \"enabled\": true,
    \"protocol\": \"openid-connect\",
    \"publicClient\": false,
    \"secret\": \"${KC_CLIENT_SECRET}\",
    \"standardFlowEnabled\": true,
    \"directAccessGrantsEnabled\": false,
    \"implicitFlowEnabled\": false,
    \"serviceAccountsEnabled\": false,
    \"redirectUris\": [ \"${DEX_REDIRECT}\" ]
  }" | kc_adm create clients -r "$REALM" -f - >/dev/null \
    || fail "creation of the 'dex' client failed in realm ${REALM}."
  dex_uuid="$(kc_client_uuid "$REALM" dex)"
  echo "    'dex' client created (standard flow only, redirect ${DEX_REDIRECT})."
else
  kc_adm update "clients/${dex_uuid}" -r "$REALM" \
    -s enabled=true -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false -s implicitFlowEnabled=false \
    -s serviceAccountsEnabled=false \
    -s "redirectUris=[\"${DEX_REDIRECT}\"]" >/dev/null \
    || warn "could not re-align the 'dex' client — check it in the console."
  echo "    'dex' client already present — fields re-aligned, secret left untouched."
fi

# `groups` as an OPTIONAL scope, not a default one: Dex asks for it explicitly in its
# `scopes:` list (values.yaml), and a requested scope has to be assigned to the client. The
# built-in `profile`/`email`/`roles`/… come with the realm and are already default.
groups_uuid="$(kc_adm get client-scopes -r "$REALM" --fields id,name 2>/dev/null \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(next((x['id'] for x in d if x['name']=='groups'),''))" 2>/dev/null || true)"
if [ -n "$groups_uuid" ]; then
  kc_adm update "clients/${dex_uuid}/optional-client-scopes/${groups_uuid}" -r "$REALM" >/dev/null 2>&1 \
    && echo "    'groups' scope assigned to the client (optional)." \
    || echo "    'groups' scope already assigned."
else
  warn "no 'groups' client scope in realm ${REALM} — the token will carry no group and the
        RBAC of rbac.yaml will match nothing. Install ../keycloak/ first."
fi

# ============================================================================
# The lab CA, so that Dex can VALIDATE Keycloak. Dex fetches the realm's
# `.well-known/openid-configuration` over HTTPS at startup, and a verification failure there is
# FATAL: the pod crashloops on `x509: certificate signed by unknown authority`. The wildcard
# that Envoy serves is signed by a local CA (`SELF_SIGNED=true`) or by the ACME STAGING chain —
# neither is in the container's trust store.
#
# Same cross-namespace pattern as the client secret above: a Secret does not travel, so we copy
# it. `tls.crt` and not a `ca.crt` key: the Secret produced by cert-manager has no such key, and
# the self-signed one deliberately concatenates leaf + CA into `tls.crt`. In both cases the
# bundle carries its own trust anchor, which is exactly what `rootCAs` needs — no branching on
# the TLS mode, as everywhere else in this repository.
CA_SECRET="${CA_SECRET:-dex-lab-ca}"
chain="$(kubectl -n envoy-gateway-system get secret "$WILDCARD_TLS" \
           -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d || true)"
[ -n "$chain" ] || fail "wildcard TLS Secret 'envoy-gateway-system/${WILDCARD_TLS}' not found.
        Dex cannot validate Keycloak without the lab CA. Lay the platform down first:
          ./platform-up.sh"
printf '%s' "$chain" | kubectl -n "$NS" create secret generic "$CA_SECRET" \
  --from-file=ca.crt=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -
echo "    lab CA copied from ${WILDCARD_TLS} -> ${NS}/${CA_SECRET} (key ca.crt)"

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
