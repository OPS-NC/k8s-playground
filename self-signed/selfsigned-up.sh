#!/usr/bin/env bash
#
# selfsigned-up.sh — lays down the lab's `*.<LAB_DOMAIN>` wildcard TLS WITHOUT cert-manager,
# without Let's Encrypt, without a Cloudflare token and without a publicly resolvable domain.
#
# Does three things (each assumes the previous one):
#   1. A local CA (`_out/self-signed/ca.crt` + `ca.key`, 10 years), generated ONCE and REUSED
#      afterwards: it is the one you import into your browser / keychain. It survives
#      `vagrant destroy` (it lives on the host, not in etcd), so the security exception does
#      not have to be re-accepted on every rebuild.
#   2. A `*.<LAB_DOMAIN>` (+ `<LAB_DOMAIN>`) leaf certificate signed by that CA, 825 days,
#      regenerated only when missing / expiring / the domain changed.
#   3. The `wildcard-<dashed-domain>-tls` TLS Secret in `envoy-gateway-system`, exactly the
#      name the `https` listener of `main-gateway` expects — cert-manager would have filled
#      the SAME Secret, so the Gateway needs to know nothing about any of this.
#
# Called by platform-up.sh (step 4) when SELF_SIGNED=true, but runnable on its own:
#   ./self-signed/selfsigned-up.sh <talos|kubeadm>
# Idempotent: on a re-run it reuses the CA and the certificate as long as they are valid.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# Lifetimes. 825 days is the limit beyond which browsers refuse a server certificate, even one
# signed by a trusted CA.
CA_DAYS="${CA_DAYS:-3650}"
CERT_DAYS="${CERT_DAYS:-825}"
# Renewal margin: below it, the leaf is regenerated on the next run.
RENEW_DAYS="${RENEW_DAYS:-30}"

# LAB_DOMAIN, LAB_DOMAIN_DASH and WILDCARD_TLS come from k8s_init (lib/common.sh): the Secret
# name follows the domain, exactly as in platform-up.sh.

# The lab's `_out/` is gitignored: the CA private key cannot end up in a commit.
CERT_DIR="${LAB_DIR}/_out/self-signed"
CA_KEY="${CERT_DIR}/ca.key"
CA_CRT="${CERT_DIR}/ca.crt"
TLS_KEY="${CERT_DIR}/tls.key"
TLS_CRT="${CERT_DIR}/tls.crt"

# --- Prerequisites -----------------------------------------------------------
need kubectl openssl
require_apiserver

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

# ============================================================================
# 1. Local CA — generated once, then reused as is.
# ============================================================================
if [ -s "$CA_KEY" ] && [ -s "$CA_CRT" ]; then
  log "Local CA: reusing ${CA_CRT#"$LAB_DIR"/}"
else
  log "Local CA: generating (${CA_DAYS} days)"
  openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days "$CA_DAYS" \
    -keyout "$CA_KEY" -out "$CA_CRT" \
    -subj "/O=${CA_ORG}/CN=${CA_ORG} self-signed CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  chmod 600 "$CA_KEY"
fi

# ============================================================================
# 2. `*.<LAB_DOMAIN>` leaf certificate — regenerated only when needed.
# ============================================================================
# Three reasons to regenerate: the file is missing, it expires in less than RENEW_DAYS, or
# LAB_DOMAIN changed since (the SAN no longer covers the lab).
need_cert=0
if [ ! -s "$TLS_CRT" ] || [ ! -s "$TLS_KEY" ]; then
  need_cert=1
elif ! openssl x509 -in "$TLS_CRT" -noout -checkend "$((RENEW_DAYS * 86400))" >/dev/null 2>&1; then
  echo "    certificate expiring within ${RENEW_DAYS} days -> regenerating"
  need_cert=1
# `-text` and NOT `-ext subjectAltName`: `-ext` does not exist in LibreSSL, which is macOS'
# SYSTEM openssl (/usr/bin/openssl). There it errored out without printing anything, so the
# condition was ALWAYS true and the certificate was regenerated on every run — contradicting
# the advertised idempotence and reloading Envoy's TLS on every `platform-up.sh`. `-text`
# works on both sides.
elif ! openssl x509 -in "$TLS_CRT" -noout -text 2>/dev/null \
       | grep -Fq "DNS:*.${LAB_DOMAIN}"; then
  echo "    LAB_DOMAIN changed (SAN does not cover *.${LAB_DOMAIN}) -> regenerating"
  need_cert=1
fi

if [ "$need_cert" = "1" ]; then
  log "Certificate *.${LAB_DOMAIN} (${CERT_DAYS} days, signed by the local CA)"
  ext_file="$(mktemp)"
  csr_file="$(mktemp)"
  trap 'rm -f "$ext_file" "$csr_file"' EXIT
  # `serverAuth` + an explicit SAN: browsers have long ignored the CN and look ONLY at the
  # subjectAltName. We cover the wildcard AND the apex, otherwise `https://<LAB_DOMAIN>` (with
  # no subdomain) would fail with a name mismatch.
  cat >"$ext_file" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:*.${LAB_DOMAIN},DNS:${LAB_DOMAIN}
EOF
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$TLS_KEY" -out "$csr_file" \
    -subj "/O=${CA_ORG}/CN=*.${LAB_DOMAIN}" 2>/dev/null
  openssl x509 -req -in "$csr_file" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$TLS_CRT" -days "$CERT_DAYS" -sha256 -extfile "$ext_file" 2>/dev/null
  chmod 600 "$TLS_KEY"
  rm -f "$ext_file" "$csr_file"
  trap - EXIT
else
  log "Certificate *.${LAB_DOMAIN}: still valid, reused"
fi

# ============================================================================
# 3. TLS Secret in the Gateway's namespace.
# ============================================================================
# `tls.crt` = leaf THEN CA: Envoy serves the full chain, which lets a client holding the CA in
# its store validate with no further configuration.
log "Secret ${WILDCARD_TLS} (ns envoy-gateway-system)"
kubectl create namespace envoy-gateway-system \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
chain_file="$(mktemp)"
trap 'rm -f "$chain_file"' EXIT
cat "$TLS_CRT" "$CA_CRT" >"$chain_file"
kubectl create secret tls "$WILDCARD_TLS" -n envoy-gateway-system \
  --cert="$chain_file" --key="$TLS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f "$chain_file"
trap - EXIT

# ============================================================================
log "Self-signed wildcard in place."
echo "  Domain   : *.${LAB_DOMAIN} (+ ${LAB_DOMAIN})"
echo "  Expires  : $(openssl x509 -in "$TLS_CRT" -noout -enddate | cut -d= -f2)"
echo "  Secret   : ${WILDCARD_TLS} (ns envoy-gateway-system)"
echo "  CA       : ${CA_CRT#"$LAB_DIR"/}"
echo
echo "  The browser will warn until the CA is in your trust store."
echo "  To get rid of the warning for good (Linux, Debian/Ubuntu):"
echo "    sudo cp ${CA_CRT#"$LAB_DIR"/} /usr/local/share/ca-certificates/${CA_FILE_NAME}"
echo "    sudo update-ca-certificates"
echo "  Firefox has its own store: Settings > Privacy > Certificates > Authorities."
