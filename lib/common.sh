#!/usr/bin/env bash
#
# lib/common.sh — socle commun à TOUS les scripts d'installation de ce dépôt.
#
# Ce dépôt centralise les ressources Kubernetes de deux labs Vagrant qui n'ont PAS le même
# système de base :
#   - Vagrant-Talos   : Talos Linux (OS immuable, / et /usr en lecture seule, pas de systemd,
#                       PodSecurity `baseline` par défaut au niveau cluster, `talosctl`)
#   - Vagrant-KubeADM : Debian 13 + kubeadm (OS classique, aucun PodSecurity par défaut,
#                       kube-proxy optionnel car remplaçable par Cilium en eBPF)
#
# Tout ce qui diverge est isolé dans un PROFIL (`lib/profiles/<distro>.sh`) chargé ici. Les
# scripts d'installation ne testent donc jamais la distribution à coups de `if` dispersés :
# ils lisent des variables (`LOCAL_PATH_DIR`, `TRIVY_NODE_COLLECTOR`, …) dont la valeur vient
# du profil.
#
# Utilisation dans un *-up.sh :
#   HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${HERE}/../lib/common.sh"
#   k8s_init "$@"          # résout la distro (argument, env, lab.env, ou détection cluster)
#
# La distribution se choisit, par ordre de priorité :
#   1. 1er argument positionnel      ./longhorn/longhorn-up.sh talos
#      (ou --distro=talos)
#   2. variable d'env                K8S_DISTRO=talos ./longhorn/longhorn-up.sh
#   3. `DISTRO=` / `K8S_DISTRO=` dans lab.env
#   4. détection sur le cluster      (osImage du 1er node : « Talos » ou non)
# Sans rien de tout ça, on refuse de continuer : appliquer un manifeste « Talos » sur Debian
# (ou l'inverse) donne des pannes silencieuses, pas des erreurs franches.

# shellcheck shell=bash

# --- Racine du dépôt ---------------------------------------------------------
# `lib/common.sh` est toujours à un niveau sous la racine, quel que soit le script qui le
# source (racine, dossier de composant, ou sous-dossier comme minio-s3/cluster/).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# --- Affichage ---------------------------------------------------------------
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m/!\\ %s\033[0m\n' "$*" >&2; }
fail() { printf '\033[1;31mERREUR : %s\033[0m\n' "$*" >&2; exit 1; }

# need BIN... — vérifie la présence des binaires exigés par le script appelant.
need() {
  local bin
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || fail "'$bin' introuvable dans le PATH."
  done
}

# --- Où sont les fichiers du lab (lab.env, _out/) ? --------------------------
# Ce dépôt ne contient PAS de Vagrantfile : le cluster est monté par l'un des deux labs
# voisins, et c'est LUI qui porte `lab.env` (l'intention) et `_out/` (les faits : kubeconfig,
# talosconfig, cluster.env). On les cherche donc, dans l'ordre :
#   1. $LAB_ENV / $LAB_DIR (explicites)
#   2. la racine de ce dépôt (utile si tu y déposes un lab.env ou un lien symbolique)
#   3. le dépôt Vagrant voisin correspondant à la distribution choisie
_resoudre_lab_dir() {
  local candidat
  if [ -n "${LAB_DIR:-}" ]; then printf '%s' "$LAB_DIR"; return; fi
  if [ -n "${LAB_ENV:-}" ]; then printf '%s' "$(cd "$(dirname "$LAB_ENV")" && pwd)"; return; fi
  if [ -f "${REPO_ROOT}/lab.env" ] || [ -d "${REPO_ROOT}/_out" ]; then
    printf '%s' "$REPO_ROOT"; return
  fi
  for candidat in "${REPO_ROOT}/../${LAB_REPO_NAME:-}" ; do
    [ -n "${LAB_REPO_NAME:-}" ] && [ -d "$candidat" ] && { printf '%s' "$(cd "$candidat" && pwd)"; return; }
  done
  printf '%s' "$REPO_ROOT"
}

# --- Lecture des paramètres --------------------------------------------------
# `sed -n s///p` et JAMAIS `grep` : un `grep` sans correspondance renvoie 1 et, sous
# `set -e` + `pipefail`, tue le script — silencieusement, dès qu'une clé manque. Le
# `|| true` couvre l'absence du fichier (sed sort en 2).
#
# `lab.env` est écrit à la main : il peut porter `export CLÉ=valeur` ET un commentaire de
# fin de ligne. Les deux DOIVENT être gérés, sinon `LAB_DOMAIN=lab.example.com  # perso`
# donne `lab.example.com#perso` et le nom du Secret TLS dérivé devient un identifiant
# Kubernetes invalide. Convention commune aux deux labs : un commentaire est un `#`
# PRÉCÉDÉ d'une espace.
lire_lab_env() {
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" \
    "${LAB_ENV_FILE}" 2>/dev/null | head -n1 \
    | sed 's/[[:space:]][[:space:]]*#.*$//' | tr -d " \"'" || true
}

# `_out/cluster.env` (kubeadm uniquement) est GÉNÉRÉ par cluster-up.sh : il porte des
# valeurs DÉTECTÉES sur le cluster réel (interface host-only, CIDR pod effectif, choix
# kube-proxy) là où lab.env n'exprime qu'une intention. Ni `export`, ni commentaire.
lire_cluster_env() {
  sed -n "s/^[[:space:]]*$1=//p" \
    "${CLUSTER_ENV_FILE}" 2>/dev/null | head -n1 | tr -d " \"'" || true
}

# lire_param NOM DEFAUT — environnement > _out/cluster.env > lab.env > défaut.
lire_param() {
  local v="${!1:-}"
  [ -z "$v" ] && v="$(lire_cluster_env "$1")"
  [ -z "$v" ] && v="$(lire_lab_env "$1")"
  printf '%s' "${v:-$2}"
}

# --- Détection de la distribution sur un cluster en marche -------------------
# `osImage` du premier node : « Talos (v1.13.7) » sur Talos, « Debian GNU/Linux 13 (trixie) »
# sur le lab kubeadm. C'est le dernier recours, uniquement si rien n'a été déclaré.
_detecter_distro() {
  local os
  os="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}' 2>/dev/null || true)"
  case "$os" in
    *Talos*) printf 'talos' ;;
    ?*)      printf 'kubeadm' ;;   # tout autre OS : lab Debian/kubeadm
    *)       printf '' ;;
  esac
}

usage_distro() {
  cat >&2 <<EOF
Distribution cible non déterminée.

  Passe-la en argument :        $(basename "${BASH_SOURCE[2]:-$0}") <talos|kubeadm>
  ou en variable d'env :        K8S_DISTRO=talos $(basename "${BASH_SOURCE[2]:-$0}")
  ou dans le lab.env du lab :   DISTRO=talos

Les deux valeurs supportées sont 'talos' et 'kubeadm' (cf. README.md).
EOF
  exit 1
}

# --- k8s_init [args...] ------------------------------------------------------
# Point d'entrée unique : résout la distro, charge son profil, calcule le domaine du lab
# et les noms dérivés, positionne KUBECONFIG. Les arguments non consommés (tout ce qui
# n'est pas la distro) sont replacés dans le tableau K8S_ARGS.
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

  # lab.env peut porter la distro : il faut donc le localiser AVANT de la connaître, d'où
  # cette première résolution sans nom de dépôt voisin (elle ne regarde que $LAB_*/racine).
  LAB_ENV_FILE="${LAB_ENV:-$(_resoudre_lab_dir)/lab.env}"
  [ -z "$distro" ] && distro="$(lire_lab_env DISTRO)"
  [ -z "$distro" ] && distro="$(lire_lab_env K8S_DISTRO)"
  [ -z "$distro" ] && distro="$(_detecter_distro)"
  [ -z "$distro" ] && usage_distro

  case "$distro" in
    talos|kubeadm) ;;
    *) fail "distribution '${distro}' inconnue (talos|kubeadm)." ;;
  esac
  K8S_DISTRO="$distro"
  export K8S_DISTRO

  # Profil : c'est lui qui porte TOUT ce qui diverge entre les deux labs.
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/lib/profiles/${K8S_DISTRO}.sh"

  # Maintenant que LAB_REPO_NAME est connu (posé par le profil), on peut retomber sur le
  # dépôt Vagrant voisin pour lab.env / _out/.
  LAB_DIR="$(_resoudre_lab_dir)"
  LAB_ENV_FILE="${LAB_ENV:-${LAB_DIR}/lab.env}"
  CLUSTER_ENV_FILE="${CLUSTER_ENV:-${LAB_DIR}/_out/cluster.env}"
  export LAB_DIR LAB_ENV_FILE CLUSTER_ENV_FILE
  export KUBECONFIG="${KUBECONFIG:-${LAB_DIR}/kubeconfig}"

  # --- Domaine du lab : défaut versionné NEUTRE (le dépôt est public) --------
  # Les manifestes portent `lab.example.io` ; il est remplacé à la volée (cf. `rendre`)
  # par LAB_DOMAIN. Le défaut dépend de la distro pour que les deux labs puissent tourner
  # côte à côte sans collision de noms DNS.
  LAB_DOMAIN="${LAB_DOMAIN:-$(lire_lab_env LAB_DOMAIN)}"
  LAB_DOMAIN="${LAB_DOMAIN:-$DEFAULT_LAB_DOMAIN}"
  # Nom du Certificate/Secret wildcard : dérivé du domaine (points -> tirets).
  LAB_DOMAIN_DASH="${LAB_DOMAIN//./-}"
  WILDCARD_TLS="wildcard-${LAB_DOMAIN_DASH}-tls"
  export LAB_DOMAIN LAB_DOMAIN_DASH WILDCARD_TLS
}

# --- rendre FICHIER... -------------------------------------------------------
# Écrit sur stdout le manifeste versionné avec les valeurs NEUTRES substituées :
#   lab.example.io   -> $LAB_DOMAIN        (hostnames, HTTPRoute, values Helm…)
#   lab-example-io   -> $LAB_DOMAIN_DASH   (nom du Secret TLS wildcard)
#   lab-kv           -> $VAULT_KV_MOUNT    (moteur KV-v2 de démo : talos-lab / kubeadm-lab)
# Aucun fichier versionné n'est réécrit : `git status` reste propre.
rendre() {
  sed -e "s/lab\.example\.io/${LAB_DOMAIN}/g" \
      -e "s/lab-example-io/${LAB_DOMAIN_DASH}/g" \
      -e "s/lab-kv/${VAULT_KV_MOUNT}/g" "$@"
}

# --- exiger_apiserver --------------------------------------------------------
exiger_apiserver() {
  kubectl get --raw='/readyz' >/dev/null 2>&1 \
    || fail "apiserver injoignable (KUBECONFIG=${KUBECONFIG}).
        Monte d'abord le cluster : ${CLUSTER_UP_HINT}"
}

# --- exiger_sc SC -----------------------------------------------------------
exiger_sc() {
  kubectl get storageclass "$1" >/dev/null 2>&1 \
    || fail "StorageClass '$1' absente. Installe le stockage d'abord :
        ./install.sh ${K8S_DISTRO} longhorn      (ou local-path pour du stockage node-local)"
}

# --- resume_distro ----------------------------------------------------------
# Une ligne de rappel, affichée en tête de chaque installation : savoir sur quel profil on
# tourne évite 90 % des « pourquoi ça ne marche pas ? ».
resume_distro() {
  printf '\033[0;90m    profil %s (%s) · domaine *.%s · lab.env %s\033[0m\n' \
    "$K8S_DISTRO" "$DISTRO_LABEL" "$LAB_DOMAIN" \
    "$([ -f "$LAB_ENV_FILE" ] && printf '%s' "${LAB_ENV_FILE/#$HOME/~}" || printf 'absent (défauts)')"
}
