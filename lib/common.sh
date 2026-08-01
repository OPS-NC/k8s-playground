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
# Ce dépôt ne contient NI Vagrantfile NI lab.env, et c'est délibéré : il n'y a qu'UNE
# source de vérité pour la topologie, celle du lab Vagrant qui monte le cluster. C'est lui
# qui porte `lab.env` (l'intention) et `_out/` (les faits : kubeconfig, talosconfig,
# cluster.env). Il faut donc le localiser.
#
# La disposition NORMALE est le sous-module : ce dépôt est monté sur `<lab>/_k8s`, donc le
# lab est tout simplement le dossier parent. On le reconnaît à son `Vagrantfile` — signal
# non ambigu, présent dès le clone, avant même tout `vagrant up`.
#
# Ordre de résolution :
#   1. $LAB_DIR / $LAB_ENV                  surcharge explicite, gagne toujours
#   2. le dossier PARENT s'il porte un Vagrantfile    => disposition sous-module
#   3. ../$LAB_REPO_NAME                    => disposition « dépôts voisins »
#      (n'est connu qu'APRÈS le chargement du profil, cf. k8s_init : ce candidat n'est
#       donc évalué qu'au second appel)
#   4. la racine de ce dépôt si on y a déposé un lab.env ou un _out/  (usage autonome)
#   5. repli : la racine de ce dépôt
_est_un_lab() { [ -f "$1/Vagrantfile" ]; }

_resoudre_lab_dir() {
  local candidat
  if [ -n "${LAB_DIR:-}" ]; then printf '%s' "$LAB_DIR"; return; fi
  if [ -n "${LAB_ENV:-}" ]; then printf '%s' "$(cd "$(dirname "$LAB_ENV")" && pwd)"; return; fi

  # Disposition sous-module : `<lab>/_k8s` -> le lab est le parent. Testé AVANT la racine
  # de ce dépôt, pour qu'un `_out/` résiduel traînant ici ne prenne jamais le pas sur le
  # vrai lab. Le test `Vagrantfile` évite tout faux positif en disposition voisine, où le
  # parent est un simple dossier de travail sans Vagrantfile.
  if _est_un_lab "${REPO_ROOT}/.."; then
    printf '%s' "$(cd "${REPO_ROOT}/.." && pwd)"; return
  fi

  # Disposition « dépôts voisins » : ../Vagrant-Talos ou ../Vagrant-KubeADM.
  candidat="${REPO_ROOT}/../${LAB_REPO_NAME:-}"
  if [ -n "${LAB_REPO_NAME:-}" ] && [ -d "$candidat" ]; then
    printf '%s' "$(cd "$candidat" && pwd)"; return
  fi

  if [ -f "${REPO_ROOT}/lab.env" ] || [ -d "${REPO_ROOT}/_out" ]; then
    printf '%s' "$REPO_ROOT"; return
  fi
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

# --- Détection de la distribution ---------------------------------------------
# Objectif : que `./_k8s/platform-up.sh` fonctionne depuis la racine de n'importe lequel
# des deux labs, SANS argument ni variable. On regarde donc d'abord le lab lui-même.
#
# Deux familles de signaux, du plus fiable au moins fiable :
#
#   1. La STRUCTURE du lab. Chaque dépôt Vagrant porte le script de bootstrap de sa
#      distribution : `talos/cluster-up.sh` ou `kubeadm/cluster-up.sh`. Présent dès le
#      clone, donc AVANT tout `vagrant up` — c'est le signal le plus tôt disponible, et
#      celui qui ne dépend d'aucun cluster en marche.
#   2. Les ARTEFACTS de bootstrap dans `_out/` : `talosconfig` n'existe que sur Talos,
#      `cluster.env` n'est écrit que par kubeadm/cluster-up.sh. Utile si la structure a
#      été renommée.
#
# Le sondage du cluster (`osImage` du premier node) reste en DERNIER recours : il exige un
# cluster déjà debout ET un KUBECONFIG déjà correct — or KUBECONFIG n'est positionné
# qu'APRÈS la résolution de la distro (il dépend du profil). C'est donc, par construction,
# le signal le moins disponible au moment où on en a besoin.
#
# $1 = dossier du lab (peut être vide : on se rabat alors sur le sondage du cluster).
_detecter_distro() {
  local lab="${1:-}" os

  if [ -n "$lab" ]; then
    # 1. structure du dépôt Vagrant
    [ -f "${lab}/talos/cluster-up.sh" ]   && { printf 'talos'   ; return; }
    [ -f "${lab}/kubeadm/cluster-up.sh" ] && { printf 'kubeadm' ; return; }
    # 2. artefacts laissés par le bootstrap
    [ -f "${lab}/_out/talosconfig" ]      && { printf 'talos'   ; return; }
    [ -f "${lab}/_out/cluster.env" ]      && { printf 'kubeadm' ; return; }
  fi

  # 3. disposition « dépôts voisins ». On ne peut PAS s'appuyer sur LAB_REPO_NAME ici :
  # il est posé par le profil, donc après la résolution de la distro — l'œuf et la poule.
  # On regarde donc directement les deux voisins possibles. S'ils sont tous les deux là,
  # on ne tranche pas : mieux vaut demander que deviner et se tromper de cluster.
  local voisin_talos=0 voisin_kubeadm=0
  [ -f "${REPO_ROOT}/../Vagrant-Talos/talos/cluster-up.sh" ]     && voisin_talos=1
  [ -f "${REPO_ROOT}/../Vagrant-KubeADM/kubeadm/cluster-up.sh" ] && voisin_kubeadm=1
  if [ "$voisin_talos" = 1 ] && [ "$voisin_kubeadm" = 0 ]; then printf 'talos'  ; return; fi
  if [ "$voisin_kubeadm" = 1 ] && [ "$voisin_talos" = 0 ]; then printf 'kubeadm'; return; fi

  # 4. dernier recours : l'OS des nodes d'un cluster déjà joignable.
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

  Depuis la racine d'un lab Vagrant, elle est DÉTECTÉE toute seule (présence de
  talos/cluster-up.sh ou kubeadm/cluster-up.sh) : tu ne devrais pas voir ce message.
  Si tu le vois, c'est que le lab n'a pas été localisé — vérifie que ce dépôt est bien
  monté en sous-module sur <lab>/_k8s, ou force le chemin :  LAB_DIR=/chemin/du/lab

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

  # lab.env peut porter la distro : il faut donc localiser le lab AVANT de la connaître.
  # Cette première résolution ne dispose pas encore de LAB_REPO_NAME (posé par le profil),
  # mais la règle « le parent porte un Vagrantfile » suffit en disposition sous-module —
  # c'est ce qui permet à `./_k8s/platform-up.sh` de marcher sans le moindre argument.
  local lab_tot
  lab_tot="$(_resoudre_lab_dir)"
  LAB_ENV_FILE="${LAB_ENV:-${lab_tot}/lab.env}"
  [ -z "$distro" ] && distro="$(lire_lab_env DISTRO)"
  [ -z "$distro" ] && distro="$(lire_lab_env K8S_DISTRO)"
  [ -z "$distro" ] && distro="$(_detecter_distro "$lab_tot")"
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
