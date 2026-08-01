#!/usr/bin/env bash
#
# install.sh — point d'entrée unique des ressources Kubernetes de ce dépôt.
#
#   ./install.sh <talos|kubeadm> <composant...>
#
# Exemples :
#   ./install.sh talos platform                 # la plateforme de base sur le lab Talos
#   ./install.sh kubeadm platform longhorn      # plateforme puis stockage bloc
#   ./install.sh talos list                     # ce qui est installable
#   ./install.sh kubeadm all                    # plateforme + tous les addons, dans l'ordre
#
# La distribution est le PREMIER argument, parce que c'est la seule chose qui change
# vraiment d'un lab à l'autre (cf. lib/profiles/). Elle est transmise à chaque script de
# composant, qui reste lançable seul :
#   ./longhorn/longhorn-up.sh talos
#
# Rien n'est installé « en douce » : chaque composant a son dossier, son script et son
# README avec la version PAS-À-PAS des mêmes commandes (utile en formation).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${HERE}/lib/common.sh"

# --- Catalogue ---------------------------------------------------------------
# alias|script|description  — l'ordre est l'ordre d'installation conseillé (`all`).
CATALOGUE=(
  "platform|platform-up.sh|CNI + Envoy Gateway + metrics-server + wildcard TLS (socle)"
  "cilium|cilium/cilium-up.sh|CNI Cilium + pool d'IP LoadBalancer + annonce L2 (ARP)"
  "calico|calico/calico-up.sh|CNI Calico via l'opérateur Tigera (alternative, sans L2)"
  "self-signed|self-signed/selfsigned-up.sh|AC locale + wildcard TLS auto-signé (openssl)"
  "longhorn|longhorn/longhorn-up.sh|stockage bloc répliqué + StorageClass longhorn-r1"
  "local-path|local-path-storage/local-path-up.sh|stockage local dynamique (hostPath)"
  "minio|minio-s3/minio-up.sh|MinIO standalone (S3 + console)"
  "minio-cluster|minio-s3/cluster/minio-cluster-up.sh|MinIO distribué 4 nœuds (cible des sauvegardes)"
  "cnpg|cloudnative-pg/cloudnative-pg-up.sh|opérateur PostgreSQL HA + cluster de démo"
  "keycloak|keycloak/keycloak-up.sh|Keycloak par son opérateur + realm 'lab' (IdP OIDC)"
  "vault|vault-cluster/vault-up.sh|HashiCorp Vault HA (Raft) + UI HTTPS"
  "observability|observability/observability-up.sh|kube-prometheus-stack + Loki + Alloy"
  "npd|node-problem-detector/node-problem-detector-up.sh|node-problem-detector (santé des nodes)"
  "kyverno|kyverno/kyverno-up.sh|Kyverno + Policy Reporter (policies en Audit)"
  "trivy|trivy-operator/trivy-operator-up.sh|Trivy Operator (CVE, config, secrets, RBAC)"
  "argocd|argocd/argocd-up.sh|Argo CD (GitOps) + UI HTTPS"
  "chaos|chaos-kube/chaoskube-up.sh|chaoskube : supprime 1 pod au hasard par heure"
)

usage() {
  cat <<EOF
Usage : ./install.sh <talos|kubeadm> <composant...>
        ./install.sh <talos|kubeadm> list
        ./install.sh <talos|kubeadm> all

Composants :
$(for e in "${CATALOGUE[@]}"; do printf '  %-14s %s\n' "${e%%|*}" "${e##*|}"; done)

Variables utiles :
  LAB_DOMAIN=...     domaine des UI (défaut : <distro>.lab.example.io)
  LAB_ENV=...        chemin du lab.env du lab Vagrant (défaut : détecté dans ../<lab>/)
  KUBECONFIG=...     défaut : <lab>/kubeconfig
  SELF_SIGNED=false  wildcard TLS via cert-manager + Let's Encrypt au lieu de l'auto-signé

Documentation : README.md (EN) · LISEZ-MOI.md (FR) — et un README par dossier, avec
l'installation PAS-À-PAS en commandes manuelles.
EOF
}

resoudre() {  # resoudre ALIAS -> chemin du script, ou vide
  local e
  for e in "${CATALOGUE[@]}"; do
    [ "${e%%|*}" = "$1" ] && { printf '%s' "$(printf '%s' "$e" | cut -d'|' -f2)"; return; }
  done
}

# --- Arguments ---------------------------------------------------------------
[ $# -ge 1 ] || { usage; exit 1; }
k8s_init "$@"           # consomme la distro, laisse le reste dans K8S_ARGS
set -- ${K8S_ARGS[@]+"${K8S_ARGS[@]}"}
[ -n "${1:-}" ] || { usage; exit 1; }

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  list)
    log "Composants installables sur ${K8S_DISTRO} (${DISTRO_LABEL})"
    for e in "${CATALOGUE[@]}"; do printf '  %-14s %s\n' "${e%%|*}" "${e##*|}"; done
    exit 0 ;;
esac

cibles=("$@")
if [ "${1}" = "all" ]; then
  cibles=()
  for e in "${CATALOGUE[@]}"; do
    case "${e%%|*}" in
      calico|local-path|self-signed) continue ;;   # alternatives, pas des étapes de « all »
    esac
    cibles+=("${e%%|*}")
  done
fi

# Validation AVANT d'installer quoi que ce soit : mieux vaut une faute de frappe rejetée
# tout de suite qu'un `all` qui s'arrête au milieu.
for cible in "${cibles[@]}"; do
  [ -n "$(resoudre "$cible")" ] || { echo "ERREUR : composant '${cible}' inconnu." >&2; usage >&2; exit 1; }
done

log "Cible : ${K8S_DISTRO} (${DISTRO_LABEL}) — ${#cibles[@]} composant(s) : ${cibles[*]}"
resume_distro

for cible in "${cibles[@]}"; do
  script="$(resoudre "$cible")"
  log "▶ ${cible} — ${script}"
  bash "${REPO_ROOT}/${script}" "$K8S_DISTRO"
done

log "Terminé : ${cibles[*]}"
