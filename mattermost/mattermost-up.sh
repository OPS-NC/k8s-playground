#!/usr/bin/env bash
#
# mattermost-up.sh — Mattermost Team Edition (community) + Alertmanager alerting into a
# dedicated channel.
#
#   ./mattermost/mattermost-up.sh <talos|kubeadm>
#
# Order:
#   1. PostgreSQL      CloudNativePG cluster (Mattermost v11 dropped MySQL, see values.yaml)
#   2. Mattermost      Helm chart, storage on longhorn-r1, no Ingress
#   3. HTTPRoute       mattermost.$LAB_DOMAIN through main-gateway
#   4. Bootstrap       admin + team + #alertes-k8s + incoming webhook, through `mmctl --local`
#   5. Alerting        PrometheusRule (lab rules) + AlertmanagerConfig -> the webhook
#
# Prerequisites:
#   - platform in place (Cilium + Envoy Gateway + cert-manager)
#   - `longhorn-r1` StorageClass          -> ./install.sh <distro> longhorn
#   - CloudNativePG operator              -> ./install.sh <distro> cnpg
#   - kube-prometheus-stack (Alertmanager + the CRDs) -> ./install.sh <distro> observability
#     Steps 4 and 5 are SKIPPED with a warning if Alertmanager is absent: Mattermost alone still
#     works, it just has nothing to notify it.
#
# WHY `mmctl --local` for the bootstrap rather than the REST API: local mode talks over a unix
# socket INSIDE the pod, so the bootstrap needs neither DNS, nor the ingress, nor TLS, nor a
# password on a command line. It is enabled by MM_SERVICESETTINGS_ENABLELOCALMODE in values.yaml.
#
# No distribution-specific behaviour here: same charts, same manifests on both labs. Only
# $LAB_DOMAIN changes.
#
# Idempotent: `helm upgrade --install` + `kubectl apply`, and every mmctl creation is guarded by
# a "does it already exist?" check. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Pinned versions (overridable through an environment variable) -----------
MATTERMOST_CHART_VERSION="${MATTERMOST_CHART_VERSION:-6.6.104}"   # app 11.9.0

MM_NS=mattermost
MM_DEPLOY=deploy/mattermost-mattermost-team-edition
MON_NS=monitoring
CHANNEL=alertes-k8s
TEAM=lab

need kubectl helm
require_apiserver
require_sc longhorn-r1

# ============================================================================
log "[1/5] PostgreSQL through CloudNativePG (Mattermost v11 requires PostgreSQL 14+)"
distro_summary
kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 \
  || fail "CloudNativePG operator missing. Install it first:
        ./install.sh ${K8S_DISTRO} cnpg"
kubectl apply -f "${HERE}/namespace.yaml"
kubectl apply -f "${HERE}/postgres-cluster.yaml"
echo "    waiting for the database to be ready (initdb + first start)…"
kubectl -n "$MM_NS" wait --for=condition=Ready cluster/mattermost-db --timeout=300s

# ============================================================================
log "[2/5] Mattermost Team Edition ${MATTERMOST_CHART_VERSION}"
helm repo add mattermost https://helm.mattermost.com >/dev/null 2>&1 || true
helm repo update mattermost >/dev/null

# The password is the one CloudNativePG generated: read it back, never store it in a file.
PGPASS="$(kubectl -n "$MM_NS" get secret mattermost-db-app -o jsonpath='{.data.password}' | base64 -d)"
MM_VALUES="$(mktemp)"
trap 'rm -f "$MM_VALUES"' EXIT
# `render` substitutes the neutral domain; the sed adds the DB password.
render "${HERE}/values.yaml" | sed "s|@@PGPASSWORD@@|${PGPASS}|" > "$MM_VALUES"

helm upgrade --install mattermost mattermost/mattermost-team-edition -n "$MM_NS" \
  --version "$MATTERMOST_CHART_VERSION" --values "$MM_VALUES"
kubectl -n "$MM_NS" rollout status "$MM_DEPLOY" --timeout=300s

# ============================================================================
log "[3/5] HTTPRoute mattermost.${LAB_DOMAIN}"
render "${HERE}/httproute.yaml" | kubectl apply -f -

# ============================================================================
# Everything below only makes sense with Alertmanager around.
if ! kubectl -n "$MON_NS" get alertmanager kube-prometheus-stack-alertmanager >/dev/null 2>&1; then
  warn "no kube-prometheus-stack Alertmanager in the '${MON_NS}' namespace:"
  warn "  skipping the alerting setup (steps 4 and 5)."
  warn "  Install ./install.sh ${K8S_DISTRO} observability, then re-run this script."
  log "Mattermost installed (without alerting)."
  echo "  UI: https://mattermost.${LAB_DOMAIN}"
  exit 0
fi

log "[4/5] Bootstrap: admin + team '${TEAM}' + channel '#${CHANNEL}' + incoming webhook"
mmctl() { kubectl -n "$MM_NS" exec "$MM_DEPLOY" -c mattermost-team-edition -- mmctl --local "$@"; }

# The admin password is generated once and kept in a Secret: re-running the script must not
# change it, and it must not appear in the terminal history.
#
# The Secret is written only AFTER the account is actually created. Writing it upfront would lie
# in the one case that matters: an admin that already exists (created by hand, or Secret deleted)
# whose real password we cannot know — `user create` would fail and the Secret would hold a
# password that opens nothing.
if kubectl -n "$MM_NS" get secret mattermost-admin >/dev/null 2>&1; then
  ADMIN_PASS="$(kubectl -n "$MM_NS" get secret mattermost-admin -o jsonpath='{.data.password}' | base64 -d)"
  echo "    'mattermost-admin' secret already there, password preserved"
  mmctl user create --email "admin@${LAB_DOMAIN}" --username admin --password "$ADMIN_PASS" \
    --system-admin >/dev/null 2>&1 || echo "    user 'admin' already there"
else
  # `tr -dc … </dev/urandom | head -c 24` would look natural and is a TRAP: head closes the pipe
  # after 24 bytes, tr takes a SIGPIPE, and under `set -o pipefail` the substitution returns 141,
  # which `set -e` turns into an immediate exit. Bounding the READ instead of the WRITE keeps
  # every stage happy: 256 random bytes leave ~150 alphanumerics, cut takes the first 24.
  ADMIN_PASS="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
  if mmctl user create --email "admin@${LAB_DOMAIN}" --username admin --password "$ADMIN_PASS" \
       --system-admin >/dev/null 2>&1; then
    kubectl -n "$MM_NS" create secret generic mattermost-admin \
      --from-literal=username=admin --from-literal=password="$ADMIN_PASS"
    echo "    admin created, password stored in the 'mattermost-admin' secret"
  else
    warn "an 'admin' account already exists but there is no 'mattermost-admin' secret:"
    warn "  its password is unknown, so nothing was stored. Reset it with:"
    warn "  kubectl -n ${MM_NS} exec ${MM_DEPLOY} -c mattermost-team-edition -- \\"
    warn "    mmctl --local user change-password admin --password '<new password>'"
    warn "  then store it: kubectl -n ${MM_NS} create secret generic mattermost-admin \\"
    warn "    --from-literal=username=admin --from-literal=password='<new password>'"
  fi
fi
mmctl team create --name "$TEAM" --display-name "Lab k8s" >/dev/null 2>&1 \
  || echo "    team '${TEAM}' already there"
mmctl team users add "$TEAM" "admin@${LAB_DOMAIN}" >/dev/null 2>&1 || true
mmctl channel create --team "$TEAM" --name "$CHANNEL" --display-name "Alertes k8s" \
  --purpose "Prometheus/Alertmanager alerts" >/dev/null 2>&1 \
  || echo "    channel '#${CHANNEL}' already there"

# One webhook, reused across runs: creating a second one would DOUBLE every notification.
# The match is anchored on our own display name, so an unrelated webhook is never hijacked.
# `mmctl webhook list` prints one line per hook: "Incoming:\t<display name> (<26-char id>)".
HOOK_ID="$(mmctl webhook list "$TEAM" 2>/dev/null \
  | sed -n 's/^Incoming:.*Alertmanager (\([a-z0-9]\{26\}\)).*/\1/p' | head -1 || true)"
if [ -z "$HOOK_ID" ]; then
  # `--channel` and `--user` accept team:channel and an email (mmctl resolves both), even though
  # `--help` only mentions the IDs. `create-incoming` answers with "Id: <id>" on its first line.
  HOOK_ID="$(mmctl webhook create-incoming --channel "${TEAM}:${CHANNEL}" \
    --user "admin@${LAB_DOMAIN}" --display-name Alertmanager --lock-to-channel 2>/dev/null \
    | sed -n 's/^Id: \([a-z0-9]\{26\}\).*/\1/p' | head -1 || true)"
  [ -n "$HOOK_ID" ] || fail "could not create the incoming webhook.
        Check that local mode is on: MM_SERVICESETTINGS_ENABLELOCALMODE in values.yaml"
  echo "    incoming webhook created"
else
  echo "    incoming webhook already there, reused"
fi

# The IN-CLUSTER URL on purpose: Alertmanager must not depend on the public DNS, on the Gateway
# or on the TLS certificate to deliver an alert. Short service name (2 dots) rather than the
# full .svc.cluster.local: some Alpine/musl-based images fail to resolve a 4-dot FQDN with
# `ndots:5`, and that failure mode is very hard to spot.
kubectl -n "$MON_NS" create secret generic mattermost-webhook \
  --from-literal=url="http://mattermost-team-edition.${MM_NS}:8065/hooks/${HOOK_ID}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ============================================================================
log "[5/5] Alerting: PrometheusRule + AlertmanagerConfig"
# See the ⚠️ in alertmanagerconfig.yaml: without this, node alerts are never delivered.
kubectl -n "$MON_NS" patch alertmanager kube-prometheus-stack-alertmanager --type=merge \
  -p '{"spec":{"alertmanagerConfigMatcherStrategy":{"type":"None"}}}' >/dev/null
kubectl apply -f "${HERE}/prometheusrule-lab-alerts.yaml"
kubectl apply -f "${HERE}/alertmanagerconfig.yaml"

# ============================================================================
log "Mattermost + alerting installed."
echo "  UI         : https://mattermost.${LAB_DOMAIN}"
echo "  Admin      : admin / kubectl -n ${MM_NS} get secret mattermost-admin -o jsonpath='{.data.password}' | base64 -d"
echo "  Channel    : ~${CHANNEL} (team '${TEAM}')"
echo "  Rules      : kubectl -n ${MON_NS} get prometheusrule lab-alerts"
echo "  Routing    : kubectl -n ${MON_NS} get alertmanagerconfig mattermost"
echo
echo "  Alerts arrive within ~2-5 min of a real problem. To provoke one on purpose:"
echo "    kubectl create deployment crashtest --image=busybox:1.36 -- sh -c 'exit 1'"
echo "    # LabPodCrashLooping fires after ~4 min, then:"
echo "    kubectl delete deployment crashtest      # and the RESOLVED message follows"
