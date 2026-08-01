#!/usr/bin/env bash
#
# platform-up.sh — installs the "platform" layer on an ALREADY bootstrapped cluster, whether
# it comes from the Talos lab or the kubeadm lab.
#
#   ./platform-up.sh <talos|kubeadm>          (or ./install.sh <distro> platform)
#
# ⚠️ Neither lab leaves a usable pod network BEFORE this layer:
#    - kubeadm: `kubeadm init` installs NO CNI, nodes stay NotReady until step [1/4];
#    - Talos  : with CNI=cilium/calico the bootstrap sets `cni.name: none` — same situation.
#      (Only CNI=flannel is already installed by Talos at bootstrap: step [1/4] then does
#      nothing, see FLANNEL_PRE_INSTALLED in lib/profiles/talos.sh.)
#
# Order (every link assumes the previous one):
#   1. CNI + L2 announcer  per `CNI` (cluster.env, then lab.env) — cilium (default, announces
#                          its own LoadBalancer IPs), calico (CNI only), flannel (CNI only),
#                          none. When the CNI does NOT announce, metallb/ is installed right
#                          after it on the SAME range => a LoadBalancer IP in every case.
#                          `METALLB=false` in lab.env opts out (you then have no LB IP).
#   2. Envoy Gateway       controller + Gateway API CRDs + main-gateway (HTTP/HTTPS), then the
#                          `hubble.<LAB_DOMAIN>` route when CNI=cilium (step 1 could not create
#                          it: the Gateway API CRDs did not exist yet)
#   3. metrics-server      metrics.k8s.io (kubectl top)
#   4. wildcard TLS        per `SELF_SIGNED` in lab.env:
#                          true  -> local CA + openssl cert (self-signed/), NO cert-manager
#                          false -> cert-manager + Cloudflare secret + ClusterIssuers (ACME)
#                          Both paths fill the SAME Secret the Gateway serves.
#
# Deliberately EXCLUDED (installed separately, each with its README + up.sh):
#   argocd/ · longhorn/ · vault-cluster/ · vault-secret-operator/ · kyverno/ ·
#   trivy-operator/ · cloudnative-pg/ · observability/ · minio-s3/ · chaos-kube/
#
# Domain: versioned manifests carry the NEUTRAL domain `lab.example.io` (public repository).
# It is replaced on the fly with `LAB_DOMAIN` (env or lab.env; default
# `<distro>.lab.example.io`) — same for `LAB_DNS_ZONE` (DNS-01 solver zone), `LAB_ACME_EMAIL`
# (Let's Encrypt account) and `LAB_ACME_ISSUER` (staging by default / prod on demand). Those
# last three are ONLY used on the ACME path (SELF_SIGNED=false).
#
# Idempotent: `helm upgrade --install` + `kubectl apply`. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${HERE}/lib/common.sh"
k8s_init "$@"

# --- Pinned versions (overridable through an environment variable) -----------
ENVOY_GW_VERSION="${ENVOY_GW_VERSION:-1.8.3}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.1}"

# kubeadm guard rail: without `_out/cluster.env` we fall back to GUESSED values. Better to say
# so here than to let Cilium pin itself to the wrong network card three steps later. Not
# blocking: a hand-built cluster stays usable through lab.env.
# (On Talos that file does not exist: the facts are read from _out/controlplane.yaml.)
if [ "$K8S_DISTRO" = "kubeadm" ] && [ ! -f "$CLUSTER_ENV_FILE" ]; then
  warn "${CLUSTER_ENV_FILE} missing: ./kubeadm/cluster-up.sh was not run (or not all the way
    through). We carry on with lab.env and the defaults, but the host-only interface, the pod
    CIDR and the kube-proxy choice are then NOT verified."
fi

CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-$(read_lab_env CLOUDFLARE_API_TOKEN)}"

# Cloudflare DNS zone hosting LAB_DOMAIN (the ClusterIssuer's `dnsZones` selector): by default
# the last two labels (talos.lab.example.io -> example.io).
LAB_DNS_ZONE="${LAB_DNS_ZONE:-$(read_lab_env LAB_DNS_ZONE)}"
LAB_DNS_ZONE="${LAB_DNS_ZONE:-$(printf '%s\n' "$LAB_DOMAIN" | awk -F. '{ print (NF>1) ? $(NF-1)"."$NF : $NF }')}"
# ACME account e-mail (Let's Encrypt rejects some example domains).
LAB_ACME_EMAIL="${LAB_ACME_EMAIL:-$(read_lab_env LAB_ACME_EMAIL)}"
LAB_ACME_EMAIL="${LAB_ACME_EMAIL:-admin@${LAB_DNS_ZONE}}"

# --- TLS mode: self-signed (default) or cert-manager + Let's Encrypt ---------
# The versioned default is an example domain: with no REAL domain and no Cloudflare token the
# ACME path cannot issue anything anyway, and the lab would be left without TLS. The
# self-signed path works everywhere and offline — so it is the right "it just starts" default.
SELF_SIGNED="${SELF_SIGNED:-$(read_lab_env SELF_SIGNED)}"
SELF_SIGNED="${SELF_SIGNED:-true}"
SELF_SIGNED="$(printf '%s' "$SELF_SIGNED" | tr '[:upper:]' '[:lower:]')"
case "$SELF_SIGNED" in
  true|false) ;;
  *) fail "unknown SELF_SIGNED='${SELF_SIGNED}' (true|false)." ;;
esac

# --- ACME issuer: staging by default, production on demand -------------------
# (ignored when SELF_SIGNED=true: no ACME is involved)
# The wildcard lives ONLY in etcd: destroying the lab destroys it, and the rebuild asks for a
# fresh one. Yet Let's Encrypt PRODUCTION caps at 5 certificates per week for the same set of
# identifiers (`*.<LAB_DOMAIN>`) — a throwaway lab burns that quota in 5 rebuilds, then sits
# without TLS for hours (error 429). Staging has a ~30,000/week quota.
LAB_ACME_ISSUER="${LAB_ACME_ISSUER:-$(read_lab_env LAB_ACME_ISSUER)}"
LAB_ACME_ISSUER="${LAB_ACME_ISSUER:-staging}"
case "$LAB_ACME_ISSUER" in
  staging|prod) ;;
  *) fail "unknown LAB_ACME_ISSUER='${LAB_ACME_ISSUER}' (staging|prod)." ;;
esac
ACME_ISSUER="letsencrypt-${LAB_ACME_ISSUER}"

# --- CNI: who lays down the network? -----------------------------------------
#   cilium  -> Cilium + its L2 pool (ARP announcement)                      => announces itself
#   calico  -> Calico through the Tigera operator (CNI only)                => needs MetalLB
#   flannel -> flannel (CNI only) — ALREADY installed at bootstrap on Talos => needs MetalLB
#   none    -> nobody installs a CNI, that is on you                        => needs MetalLB
CNI="$(read_param CNI cilium)"
case "$CNI" in
  cilium|calico|flannel|none) ;;
  *) fail "unknown CNI='${CNI}' (cilium|calico|flannel|none)." ;;
esac

# --- L2 announcer: who makes a LoadBalancer IP reachable from the host? ------
# Only Cilium announces Service IPs on its own here. For every other CNI the lab installs
# MetalLB in L2 mode, on the SAME range and the same interface (see metallb/): the entry point
# keeps the address the wildcard DNS record points at, whatever the CNI.
#
# `METALLB=false` opts out — for a cluster that already has an announcer (a real
# MetalLB/kube-vip installed by hand, a cloud controller). The Gateway then stays <pending>.
#
# ⚠️ NEVER cilium + MetalLB: two announcers on the same range means two nodes answering ARP
#    for the same IP. Hence the switch below rather than an independent flag, and the guard
#    rail inside metallb-up.sh for a direct call.
METALLB="$(read_param METALLB true)"
METALLB="$(printf '%s' "$METALLB" | tr '[:upper:]' '[:lower:]')"
case "$METALLB" in
  true|false) ;;
  *) fail "unknown METALLB='${METALLB}' (true|false)." ;;
esac
if [ "$CNI" = "cilium" ]; then
  LB_ANNOUNCER=cilium
elif [ "$METALLB" = "true" ]; then
  LB_ANNOUNCER=metallb
else
  LB_ANNOUNCER=none
fi

# LoadBalancer IP range: the 1st IP is the one the Gateway takes (target of the wildcard DNS).
LB_POOL_START="$(read_param LB_POOL_START 192.168.56.200)"

# Network parameters re-read from the real cluster — only used by the flannel branch below
# (cilium-up.sh and calico-up.sh re-read them themselves).
POD_CIDR="$(read_param POD_CIDR "$DEFAULT_POD_CIDR")"
HOSTONLY_IF="$(read_param HOSTONLY_IF "$DEFAULT_HOSTONLY_IF")"
KUBE_PROXY_REPLACEMENT="$(read_param KUBE_PROXY_REPLACEMENT "$DEFAULT_KUBE_PROXY_REPLACEMENT")"
KUBE_PROXY_REPLACEMENT="$(printf '%s' "$KUBE_PROXY_REPLACEMENT" | tr '[:upper:]' '[:lower:]')"

# ⚠️ The forbidden pair (kubeadm only). With KUBE_PROXY_REPLACEMENT=true, `kubeadm init` ran
# with `--skip-phases=addon/kube-proxy`: there is NO kube-proxy in the cluster at all. Only
# Cilium knows how to replace it — with calico/flannel/none no ClusterIP would answer any more
# (CoreDNS included). cluster-up.sh already refuses that pair at bootstrap; we re-check it
# because lab.env may have been edited since, and the breakage would be unreadable.
# On Talos kube-proxy is always installed by the bootstrap: the question does not arise.
if [ "$KUBE_PROXY_REPLACEABLE" = "true" ] && [ "$KUBE_PROXY_REPLACEMENT" = "true" ] && [ "$CNI" != "cilium" ]; then
  fail "KUBE_PROXY_REPLACEMENT=true requires CNI=cilium (here CNI=${CNI}).
        Pick CNI=cilium, or KUBE_PROXY_REPLACEMENT=false + rebuild the cluster
        (${CLUSTER_RESET_HINT})."
fi

# --- Prerequisites ----------------------------------------------------------
need kubectl helm
# openssl is only needed to build the self-signed wildcard.
[ "$SELF_SIGNED" = "true" ] && need openssl
require_apiserver

log "Platform — ${K8S_DISTRO} profile"
distro_summary

# ============================================================================
log "[1/4] CNI = ${CNI}, L2 announcer = ${LB_ANNOUNCER}"
case "$CNI" in
  cilium)
    echo "    -> cilium/cilium-up.sh (CNI + L2 pool)"
    bash "${REPO_ROOT}/cilium/cilium-up.sh" "$K8S_DISTRO"
    ;;
  calico)
    echo "    -> calico/calico-up.sh (CNI only)"
    bash "${REPO_ROOT}/calico/calico-up.sh" "$K8S_DISTRO"
    echo "    Calico announces no LoadBalancer Service IP (BGP only, and there is no peer"
    echo "    router on a host-only network): MetalLB takes that role below."
    ;;
  flannel)
    if [ "$FLANNEL_PRE_INSTALLED" = "true" ]; then
      # Talos: `cluster.network.cni.name: flannel` is its default, the bootstrap laid it down.
      echo "    Talos installed flannel at bootstrap: nothing to do here."
    else
      # kubeadm: flannel has no dedicated directory — it is the lab's DEGRADED path (no
      # LoadBalancer IP, hence no reachable UI), and it fits in a few lines here.
      # Two values are vital, and they are the whole point of going through the chart:
      #   - podCidr MUST equal kubeadm's `networking.podSubnet` (the chart default is
      #     10.244.0.0/16, which happens to be ours — we do NOT bet on that);
      #   - `--iface=<host-only>` pins the right card. Without it flannel follows the default
      #     route and takes the 10.0.2.15 NAT address, identical on every VM: the VXLAN VTEPs
      #     point at an isolated NAT and cross-node pod traffic is broken.
      # Version NOT pinned by default: this path has neither a directory nor a README to keep
      # up to date. `FLANNEL_VERSION=v0.28.8 ./platform-up.sh kubeadm` if you want
      # reproducibility.
      echo "    -> flannel/flannel chart (CNI only, no LoadBalancer IP)"
      helm repo add flannel https://flannel-io.github.io/flannel/ >/dev/null 2>&1 || true
      helm repo update flannel >/dev/null
      flannel_args=(upgrade --install flannel flannel/flannel
        -n kube-flannel --create-namespace
        --set "podCidr=${POD_CIDR}"
        --set-json "flannel.args=[\"--ip-masq\",\"--kube-subnet-mgr\",\"--iface=${HOSTONLY_IF}\"]")
      if [ -n "${FLANNEL_VERSION:-}" ]; then
        flannel_args+=(--version "${FLANNEL_VERSION}")
      fi
      helm "${flannel_args[@]}"
      echo "    waiting for nodes to become Ready..."
      kubectl wait --for=condition=Ready nodes --all --timeout=300s
    fi
    echo "    flannel assigns no LoadBalancer Service IP: MetalLB takes that role below."
    ;;
  none)
    echo "    CNI=none: no CNI installed, neither by the bootstrap nor here."
    kubectl get nodes --no-headers | grep -q ' Ready ' \
      || fail "no Ready node — install your CNI before carrying on."
    ;;
esac

# The announcer comes right AFTER the CNI and BEFORE the Gateway: MetalLB is an ordinary
# workload (it needs the pod network to run at all), and the Envoy Service created at step
# [2/4] then gets its IP the moment it appears, instead of waiting for a later reconcile.
case "$LB_ANNOUNCER" in
  metallb)
    echo "    -> metallb/metallb-up.sh (L2 announcement of ${LB_POOL_START}, the range Cilium would use)"
    bash "${REPO_ROOT}/metallb/metallb-up.sh" "$K8S_DISTRO"
    ;;
  none)
    echo "    /!\\ METALLB=false with CNI=${CNI}: NOTHING announces LoadBalancer IPs."
    echo "        The Gateway will stay on EXTERNAL-IP <pending> and no UI will be"
    echo "        reachable. Drop METALLB=false, or bring your own announcer."
    ;;
esac

log "[2/4] Envoy Gateway ${ENVOY_GW_VERSION} + main-gateway"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GW_VERSION}" -n envoy-gateway-system --create-namespace
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=180s
# Renders the manifest: hostname of the https listener + name of the TLS Secret from
# LAB_DOMAIN, and the ACME issuer from LAB_ACME_ISSUER (the versioned manifest carries
# `staging`). In self-signed mode we REMOVE the Gateway's `annotations:` block (comments
# included): the `cert-manager.io/cluster-issuer` annotation is what triggers the creation of
# a Certificate. Leaving it in place would let cert-manager overwrite our Secret the moment it
# gets installed for some other reason.
render_envoy_proxy() {
  if [ "$SELF_SIGNED" = "true" ]; then
    issuer_edit='/^  annotations:/,\|^    cert-manager\.io/cluster-issuer:|d'
  else
    issuer_edit="s|\(cert-manager\.io/cluster-issuer:\)[[:space:]]*letsencrypt-[a-z]*|\1 ${ACME_ISSUER}|"
  fi
  render "${REPO_ROOT}/envoy-gateway/Envoy-Proxy.yml" | sed -e "$issuer_edit"
}
gateway_ip() {
  kubectl -n envoy-gateway-system get svc \
    -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' \
    2>/dev/null || true
}

if [ "$LB_ANNOUNCER" = "cilium" ]; then
  render_envoy_proxy | kubectl apply -f -
else
  # `loadBalancerClass: io.cilium/l2-announcer` names ONE controller as the only one allowed to
  # serve this Service. Left in place with MetalLB, MetalLB ignores the Service and the IP
  # stays <pending> forever, with a valid pool right next to it — the #1 false lead here.
  render_envoy_proxy | sed '/loadBalancerClass:/d' | kubectl apply -f -
fi

if [ "$LB_ANNOUNCER" != "none" ]; then
  echo "    waiting for the LoadBalancer IP (${LB_ANNOUNCER} L2 announcement, expecting ${LB_POOL_START})..."
  for _ in $(seq 1 30); do
    ip="$(gateway_ip)"
    [ -n "$ip" ] && break
    sleep 5
  done
  if [ -n "${ip:-}" ]; then
    echo "    Gateway EXTERNAL-IP = $ip"
  else
    echo "    /!\\ still <pending> after 150 s. Check the pool and the L2 announcement:"
    if [ "$LB_ANNOUNCER" = "cilium" ]; then
      echo "        kubectl get ciliumloadbalancerippool ; kubectl get ciliuml2announcementpolicy"
    else
      echo "        kubectl get ipaddresspool -n metallb-system ; kubectl get l2advertisement -n metallb-system"
      echo "        kubectl -n metallb-system logs deploy/metallb-controller"
    fi
  fi
else
  echo "    No L2 announcer (CNI=${CNI}, METALLB=false): the Service will stay <pending>."
  echo "    Drop METALLB=false from lab.env to get one (see metallb/README.md)."
fi

# Hubble UI route. It belongs to cilium/, and cilium-up.sh applies it on its own when it can —
# but at step [1/4] the Gateway API CRDs did not exist yet, so on a fresh install it could not.
# Now that main-gateway is there, do it. Idempotent, so a re-run just re-applies it.
if [ "$CNI" = "cilium" ]; then
  echo "    HTTPRoute hubble.${LAB_DOMAIN} -> hubble-ui (see cilium/httproute.yaml)"
  render "${REPO_ROOT}/cilium/httproute.yaml" | kubectl apply -f -
fi

log "[3/4] metrics-server (--kubelet-insecure-tls: self-signed kubelet certificates)"
kubectl apply -f "${REPO_ROOT}/metric-server.yaml"

if [ "$SELF_SIGNED" = "true" ]; then

log "[4/4] Self-signed wildcard TLS (openssl) — cert-manager NOT installed"
echo "    -> self-signed/selfsigned-up.sh (local CA + cert *.${LAB_DOMAIN})"
bash "${REPO_ROOT}/self-signed/selfsigned-up.sh" "$K8S_DISTRO"

else

log "[4/4] cert-manager ${CERT_MANAGER_VERSION} + Cloudflare + ClusterIssuers"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --set config.apiVersion="controller.config.cert-manager.io/v1alpha1" \
  --set config.kind="ControllerConfiguration" \
  --set config.enableGatewayAPI=true
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  kubectl create secret generic cloudflare-api-token -n cert-manager \
    --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "    /!\\ CLOUDFLARE_API_TOKEN empty (neither env nor lab.env): secret NOT created."
  echo "        The wildcard certificate will stay pending until it exists."
fi
# ClusterIssuers: ACME e-mail + solver DNS zone substituted (see the script header).
for issuer in 02-clusterissuer-staging 03-clusterissuer-prod; do
  render "${REPO_ROOT}/cert-manager/${issuer}.yaml" \
    | sed -e "s/admin@example\.io/${LAB_ACME_EMAIL}/g" \
          -e "s/^\([[:space:]]*-[[:space:]]\)example\.io/\1${LAB_DNS_ZONE}/" \
    | kubectl apply -f -
done

# --- Wait for the wildcard cert to be issued (DNS-01) for a truthful summary -
# The cert + the Secret live in the envoy-gateway-system ns (carried by main-gateway).
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  log "Waiting for the wildcard certificate to be issued (DNS-01, ~1-2 min)..."
  for _ in $(seq 1 24); do
    r="$(kubectl -n envoy-gateway-system get certificate "${WILDCARD_TLS}" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [ "$r" = "True" ] && { echo "    cert Ready=True"; break; }
    sleep 10
  done
fi

fi   # end of the SELF_SIGNED switch

# ============================================================================
log "Platform installed (${K8S_DISTRO})."
echo "  CNI          : ${CNI}"
case "$LB_ANNOUNCER" in
  cilium)  echo "  L2 announcer : Cilium (built into the CNI) — pool ${LB_POOL_START}+" ;;
  metallb) echo "  L2 announcer : MetalLB (metallb-system) — pool ${LB_POOL_START}+, same range as Cilium's" ;;
  none)    echo "  L2 announcer : NONE (METALLB=false) — no LoadBalancer IP, no reachable UI" ;;
esac
if [ "$KUBE_PROXY_REPLACEABLE" = "true" ]; then
  echo "  kube-proxy   : $([ "$KUBE_PROXY_REPLACEMENT" = true ] && echo 'REPLACED by Cilium (eBPF)' || echo 'installed by kubeadm')"
else
  echo "  kube-proxy   : installed by Talos (not replaceable in this lab)"
fi
echo "  Nodes        : $(kubectl get nodes --no-headers | grep -c ' Ready ')/$(kubectl get nodes --no-headers | wc -l) Ready"
echo "  Gateway      : $(kubectl -n envoy-gateway-system get gateway main-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)"
if [ "$SELF_SIGNED" = "true" ]; then
  echo "  Wildcard cert: $(kubectl -n envoy-gateway-system get secret "${WILDCARD_TLS}" -o jsonpath='{.metadata.name}' 2>/dev/null || echo 'MISSING') (self-signed) [${WILDCARD_TLS}]"
  echo "  TLS mode     : SELF_SIGNED=true — local CA _out/self-signed/ca.crt, no cert-manager"
  echo "  Domain       : *.${LAB_DOMAIN}  (no public DNS required)"
  echo "                 The browser warns until the CA is imported:"
  echo "                 sudo cp _out/self-signed/ca.crt /usr/local/share/ca-certificates/${CA_FILE_NAME}"
  echo "                 sudo update-ca-certificates"
  echo "                 For a publicly trusted cert: SELF_SIGNED=false + CLOUDFLARE_API_TOKEN."
else
  echo "  Wildcard cert: $(kubectl -n envoy-gateway-system get certificate "${WILDCARD_TLS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '?') (Ready) [${WILDCARD_TLS}]"
  echo "  ACME issuer  : ${ACME_ISSUER}$([ "$LAB_ACME_ISSUER" = "staging" ] && echo '  (cert NOT trusted: browser warning expected)' || echo '  (trusted cert — 5/week quota!)')"
  echo "  Domain       : *.${LAB_DOMAIN}  (DNS zone ${LAB_DNS_ZONE})"
  if [ "$LAB_ACME_ISSUER" = "staging" ]; then
    echo "                 For a trusted cert: LAB_ACME_ISSUER=prod in lab.env, then"
    echo "                 kubectl -n envoy-gateway-system delete secret ${WILDCARD_TLS}"
  fi
fi
echo
echo "  Add-ons to install next (each with its directory + up.sh + step-by-step README):"
echo "    ./install.sh ${K8S_DISTRO} longhorn        (block storage)"
echo "    ./install.sh ${K8S_DISTRO} vault           (HA secrets)"
echo "    ./install.sh ${K8S_DISTRO} argocd          (GitOps, argo.${LAB_DOMAIN})"
echo "    ./install.sh ${K8S_DISTRO} list            (the full catalogue)"
echo
gw_ip="$(gateway_ip || true)"
gw_ip="${gw_ip:-$LB_POOL_START}"
if [ "$SELF_SIGNED" = "true" ]; then
  # No ACME constraint in self-signed mode: the domain never has to exist publicly, local
  # resolution is enough to reach the UIs.
  echo "  Name resolution — do this ONCE to reach the UIs:"
  echo "    an /etc/hosts line (simplest, one subdomain per line):"
  echo "      ${gw_ip}  argo.${LAB_DOMAIN} grafana.${LAB_DOMAIN} vault.${LAB_DOMAIN}"
  echo "    or a wildcard A record  *.${LAB_DOMAIN} -> ${gw_ip}  if you have a DNS zone."
else
  echo "  DNS — do this ONCE at your registrar/Cloudflare to reach the UIs:"
  echo "    A record  *.${LAB_DOMAIN}  ->  ${gw_ip}"
  echo "    in DNS-only (GREY cloud): the Cloudflare proxy cannot reach a private IP."
fi
