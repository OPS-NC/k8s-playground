#!/usr/bin/env bash
#
# lib/common.sh — the shared core of EVERY install script in this repository.
#
# This repository centralises the Kubernetes resources of two Vagrant labs that do NOT share
# the same base system:
#   - Vagrant-Talos   : Talos Linux (immutable OS, / and /usr read-only, no systemd,
#                       PodSecurity `baseline` enforced cluster-wide, `talosctl`)
#   - Vagrant-KubeADM : Debian 13 + kubeadm (ordinary OS, no PodSecurity level enforced,
#                       kube-proxy optional since Cilium can replace it in eBPF)
#
# Everything that diverges is isolated in a PROFILE (`lib/profiles/<distro>.sh`) loaded here.
# Install scripts therefore never test the distribution through scattered `if`s: they read
# variables (`LOCAL_PATH_DIR`, `TRIVY_NODE_COLLECTOR`, …) whose value comes from the profile.
#
# Usage inside a *-up.sh:
#   HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${HERE}/../lib/common.sh"
#   k8s_init "$@"          # resolves the distro (argument, env, lab.env, or cluster probe)
#
# The distribution is picked, in order of precedence:
#   1. first positional argument     ./longhorn/longhorn-up.sh talos
#      (or --distro=talos)
#   2. environment variable          K8S_DISTRO=talos ./longhorn/longhorn-up.sh
#   3. `DISTRO=` / `K8S_DISTRO=` in lab.env
#   4. probing the cluster           (osImage of the first node: "Talos" or not)
# With none of the above we refuse to continue: applying a "Talos" manifest on Debian (or the
# other way round) produces silent breakage, not clear errors.

# shellcheck shell=bash

# --- Repository root ---------------------------------------------------------
# `lib/common.sh` always sits one level below the root, whatever script sources it (the root,
# a component directory, or a nested one such as minio-s3/cluster/).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# --- Output ------------------------------------------------------------------
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m/!\\ %s\033[0m\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# need BIN... — checks that the binaries the calling script requires are present.
need() {
  local bin
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || fail "'$bin' not found in PATH."
  done
}

# --- Where do the lab files live (lab.env, _out/)? ---------------------------
# This repository contains NEITHER a Vagrantfile NOR a lab.env, and that is deliberate: there
# is only ONE source of truth for the topology, the Vagrant lab that brings the cluster up. It
# is the one carrying `lab.env` (the intent) and `_out/` (the facts: kubeconfig, talosconfig,
# cluster.env). So it has to be located.
#
# The NORMAL layout is the submodule: this repository is mounted on `<lab>/_k8s`, so the lab is
# simply the parent directory. We recognise it by its `Vagrantfile` — an unambiguous signal,
# present from the clone, before any `vagrant up`.
#
# Resolution order:
#   1. $LAB_DIR / $LAB_ENV                  explicit override, always wins
#   2. the PARENT directory if it holds a Vagrantfile    => submodule layout
#   3. ../$LAB_REPO_NAME                    => "sibling repositories" layout
#      (only known AFTER the profile is loaded, cf. k8s_init: this candidate is therefore
#       evaluated on the second call only)
#   4. the root of this repository if a lab.env or an _out/ was dropped here (standalone use)
#   5. fallback: the root of this repository
_is_lab_dir() { [ -f "$1/Vagrantfile" ]; }

_resolve_lab_dir() {
  local candidate
  if [ -n "${LAB_DIR:-}" ]; then printf '%s' "$LAB_DIR"; return; fi
  if [ -n "${LAB_ENV:-}" ]; then printf '%s' "$(cd "$(dirname "$LAB_ENV")" && pwd)"; return; fi

  # Submodule layout: `<lab>/_k8s` -> the lab is the parent. Tested BEFORE this repository's
  # root, so that a leftover `_out/` lying around here never takes precedence over the real
  # lab. The `Vagrantfile` test rules out any false positive in the sibling layout, where the
  # parent is a plain working directory with no Vagrantfile.
  if _is_lab_dir "${REPO_ROOT}/.."; then
    printf '%s' "$(cd "${REPO_ROOT}/.." && pwd)"; return
  fi

  # "Sibling repositories" layout: ../Vagrant-Talos or ../Vagrant-KubeADM.
  candidate="${REPO_ROOT}/../${LAB_REPO_NAME:-}"
  if [ -n "${LAB_REPO_NAME:-}" ] && [ -d "$candidate" ]; then
    printf '%s' "$(cd "$candidate" && pwd)"; return
  fi

  if [ -f "${REPO_ROOT}/lab.env" ] || [ -d "${REPO_ROOT}/_out" ]; then
    printf '%s' "$REPO_ROOT"; return
  fi
  printf '%s' "$REPO_ROOT"
}

# --- Reading parameters ------------------------------------------------------
# `sed -n s///p` and NEVER `grep`: a `grep` with no match returns 1 and, under `set -e` +
# `pipefail`, kills the script — silently, as soon as one key is missing. The `|| true`
# covers a missing file (sed exits 2).
#
# `lab.env` is hand-written: it may carry `export KEY=value` AND a trailing comment. Both MUST
# be handled, otherwise `LAB_DOMAIN=lab.example.com  # mine` yields `lab.example.com#mine` and
# the derived TLS Secret name becomes an invalid Kubernetes identifier. Convention shared by
# both labs: a comment is a `#` PRECEDED by a space.
read_lab_env() {
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" \
    "${LAB_ENV_FILE}" 2>/dev/null | head -n1 \
    | sed 's/[[:space:]][[:space:]]*#.*$//' | tr -d " \"'" || true
}

# `_out/cluster.env` (kubeadm only) is GENERATED by cluster-up.sh: it carries values DETECTED
# on the real cluster (host-only interface, effective pod CIDR, kube-proxy choice) where
# lab.env only expresses an intent. Neither `export` nor comments.
read_cluster_env() {
  sed -n "s/^[[:space:]]*$1=//p" \
    "${CLUSTER_ENV_FILE}" 2>/dev/null | head -n1 | tr -d " \"'" || true
}

# read_param NAME DEFAULT — environment > _out/cluster.env > lab.env > default.
read_param() {
  local v="${!1:-}"
  [ -z "$v" ] && v="$(read_cluster_env "$1")"
  [ -z "$v" ] && v="$(read_lab_env "$1")"
  printf '%s' "${v:-$2}"
}

# --- Detecting the distribution ----------------------------------------------
# The goal: `./_k8s/platform-up.sh` must work from the root of either lab, with NO argument
# and no variable. So we look at the lab itself first.
#
# Two families of signals, from the most to the least reliable:
#
#   1. The lab STRUCTURE. Each Vagrant repository carries the bootstrap script of its own
#      distribution: `talos/cluster-up.sh` or `kubeadm/cluster-up.sh`. Present from the clone,
#      therefore BEFORE any `vagrant up` — the earliest available signal, and the one that
#      depends on no running cluster.
#   2. The bootstrap ARTEFACTS in `_out/`: `talosconfig` only exists on Talos, `cluster.env`
#      is only written by kubeadm/cluster-up.sh. Useful when the structure was renamed.
#
# Probing the cluster (`osImage` of the first node) stays the LAST resort: it needs a cluster
# already up AND a KUBECONFIG already correct — yet KUBECONFIG is only set AFTER the distro is
# resolved (it depends on the profile). By construction, it is therefore the least available
# signal at the very moment we need it.
#
# $1 = lab directory (may be empty: we then fall back to probing the cluster).
_detect_distro() {
  local lab="${1:-}" os

  if [ -n "$lab" ]; then
    # 1. structure of the Vagrant repository
    [ -f "${lab}/talos/cluster-up.sh" ]   && { printf 'talos'   ; return; }
    [ -f "${lab}/kubeadm/cluster-up.sh" ] && { printf 'kubeadm' ; return; }
    # 2. artefacts left behind by the bootstrap
    [ -f "${lab}/_out/talosconfig" ]      && { printf 'talos'   ; return; }
    [ -f "${lab}/_out/cluster.env" ]      && { printf 'kubeadm' ; return; }
  fi

  # 3. "sibling repositories" layout. We can NOT rely on LAB_REPO_NAME here: it is set by the
  # profile, hence after the distro is resolved — the chicken and the egg. So we probe both
  # possible neighbours directly. If both are there we do not decide: better ask than guess
  # and target the wrong cluster.
  local neighbour_talos=0 neighbour_kubeadm=0
  [ -f "${REPO_ROOT}/../Vagrant-Talos/talos/cluster-up.sh" ]     && neighbour_talos=1
  [ -f "${REPO_ROOT}/../Vagrant-KubeADM/kubeadm/cluster-up.sh" ] && neighbour_kubeadm=1
  if [ "$neighbour_talos" = 1 ] && [ "$neighbour_kubeadm" = 0 ]; then printf 'talos'  ; return; fi
  if [ "$neighbour_kubeadm" = 1 ] && [ "$neighbour_talos" = 0 ]; then printf 'kubeadm'; return; fi

  # 4. last resort: the OS of the nodes of an already reachable cluster.
  os="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}' 2>/dev/null || true)"
  case "$os" in
    *Talos*) printf 'talos' ;;
    ?*)      printf 'kubeadm' ;;   # any other OS: Debian/kubeadm lab
    *)       printf '' ;;
  esac
}

distro_usage() {
  cat >&2 <<EOF
Target distribution could not be determined.

  From the root of a Vagrant lab it is DETECTED on its own (presence of talos/cluster-up.sh
  or kubeadm/cluster-up.sh): you should not be seeing this message. If you do, the lab was
  not located — check that this repository really is mounted as a submodule on <lab>/_k8s,
  or force the path:  LAB_DIR=/path/to/the/lab

  Pass it as an argument:      $(basename "${BASH_SOURCE[2]:-$0}") <talos|kubeadm>
  or as an environment var:    K8S_DISTRO=talos $(basename "${BASH_SOURCE[2]:-$0}")
  or in the lab's lab.env:     DISTRO=talos

The two supported values are 'talos' and 'kubeadm' (see README.md).
EOF
  exit 1
}

# --- k8s_init [args...] ------------------------------------------------------
# The single entry point: resolves the distro, loads its profile, computes the lab domain and
# the names derived from it, sets KUBECONFIG. Arguments that were not consumed (anything that
# is not the distro) are put back into the K8S_ARGS array.
k8s_init() {
  local arg distro=""
  K8S_ARGS=()
  for arg in "$@"; do
    case "$arg" in
      talos|kubeadm)          [ -z "$distro" ] && distro="$arg" || K8S_ARGS+=("$arg") ;;
      --distro=*)             distro="${arg#--distro=}" ;;
      *)                      K8S_ARGS+=("$arg") ;;
    esac
  done
  [ -z "$distro" ] && distro="${K8S_DISTRO:-${DISTRO:-}}"

  # lab.env may carry the distro: the lab therefore has to be located BEFORE we know it. This
  # first resolution does not have LAB_REPO_NAME yet (set by the profile), but the rule "the
  # parent holds a Vagrantfile" is enough in the submodule layout — which is what lets
  # `./_k8s/platform-up.sh` work with no argument at all.
  local lab_first
  lab_first="$(_resolve_lab_dir)"
  LAB_ENV_FILE="${LAB_ENV:-${lab_first}/lab.env}"
  [ -z "$distro" ] && distro="$(read_lab_env DISTRO)"
  [ -z "$distro" ] && distro="$(read_lab_env K8S_DISTRO)"
  [ -z "$distro" ] && distro="$(_detect_distro "$lab_first")"
  [ -z "$distro" ] && distro_usage

  case "$distro" in
    talos|kubeadm) ;;
    *) fail "unknown distribution '${distro}' (talos|kubeadm)." ;;
  esac
  K8S_DISTRO="$distro"
  export K8S_DISTRO

  # Profile: it carries EVERYTHING that diverges between the two labs.
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/lib/profiles/${K8S_DISTRO}.sh"

  # Now that LAB_REPO_NAME is known (set by the profile) we can fall back to the neighbouring
  # Vagrant repository for lab.env / _out/.
  LAB_DIR="$(_resolve_lab_dir)"
  LAB_ENV_FILE="${LAB_ENV:-${LAB_DIR}/lab.env}"
  CLUSTER_ENV_FILE="${CLUSTER_ENV:-${LAB_DIR}/_out/cluster.env}"
  export LAB_DIR LAB_ENV_FILE CLUSTER_ENV_FILE
  export KUBECONFIG="${KUBECONFIG:-${LAB_DIR}/kubeconfig}"

  # --- Lab domain: a NEUTRAL versioned default (the repository is public) ----
  # Manifests carry `lab.example.io`; it is substituted on the fly (see `render`) with
  # LAB_DOMAIN. The default depends on the distro so that both labs can run side by side
  # without colliding on DNS names.
  LAB_DOMAIN="${LAB_DOMAIN:-$(read_lab_env LAB_DOMAIN)}"
  LAB_DOMAIN="${LAB_DOMAIN:-$DEFAULT_LAB_DOMAIN}"
  # Name of the wildcard Certificate/Secret: derived from the domain (dots -> dashes).
  LAB_DOMAIN_DASH="${LAB_DOMAIN//./-}"
  WILDCARD_TLS="wildcard-${LAB_DOMAIN_DASH}-tls"
  export LAB_DOMAIN LAB_DOMAIN_DASH WILDCARD_TLS
}

# --- render FILE... ----------------------------------------------------------
# Writes to stdout the versioned manifest with the NEUTRAL values substituted:
#   lab.example.io   -> $LAB_DOMAIN        (hostnames, HTTPRoute, Helm values…)
#   lab-example-io   -> $LAB_DOMAIN_DASH   (name of the wildcard TLS Secret)
#   lab-kv           -> $VAULT_KV_MOUNT    (demo KV-v2 engine: talos-lab / kubeadm-lab)
# No versioned file is ever rewritten: `git status` stays clean.
render() {
  sed -e "s/lab\.example\.io/${LAB_DOMAIN}/g" \
      -e "s/lab-example-io/${LAB_DOMAIN_DASH}/g" \
      -e "s/lab-kv/${VAULT_KV_MOUNT}/g" "$@"
}

# --- require_apiserver -------------------------------------------------------
require_apiserver() {
  kubectl get --raw='/readyz' >/dev/null 2>&1 \
    || fail "apiserver unreachable (KUBECONFIG=${KUBECONFIG}).
        Bring the cluster up first: ${CLUSTER_UP_HINT}"
}

# --- require_sc SC -----------------------------------------------------------
require_sc() {
  kubectl get storageclass "$1" >/dev/null 2>&1 \
    || fail "StorageClass '$1' missing. Install storage first:
        ./install.sh ${K8S_DISTRO} longhorn      (or local-path for node-local storage)"
}

# --- distro_summary ----------------------------------------------------------
# A one-line reminder printed at the top of every install: knowing which profile you are
# running on avoids 90 % of the "why doesn't it work?" questions.
distro_summary() {
  printf '\033[0;90m    profile %s (%s) · domain *.%s · lab.env %s\033[0m\n' \
    "$K8S_DISTRO" "$DISTRO_LABEL" "$LAB_DOMAIN" \
    "$([ -f "$LAB_ENV_FILE" ] && printf '%s' "${LAB_ENV_FILE/#$HOME/~}" || printf 'absent (defaults)')"
}
