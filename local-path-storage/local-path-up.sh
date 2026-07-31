#!/usr/bin/env bash
#
# local-path-up.sh — installe Rancher local-path-provisioner : une StorageClass
# `local-path` PAR DÉFAUT qui provisionne des PV sur le disque local des workers.
# Stockage NODE-LOCAL, sans réplication : survit au redémarrage d'un pod, perdu si le node
# meurt. C'est l'alternative « sans Longhorn » pour les addons de ce lab (CloudNativePG…).
#
#   ./local-path-storage/local-path-up.sh <talos|kubeadm>
#
# ⚠️ Le CHEMIN de provisionnement dépend de la distribution (LOCAL_PATH_DIR du profil) :
#      kubeadm : /opt/local-path-provisioner   (chemin de l'AMONT ; /opt est inscriptible)
#      talos   : /var/local-path-provisioner   (sur Talos, seul /var est inscriptible —
#                un helper-pod ne peut RIEN créer sous /opt, il échoue au montage)
#    Le manifeste versionné porte le chemin amont ; il est substitué à la volée ici.
#
# Idempotent : `kubectl apply`. Relançable sans casse.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

need kubectl
exiger_apiserver

# ============================================================================
log "local-path-provisioner (chemin ${LOCAL_PATH_DIR})"
resume_distro
sed "s#/opt/local-path-provisioner#${LOCAL_PATH_DIR}#g" "${HERE}/local-path-storage.yaml" \
  | kubectl apply -f -
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=120s

# ============================================================================
log "Installé."
echo "  StorageClass : $(kubectl get storageclass local-path -o jsonpath='{.metadata.name}{" (défaut="}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{")"}' 2>/dev/null)"
echo "  Test         : kubectl create -f - <<'EOF'"
echo "    (un PVC storageClassName: local-path -> Bound dès qu'un pod le consomme)"
echo "  Chemin hôte  : ${LOCAL_PATH_DIR} sur le worker qui héberge le PV"
if [ "$K8S_DISTRO" = "talos" ]; then
  echo "                 (talosctl -n <worker-ip> ls ${LOCAL_PATH_DIR})"
else
  echo "                 (vagrant ssh k8s-w1 -c 'sudo ls -l ${LOCAL_PATH_DIR}')"
fi
