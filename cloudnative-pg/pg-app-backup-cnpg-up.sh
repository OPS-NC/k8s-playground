#!/usr/bin/env bash
#
# pg-app-backup-cnpg-up.sh — sets up the NATIVE CloudNativePG backup (CRDs) to MinIO S3 for
# the `pg-demo` cluster (which holds the `app` database). PHYSICAL backup + WAL archiving
# (PITR).
#
# Steps (idempotent):
#   1. `cnpg-backups` MinIO bucket + dedicated `cnpg-backup` user (scoped to the bucket);
#   2. `cnpg-backup-s3` K8s Secret (access/secret key) in cnpg-demo;
#   3. patch the `pg-demo` Cluster with `spec.backup.barmanObjectStore` (=> WAL archiving);
#   4. hourly ScheduledBackup + one on-demand Backup (pg-app-backup-cnpg.yaml).
#
# ⚠️ CNPG ≤ 1.30: the in-tree `barmanObjectStore` works but is DEPRECATED (removal planned for
#    1.31). Future migration: the Barman Cloud Plugin (CNPG-I). See the README.
#
# Prerequisites: the minio-s3/cluster add-on deployed + the pg-demo cluster UP.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

for bin in kubectl curl openssl; do command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' missing." >&2; exit 1; }; done
kubectl -n cnpg-demo get cluster pg-demo >/dev/null 2>&1 || { echo "ERROR: cluster pg-demo missing." >&2; exit 1; }

MC="$(command -v mc || true)"
# `mc` is downloaded for the HOST platform, not hard-coded to Linux: this script runs on your
# workstation (it does a `kubectl port-forward` on 127.0.0.1), and a linux-amd64 binary on an
# Apple Silicon Mac fails with "exec format error".
mc_url() {
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
  printf 'https://dl.min.io/client/mc/release/%s-%s/mc' "$os" "$arch"
}
if [ -z "$MC" ]; then MC="$(mktemp -d)/mc"; curl -fsSL -o "$MC" "$(mc_url)" && chmod +x "$MC"; fi

log "MinIO: cnpg-backups bucket + dedicated cnpg-backup user"
ROOTPW="$(kubectl -n minio-cluster get secret minio-creds -o jsonpath='{.data.root-password}' | base64 -d)"
kubectl -n minio-cluster port-forward svc/minio 19000:9000 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
# BOUNDED wait: if the port-forward dies (pod restarted, svc missing), an infinite `until`
# loop left the script spinning without ever saying anything.
for _ in $(seq 1 60); do
  curl -s -o /dev/null http://127.0.0.1:19000/minio/health/ready 2>/dev/null && break
  kill -0 "$PF" 2>/dev/null || { echo "ERROR: the port-forward to svc/minio died." >&2; exit 1; }
  sleep 1
done
curl -sf -o /dev/null http://127.0.0.1:19000/minio/health/ready \
  || { echo "ERROR: MinIO (minio-cluster) not ready after 60s — kubectl -n minio-cluster get pods" >&2; exit 1; }
"$MC" alias set _lab http://127.0.0.1:19000 admin "$ROOTPW" >/dev/null
"$MC" mb --ignore-existing _lab/cnpg-backups >/dev/null
POLICY="$(mktemp)"; cat > "$POLICY" <<'JSON'
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::cnpg-backups","arn:aws:s3:::cnpg-backups/*"]} ]}
JSON
"$MC" admin policy create _lab cnpg-backups-rw "$POLICY" >/dev/null 2>&1 || true
if kubectl -n cnpg-demo get secret cnpg-backup-s3 >/dev/null 2>&1; then
  SK="$(kubectl -n cnpg-demo get secret cnpg-backup-s3 -o jsonpath='{.data.SECRET_ACCESS_KEY}' | base64 -d)"
else
  SK="$(openssl rand -base64 21 | tr -d '/+=' | head -c 28)"
fi
"$MC" admin user add _lab cnpg-backup "$SK" >/dev/null 2>&1 || true
"$MC" admin policy attach _lab cnpg-backups-rw --user cnpg-backup >/dev/null 2>&1 || true
kill $PF 2>/dev/null || true; trap - EXIT

log "K8s Secret cnpg-backup-s3 (ns cnpg-demo)"
kubectl -n cnpg-demo create secret generic cnpg-backup-s3 \
  --from-literal=ACCESS_KEY_ID=cnpg-backup \
  --from-literal=SECRET_ACCESS_KEY="$SK" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "Patching the pg-demo Cluster: barmanObjectStore -> MinIO (enables WAL archiving)"
kubectl -n cnpg-demo patch cluster pg-demo --type=merge -p '{
  "spec":{"backup":{"retentionPolicy":"7d","barmanObjectStore":{
    "destinationPath":"s3://cnpg-backups/",
    "endpointURL":"http://minio.minio-cluster.svc.cluster.local:9000",
    "s3Credentials":{"accessKeyId":{"name":"cnpg-backup-s3","key":"ACCESS_KEY_ID"},
                     "secretAccessKey":{"name":"cnpg-backup-s3","key":"SECRET_ACCESS_KEY"}},
    "wal":{"compression":"gzip"},"data":{"compression":"gzip"}}}}}'
echo "    waiting for ContinuousArchiving=True..."
for _ in $(seq 1 20); do
  [ "$(kubectl -n cnpg-demo get cluster pg-demo -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}' 2>/dev/null)" = "True" ] && break
  sleep 6
done

log "Hourly ScheduledBackup + on-demand Backup"
kubectl apply -f "${HERE}/pg-app-backup-cnpg.yaml"

log "Ready."
echo "  Track backups : kubectl -n cnpg-demo get backups"
echo "  MinIO objects : mc ls -r _lab/cnpg-backups/pg-demo/"
echo "  PITR possible : kubectl -n cnpg-demo get cluster pg-demo -o jsonpath='{.status.firstRecoverabilityPoint}'"
