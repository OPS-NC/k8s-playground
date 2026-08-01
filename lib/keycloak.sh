#!/usr/bin/env bash
#
# keycloak.sh — talking to the Keycloak admin API from an addon script.
#
# Sourced by keycloak/keycloak-up.sh and dex/dex-up.sh. Not standalone.
#
# WHY THIS EXISTS AT ALL. Keycloak 26.7 ships a `KeycloakOIDCClient` CRD, and declaring the
# client with it would be the natural thing to do here. It does not work — see
# `../dex/README.md`, "Why the client is created with kcadm". Two independent blockers, both
# silent: the CR applies cleanly, `kubectl apply` says `configured`, and the client is simply
# never created in the realm. So we drive the admin API ourselves.
#
# WHY `kubectl exec` + `kcadm.sh` RATHER THAN curl FROM THE HOST. The obvious version —
# `curl https://keycloak.$LAB_DOMAIN/admin/...` — needs three things the lab cannot promise:
# a resolvable wildcard (absent offline, and `SELF_SIGNED=true` has no public DNS at all), a
# host that trusts the lab CA (it does not, by construction: staging and self-signed are both
# untrusted), and curl on the host. Running the vendor's own client INSIDE the pod needs none
# of them: it talks to `localhost:8080` behind the proxy, over plain HTTP, with no certificate
# in the picture. `kubectl exec` is the only requirement, and every other script here already
# assumes it.
#
# The admin credentials never transit through a command line: they are passed to the pod as
# environment variables of the `exec`, which is why every call goes through `kc_adm`.

# `keycloak-0` is the operator's StatefulSet pod. Overridable for an unusual deployment.
KC_NS="${KC_NS:-keycloak}"
KC_POD="${KC_POD:-keycloak-0}"
KC_ADMIN_SECRET="${KC_ADMIN_SECRET:-keycloak-initial-admin}"

# Runs a kcadm.sh command in the Keycloak pod, already authenticated.
#
#   kc_adm get clients -r lab -q clientId=dex
#
# `config credentials` writes a token into the pod's own kcadm config; it is re-run on every
# call because each `exec` is a fresh process. The cost is one extra token request, and in
# exchange there is no session to keep alive or invalidate.
kc_adm() {
  local user pass
  user="$(kubectl -n "$KC_NS" get secret "$KC_ADMIN_SECRET" -o jsonpath='{.data.username}' | base64 -d)"
  pass="$(kubectl -n "$KC_NS" get secret "$KC_ADMIN_SECRET" -o jsonpath='{.data.password}' | base64 -d)"
  [ -n "$user" ] && [ -n "$pass" ] \
    || fail "unable to read the admin credentials from ${KC_NS}/${KC_ADMIN_SECRET}.
        That Secret is created by the operator at first start. If you deleted it (the
        keycloak-up.sh summary suggests you do, once you have your own admin), point
        KC_ADMIN_SECRET at a Secret carrying 'username' and 'password'."
  # `env` and not an inline `VAR=x cmd`: the values must not appear in the pod's argv, where
  # any `ps` in the container would show them.
  kubectl -n "$KC_NS" exec -i "$KC_POD" -- env KC_U="$user" KC_P="$pass" sh -c '
    /opt/keycloak/bin/kcadm.sh config credentials \
      --server http://localhost:8080 --realm master \
      --user "$KC_U" --password "$KC_P" >/dev/null 2>&1 \
      || { echo "kcadm: authentication failed" >&2; exit 1; }
    exec /opt/keycloak/bin/kcadm.sh "$@"' -- "$@"
}

# Waits for the Keycloak HTTP endpoint to answer inside the pod. The operator marks the
# StatefulSet ready before Quarkus finishes opening its port, and the first kcadm call then
# fails on a connection refused that looks like an authentication problem.
kc_wait_ready() {
  local tries="${1:-60}"
  printf '    waiting for the Keycloak API '
  for _ in $(seq 1 "$tries"); do
    if kubectl -n "$KC_NS" exec "$KC_POD" -- \
         sh -c 'exec 3<>/dev/tcp/127.0.0.1/8080' >/dev/null 2>&1; then
      echo ' OK'; return 0
    fi
    printf '.'; sleep 5
  done
  echo ' FAILED'
  fail "the Keycloak API did not answer inside ${KC_POD} after $((tries * 5))s.
        Look at:  kubectl -n ${KC_NS} logs ${KC_POD} --tail=50"
}

# Ensures a client scope exists, with its protocol mappers. Idempotent: the scope is created
# on the first run, and left alone afterwards (kcadm has no upsert, and rewriting a scope that
# a client already references would be a needless risk).
#
#   kc_ensure_client_scope <realm> <name> <json-of-the-representation>
kc_ensure_client_scope() {
  local realm="$1" name="$2" repr="$3"
  if kc_adm get client-scopes -r "$realm" --fields name 2>/dev/null | grep -q "\"${name}\""; then
    echo "    client scope '${name}' already present in realm ${realm}."
    return 0
  fi
  printf '%s' "$repr" | kc_adm create client-scopes -r "$realm" -f - >/dev/null \
    || fail "creation of the '${name}' client scope failed in realm ${realm}."
  echo "    client scope '${name}' created in realm ${realm}."
}

# Internal id of a client, from its clientId. Empty when the client does not exist.
kc_client_uuid() {
  local realm="$1" client_id="$2"
  kc_adm get clients -r "$realm" -q "clientId=${client_id}" --fields id 2>/dev/null \
    | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}
