#!/usr/bin/env bash
#
# pg-backup-up.sh — sets up the HOURLY backup of the `vault` database to MinIO (S3), using the
# PostgreSQL credentials MANAGED BY VAULT (the pg-rotate-creds secret).
#
# What the script does (idempotent):
#   1. creates the `pg-backups` MinIO bucket + a DEDICATED `pg-backup` user scoped to it;
#   2. creates the `minio-backup-creds` K8s Secret (endpoint + access/secret key) in
#      pg-rotate-demo;
#   3. applies the `pg-backup-vault-s3` CronJob (pg-backup-vault-s3.yaml).
#
# ⚠️ LOGICAL backup (pg_dump) — it does NOT use the CloudNativePG backup CRDs (Barman): the
#    whole point is to back up WITH the Vault credentials. See the README for the CNPG-native
#    alternative.
#
# Prerequisites: the minio-s3/cluster add-on deployed, Vault rotation in place
# (pg-rotate-creds present), the pg-demo cluster UP.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

for bin in kubectl curl openssl; do command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' missing." >&2; exit 1; }; done
kubectl -n pg-rotate-demo get secret pg-rotate-creds >/dev/null 2>&1 || { echo "ERROR: secret pg-rotate-creds missing (Vault rotation not in place?)." >&2; exit 1; }

# --- mc (the MinIO client): a local static binary if it is missing -----------
MC="$(command -v mc || true)"
# `mc` is downloaded for the HOST platform, not hard-coded to Linux: this script runs on your
# workstation (it does a `kubectl port-forward` on 127.0.0.1), and a linux-amd64 binary on an
# Apple Silicon Mac fails with "exec format error".
mc_url() {
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
  printf 'https://dl.min.io/client/mc/release/%s-%s/mc' "$os" "$arch"
}
if [ -z "$MC" ]; then
  MC="$(mktemp -d)/mc"
  curl -fsSL -o "$MC" "$(mc_url)" && chmod +x "$MC"
fi

log "MinIO: pg-backups bucket + dedicated pg-backup user"
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
# The alias name must START WITH A LETTER: since RELEASE.2025-08-13 `mc` validates it and
# rejects the older `_lab` outright. Still NOT plain `lab` — that is the name a human is told to
# use for their own alias, and clobbering it would repoint their shell at this port-forward.
MC_ALIAS="${MC_ALIAS:-labminio}"
"$MC" alias set "$MC_ALIAS" http://127.0.0.1:19000 admin "$ROOTPW" >/dev/null
"$MC" mb --ignore-existing "${MC_ALIAS}/pg-backups" >/dev/null
POLICY="$(mktemp)"; cat > "$POLICY" <<'JSON'
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::pg-backups","arn:aws:s3:::pg-backups/*"]} ]}
JSON
"$MC" admin policy create "$MC_ALIAS" pg-backups-rw "$POLICY" >/dev/null 2>&1 || true

# The user's secret key: reuse the one already in the K8s Secret when present (idempotence),
# otherwise generate a new one and (re)create the user with it.
if kubectl -n pg-rotate-demo get secret minio-backup-creds >/dev/null 2>&1; then
  SK="$(kubectl -n pg-rotate-demo get secret minio-backup-creds -o jsonpath='{.data.MINIO_SECRET_KEY}' | base64 -d)"
else
  SK="$(openssl rand -base64 21 | tr -d '/+=' | head -c 28)"
fi
"$MC" admin user add "$MC_ALIAS" pg-backup "$SK" >/dev/null 2>&1 || "$MC" admin user svcacct info "$MC_ALIAS" pg-backup >/dev/null 2>&1 || true
"$MC" admin policy attach "$MC_ALIAS" pg-backups-rw --user pg-backup >/dev/null 2>&1 || true
kill $PF 2>/dev/null || true; trap - EXIT

log "K8s Secret minio-backup-creds (ns pg-rotate-demo)"
kubectl -n pg-rotate-demo create secret generic minio-backup-creds \
  --from-literal=MINIO_ENDPOINT="http://minio.minio-cluster.svc.cluster.local:9000" \
  --from-literal=MINIO_ACCESS_KEY="pg-backup" \
  --from-literal=MINIO_SECRET_KEY="$SK" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "Hourly CronJob pg-backup-vault-s3"
kubectl apply -f "${HERE}/pg-backup-vault-s3.yaml"

log "Ready."
echo "  Trigger a backup right now:"
echo "    kubectl -n pg-rotate-demo create job pg-backup-now --from=cronjob/pg-backup-vault-s3"
echo "  List the backups in the bucket:"
echo "    mc ls ${MC_ALIAS}/pg-backups/    (or through the MinIO console)"
