#!/usr/bin/env bash
#
# velero-up.sh — installs Velero (cluster backup and restore) with MinIO as its S3 backend.
#
#   ./velero/velero-up.sh <talos|kubeadm>     (or ./install.sh <distro> velero)
#
# WHAT gets backed up — the question has two halves, and this component answers both:
#
#   1. the Kubernetes OBJECTS. Velero lists them through the API server (namespaced AND
#      cluster-scoped: Deployments, Secrets, CRDs, PVs, ClusterRoles…) and writes them as one
#      tarball per backup into the bucket. That is Velero's core job, nothing to configure.
#
#   2. the PERSISTENT VOLUME DATA, Longhorn included, through File System Backup (FSB): the
#      `node-agent` DaemonSet reads the volume where the kubelet has ALREADY mounted it and
#      uploads the bytes to the SAME bucket with kopia. `defaultVolumesToFsBackup: true`
#      (values.yaml) makes that the default for every pod volume — no annotation to remember
#      on each workload.
#
# WHEN each half runs — the two costs are not comparable, so neither is their cadence
# (schedule.yaml): `hourly-objects` writes the OBJECTS every hour (one tarball, seconds), while
# `daily-full` writes objects AND volume data once a day at 02:00 UTC, because that one re-reads
# every pod volume in the cluster through the node-agent. ~1-hour RPO on a deleted manifest,
# ~24-hour RPO on the bytes inside a PVC.
#
# WHY FSB rather than CSI snapshots: a CSI snapshot of a Longhorn volume stays INSIDE Longhorn,
# on the very worker disks we are protecting, and it would need the external-snapshotter
# controller plus a VolumeSnapshotClass — neither of which this lab installs. FSB copies the
# data OUT, which is the only thing that survives `vagrant destroy`. Bonus: it is
# storage-agnostic, so `longhorn`, `longhorn-r1` and `local-path` are all covered by the same
# setup.
#
# The MinIO endpoint is the in-cluster Service. BACKUP traffic therefore never goes through
# main-gateway, needs no LoadBalancer IP and no DNS record: the backup half of this component
# behaves identically whether the LoadBalancer IPs come from Cilium's L2 announcer or from
# MetalLB — and it keeps working when neither is installed.
#
# THE UI, on the other hand, is a web dashboard and does need to be reachable: velero-ui (otwld)
# is installed in the same namespace and exposed at velero.$LAB_DOMAIN through main-gateway,
# like every other UI here. It is the reason a restore stops being a CLI-only exercise. Set
# VELERO_UI=false to skip it entirely; when the Gateway API is not installed the route is
# skipped on its own and the rest still installs.
#
# Prerequisites: a MinIO in the cluster (`minio-cluster` preferred, `minio-s3` accepted),
#                kubectl + helm + curl + openssl. `mc` is downloaded if it is not in PATH; the
#                `velero` CLI is OPTIONAL (everything here is plain CRDs — even more so now that
#                the UI covers browsing and restoring).
# Idempotent: `helm upgrade --install` + `kubectl apply`, and the MinIO user keeps its existing
# access key. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Pinned versions (overridable through environment variables) -------------
VELERO_VERSION="${VELERO_VERSION:-12.1.0}"                  # chart (app v1.18.1)
VELERO_AWS_PLUGIN_VERSION="${VELERO_AWS_PLUGIN_VERSION:-v1.14.2}"  # plugin v1.14.x <-> Velero v1.18.x
VELERO_UI_VERSION="${VELERO_UI_VERSION:-0.15.0}"            # chart otwld/velero-ui (app 0.10.2)

NS="${VELERO_NS:-velero}"
VELERO_BUCKET="${VELERO_BUCKET:-velero}"
S3_USER="${VELERO_S3_USER:-velero}"
VELERO_UI="${VELERO_UI:-true}"                              # false: back up, no dashboard
VELERO_UI_USER="${VELERO_UI_USER:-admin}"

# --- Prerequisites -----------------------------------------------------------
need kubectl helm curl openssl
require_apiserver

# WHICH MinIO? `minio-cluster` (distributed, the repository's designated backup target) comes
# first; the standalone `minio-s3` is accepted as a fallback because a lab short on workers
# cannot run the 4-node one. Both expose the same `svc/minio:9000`.
MINIO_NS="${VELERO_MINIO_NS:-}"
if [ -z "$MINIO_NS" ]; then
  for candidate in minio-cluster minio-s3; do
    if kubectl -n "$candidate" get svc minio >/dev/null 2>&1; then MINIO_NS="$candidate"; break; fi
  done
fi
[ -n "$MINIO_NS" ] || fail "no MinIO found (neither minio-cluster nor minio-s3).
        Install the backup target first:
          ./install.sh ${K8S_DISTRO} minio-cluster     (4 workers required)
          ./install.sh ${K8S_DISTRO} minio             (standalone, 1 pod)
        Or point at your own: VELERO_MINIO_NS=<namespace> (it must hold svc/minio:9000)"
S3_URL="http://minio.${MINIO_NS}.svc.cluster.local:9000"

# `mc` is downloaded for the HOST platform, not hard-coded to Linux: this script runs on your
# workstation (it opens a `kubectl port-forward` on 127.0.0.1), and a linux-amd64 binary on an
# Apple Silicon Mac fails with "exec format error". Same helper as
# ../cloudnative-pg/pg-app-backup-cnpg-up.sh.
MC="$(command -v mc || true)"
mc_url() {
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
  printf 'https://dl.min.io/client/mc/release/%s-%s/mc' "$os" "$arch"
}
if [ -z "$MC" ]; then MC="$(mktemp -d)/mc"; curl -fsSL -o "$MC" "$(mc_url)" && chmod +x "$MC"; fi

# ONE cleanup for the whole script: a port-forward left running would hold port 19010 for the
# next run, and the two temporary files carry a MinIO policy and the rendered Helm values.
PF=""; POLICY=""; VALUES=""
cleanup() {
  [ -n "$PF" ] && kill "$PF" 2>/dev/null
  [ -n "$POLICY" ] && rm -f "$POLICY"
  [ -n "$VALUES" ] && rm -f "$VALUES"
  return 0
}
trap cleanup EXIT

distro_summary

# ============================================================================
log "[1/5] Namespace ${NS} (PodSecurity privileged)"
# The node-agent mounts the kubelet's pod directory (hostPath) to reach the volume data.
# PodSecurity `baseline` FORBIDS hostPath volumes, so on Talos — where baseline is enforced
# cluster-wide — this label is what stands between a working DaemonSet and a silent refusal
# (the DaemonSet exists, it creates no pod, and nothing in `kubectl get ds` says why). On
# kubeadm no level is enforced today: the label documents the need and keeps the namespace
# working the day admission is hardened.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace "$NS" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite >/dev/null
echo "    ${NS} labelled privileged (node-agent needs hostPath; cluster default: ${PODSECURITY_DEFAULT})"

# ============================================================================
log "[2/5] MinIO (${MINIO_NS}): bucket ${VELERO_BUCKET} + dedicated user ${S3_USER}"
# A DEDICATED user rather than the MinIO root: a backup agent that can read every bucket of
# the lab is a strange thing to hand a cluster-admin ServiceAccount.
ROOTPW="$(kubectl -n "$MINIO_NS" get secret minio-creds -o jsonpath='{.data.root-password}' | base64 -d)"
[ -n "$ROOTPW" ] || fail "Secret ${MINIO_NS}/minio-creds has no root-password."
kubectl -n "$MINIO_NS" port-forward svc/minio 19010:9000 >/dev/null 2>&1 &
PF=$!
# BOUNDED wait: an infinite `until` on a port-forward that died (pod restarted, Service gone)
# leaves the script spinning forever without ever saying so.
for _ in $(seq 1 60); do
  curl -s -o /dev/null http://127.0.0.1:19010/minio/health/ready 2>/dev/null && break
  kill -0 "$PF" 2>/dev/null || fail "the port-forward to ${MINIO_NS}/svc/minio died."
  sleep 1
done
curl -sf -o /dev/null http://127.0.0.1:19010/minio/health/ready \
  || fail "MinIO (${MINIO_NS}) not ready after 60s — kubectl -n ${MINIO_NS} get pods"

# The alias name must START WITH A LETTER: since RELEASE.2025-08-13 `mc` validates it and
# rejects the older `_lab` outright ("Alias `_lab` should have alphanumeric characters […] and
# begin with a letter"), which failed the whole install here. Still NOT plain `lab`: that is the
# name the README hands to a human for their own alias, and clobbering it would silently
# repoint their shell at this port-forward.
MC_ALIAS="${MC_ALIAS:-labminio}"
"$MC" alias set "$MC_ALIAS" http://127.0.0.1:19010 admin "$ROOTPW" >/dev/null
"$MC" mb --ignore-existing "${MC_ALIAS}/${VELERO_BUCKET}" >/dev/null
POLICY="$(mktemp)"
cat > "$POLICY" <<JSON
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::${VELERO_BUCKET}","arn:aws:s3:::${VELERO_BUCKET}/*"]} ]}
JSON
"$MC" admin policy create "$MC_ALIAS" "${VELERO_BUCKET}-rw" "$POLICY" >/dev/null 2>&1 || true

# Idempotency, and the reason it matters: a secret key is write-only on the MinIO side. If we
# minted a fresh one on every run, Velero's Secret and MinIO would drift apart and EVERY upload
# would 403 — with a `helm upgrade` still reporting success. So the existing key is read back
# out of the Secret (whose `cloud` value is an AWS credentials file, hence the sed), and only
# when there is none do we reset the user.
SK=""
if kubectl -n "$NS" get secret velero-s3 >/dev/null 2>&1; then
  SK="$(kubectl -n "$NS" get secret velero-s3 -o jsonpath='{.data.cloud}' | base64 -d \
        | sed -n 's/^aws_secret_access_key=//p' | head -n1)"
fi
if [ -z "$SK" ]; then
  SK="$(openssl rand -base64 21 | tr -d '/+=' | head -c 28)"
  # Nothing on our side can recover the key MinIO may still hold for this user: drop it, so
  # that the `user add` below really installs the one we are about to store.
  "$MC" admin user remove "$MC_ALIAS" "$S3_USER" >/dev/null 2>&1 || true
fi
"$MC" admin user add "$MC_ALIAS" "$S3_USER" "$SK" >/dev/null 2>&1 || true
"$MC" admin policy attach "$MC_ALIAS" "${VELERO_BUCKET}-rw" --user "$S3_USER" >/dev/null 2>&1 || true
kill "$PF" 2>/dev/null || true; PF=""
echo "    bucket ${VELERO_BUCKET} + user ${S3_USER} scoped to it (policy ${VELERO_BUCKET}-rw)"

# The Secret the chart expects: ONE `cloud` key holding an AWS credentials file. `umask 077`
# is pointless here — nothing touches the disk, the value goes straight into the API server.
kubectl -n "$NS" create secret generic velero-s3 \
  --from-literal=cloud="$(printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' "$S3_USER" "$SK")" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "    Secret ${NS}/velero-s3 (key 'cloud') up to date"

# ============================================================================
log "[3/5] Velero chart ${VELERO_VERSION} -> ${S3_URL}/${VELERO_BUCKET}"
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update vmware-tanzu >/dev/null
# values.yaml carries the DEFAULT endpoint (minio-cluster) and the pinned plugin tag; we
# substitute the values actually resolved above, without ever rewriting the versioned file
# (same approach as ../cilium/cilium-up.sh with its L2 pool).
VALUES="$(mktemp)"
sed -e "s#http://minio\.minio-cluster\.svc\.cluster\.local:9000#${S3_URL}#" \
    -e "s#velero/velero-plugin-for-aws:v1\.14\.2#velero/velero-plugin-for-aws:${VELERO_AWS_PLUGIN_VERSION}#" \
    -e "s#^\( *bucket: \).*#\1${VELERO_BUCKET}#" \
    "${HERE}/values.yaml" > "$VALUES"
helm upgrade --install velero vmware-tanzu/velero \
  --namespace "$NS" \
  --version "${VELERO_VERSION}" \
  --values "$VALUES" \
  --set "nodeAgent.podVolumePath=${VELERO_POD_VOLUME_PATH}" \
  --wait --timeout 10m
kubectl -n "$NS" rollout status deploy/velero --timeout=300s
kubectl -n "$NS" rollout status ds/node-agent --timeout=300s

# The BackupStorageLocation is Velero's own verdict on the bucket: `Available` means it
# listed it with the credentials above. `Unavailable` here is worth far more than a green
# `helm install`, so we wait for it instead of declaring victory.
echo "    waiting for the BackupStorageLocation to become Available..."
for _ in $(seq 1 20); do
  PHASE="$(kubectl -n "$NS" get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "$PHASE" = "Available" ] && break
  sleep 6
done
[ "${PHASE:-}" = "Available" ] \
  || warn "BackupStorageLocation 'default' is '${PHASE:-<none>}' — kubectl -n ${NS} logs deploy/velero | tail -30"

# ============================================================================
log "[4/5] Schedules: hourly objects + daily objects-and-volumes"
kubectl apply -f "${HERE}/schedule.yaml"

# ============================================================================
if [ "$VELERO_UI" = "true" ]; then
  log "[5/5] Velero UI ${VELERO_UI_VERSION} (velero.${LAB_DOMAIN})"

  # Same idempotency rule as the MinIO key above, for the same reason: a password regenerated on
  # every run is a password nobody can write down. Read it back when the Secret is there, mint
  # it only the first time.
  UI_PASS=""; UI_PHRASE=""
  if kubectl -n "$NS" get secret velero-ui-auth >/dev/null 2>&1; then
    UI_PASS="$(kubectl -n "$NS" get secret velero-ui-auth -o jsonpath='{.data.password}' | base64 -d)"
    UI_PHRASE="$(kubectl -n "$NS" get secret velero-ui-auth -o jsonpath='{.data.pass_phrase}' | base64 -d)"
  fi
  # `tr -d` then `cut`: the base64 alphabet contains / and + and the value travels through YAML,
  # a shell variable and an HTTP form before it is compared.
  [ -n "$UI_PASS" ]   || UI_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
  [ -n "$UI_PHRASE" ] || UI_PHRASE="$(openssl rand -hex 32)"
  kubectl -n "$NS" create secret generic velero-ui-auth \
    --from-literal=username="$VELERO_UI_USER" \
    --from-literal=password="$UI_PASS" \
    --from-literal=pass_phrase="$UI_PHRASE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "    Secret ${NS}/velero-ui-auth (username / password / pass_phrase) up to date"

  helm repo add otwld https://helm.otwld.com/ >/dev/null 2>&1 || true
  helm repo update otwld >/dev/null
  UI_VALUES="$(mktemp)"
  # ui-values.yaml pins `veleroNamespace: velero`; VELERO_NS may say otherwise.
  sed -e "s#^\( *veleroNamespace: \).*#\1\"${NS}\"#" "${HERE}/ui-values.yaml" > "$UI_VALUES"
  helm upgrade --install velero-ui otwld/velero-ui \
    --namespace "$NS" \
    --version "${VELERO_UI_VERSION}" \
    --values "$UI_VALUES" \
    --wait --timeout 5m
  rm -f "$UI_VALUES"
  kubectl -n "$NS" rollout status deploy/velero-ui --timeout=300s

  # Same ordering guard as ../cilium/cilium-up.sh: without the Gateway API CRDs the apply would
  # fail on `no matches for kind "HTTPRoute"` and take the whole install down with it — for a
  # route, on a component whose backups do not need one.
  if kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
    render "${HERE}/ui-httproute.yaml" | kubectl apply -f -
  else
    warn "Gateway API not installed: no route created. The UI is reachable with
        kubectl -n ${NS} port-forward deploy/velero-ui 3000:3000
        Install the platform (./install.sh ${K8S_DISTRO} platform), then re-run this script."
  fi
else
  log "[5/5] Velero UI skipped (VELERO_UI=false)"
fi

# ============================================================================
log "Velero installed."
echo "  Backend    : ${S3_URL}/${VELERO_BUCKET}  (MinIO namespace ${MINIO_NS})"
echo "  Covers     : every K8s object + every pod volume (FSB/kopia) — Longhorn PVs included"
echo "  Schedules  : hourly-objects  '0 * * * *'  objects only,      TTL 48h"
echo "               daily-full      '0 2 * * *'  objects + PV data, TTL 168h"
echo "               (kubectl -n ${NS} get schedules)"
echo "  Access key : kubectl -n ${NS} get secret velero-s3 -o jsonpath='{.data.cloud}' | base64 -d"
if [ "$VELERO_UI" = "true" ]; then
echo
echo "  UI         : https://velero.${LAB_DOMAIN}   (user: ${VELERO_UI_USER})"
echo "  Password   : kubectl -n ${NS} get secret velero-ui-auth -o jsonpath='{.data.password}' | base64 -d ; echo"
echo "  Test       : curl --resolve velero.${LAB_DOMAIN}:443:192.168.56.200 https://velero.${LAB_DOMAIN}/"
fi
echo
echo "  Backup now : velero backup create manual-1 --wait          (CLI)"
echo "               a Backup object does the same without the CLI — see velero/README.md"
echo "  Follow it  : kubectl -n ${NS} get backups.velero.io,podvolumebackups"
echo "               ('backups' alone hits Longhorn's CRD of the same name — see the README)"
echo "  Health     : kubectl -n ${NS} get backupstoragelocation default"
echo
echo "  /!\\ The UI can browse, create and RESTORE backups: its ServiceAccount is cluster-admin."
echo "      The 'velero' CLI stays useful for scripted restores and for backup logs:"
echo "      https://velero.io/docs/v1.18/basic-install/#install-the-cli"
