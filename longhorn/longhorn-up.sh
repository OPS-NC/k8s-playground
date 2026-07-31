#!/usr/bin/env bash
#
# longhorn-up.sh — installe Longhorn (stockage bloc répliqué) et expose son UI en HTTPS
# sous longhorn.$LAB_DOMAIN via main-gateway.
#
#   ./longhorn/longhorn-up.sh <talos|kubeadm>     (ou ./install.sh <distro> longhorn)
#
# Addon à part : platform-up.sh ne pose que Cilium + Envoy + metrics + le wildcard TLS.
#
# ⚠️ LE prérequis iSCSI n'est PAS au même endroit selon la distribution — c'est la
#    différence structurante de ce composant :
#
#    Talos (LONGHORN_PREP_REQUISE=true) : deux étapes préalables, prises en charge ici.
#      1. les extensions `iscsi-tools` / `util-linux-tools` sont CUITES dans l'image de
#         l'installeur (`talosctl get extensions`) : un node sans elles est irrécupérable
#         sans réinstallation (`iscsiadm: not found` => CSI en CrashLoopBackOff), d'où un
#         échec AVANT de poser le chart. Image à générer depuis longhorn/schematic.yaml.
#      2. montage kubelet `rshared` sur /var/lib/longhorn (longhorn/patch-longhorn.yaml,
#         `talosctl patch mc`) : le kubelet Talos tourne dans un conteneur sans propagation
#         de montage bidirectionnelle. Appliqué à chaud, sans reboot, et seulement là où
#         il manque.
#
#    kubeadm (LONGHORN_PREP_REQUISE=false) : les deux tombent.
#      1. le prérequis iSCSI est un PAQUET : `kubeadm/provision.sh` fait
#         `apt-get install -y open-iscsi nfs-common`, `systemctl enable --now iscsid` et
#         charge `iscsi_tcp` sur CHAQUE node, au provisioning ;
#      2. `/var/lib/longhorn` est un dossier ordinaire du système de fichiers racine et le
#         kubelet tourne directement sur l'hôte : la propagation de montage est déjà bonne.
#      => ni `talosctl`, ni `TALOSCONFIG`, ni patch : le script passe de 5 étapes à 3.
#
# Prérequis : plateforme en place (main-gateway HTTPS + Secret wildcard), helm
#             (+ talosctl sur Talos).
# Idempotent : `helm upgrade --install` + `kubectl apply` (+ patch mc posé seulement si
# absent). Relançable sans casse.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Version épinglée (overridable par variable d'env) ----------------------
LONGHORN_VERSION="${LONGHORN_VERSION:-1.12.0}"

# --- Pré-requis -------------------------------------------------------------
need kubectl helm
if [ "$LONGHORN_PREP_REQUISE" = "true" ]; then
  need talosctl
  export TALOSCONFIG="${TALOSCONFIG:-${LAB_DIR}/_out/talosconfig}"
fi
exiger_apiserver

# --- Préparation des nodes (Talos uniquement) -------------------------------
# Les volumes Longhorn ne vivent que sur des nodes planifiables : on adresse donc les
# workers, dont les IP se déduisent des mêmes clés que le Vagrantfile du lab.
if [ "$LONGHORN_PREP_REQUISE" = "true" ]; then
  WORKERS="$(lire_param WORKERS 3)"
  NETWORK="$(lire_param NETWORK 192.168.56)"
  WK_IP_START="$(lire_param WK_IP_START 101)"
  WK_IP_STEP="$(lire_param WK_IP_STEP 1)"
  worker_ips=()
  for ((i = 1; i <= WORKERS; i++)); do
    worker_ips+=("${NETWORK}.$((WK_IP_START + (i - 1) * WK_IP_STEP))")
  done
  [ "${#worker_ips[@]}" -gt 0 ] || fail "WORKERS=0 — Longhorn n'a aucun node de stockage."

  log "[Talos 1/2] Extensions iscsi sur les ${WORKERS} worker(s) : ${worker_ips[*]}"
  # Une extension est cuite dans l'installeur : si elle manque, on ne peut RIEN faire ici
  # (il faut réinstaller/upgrader le node), donc on échoue avant de poser le chart.
  for ip in "${worker_ips[@]}"; do
    if talosctl -n "$ip" get extensions 2>/dev/null | grep -q 'iscsi-tools'; then
      echo "    ${ip} : iscsi-tools OK"
    else
      fail "${ip} n'a pas l'extension iscsi-tools.
        INSTALLER_IMAGE (lab.env) doit pointer l'image factory du schematic
        longhorn/schematic.yaml, puis le node doit être (ré)installé.
        Cluster déjà en route : talosctl -n ${ip} upgrade --image <factory> --preserve"
    fi
  done

  log "[Talos 2/2] Montage kubelet rshared /var/lib/longhorn (patch-longhorn.yaml)"
  # `cluster-up.sh` ne passe QUE patch-all / patch-cp / cni-* au gen config : sur un
  # cluster neuf ce montage est toujours absent. Posé à chaud, sans reboot.
  for ip in "${worker_ips[@]}"; do
    if talosctl -n "$ip" get mc -o yaml 2>/dev/null | grep -q '/var/lib/longhorn'; then
      echo "    ${ip} : extraMounts déjà présent, rien à faire"
    else
      echo "    ${ip} : application du patch…"
      talosctl -n "$ip" patch mc --patch "@${HERE}/patch-longhorn.yaml"
    fi
  done
fi

# --- Nombre de nodes de stockage : DÉTECTÉ, pas déduit de lab.env ------------
# Les volumes Longhorn ne vivent que là où des pods peuvent se planifier — les workers
# dans le cas normal (les CP portent `node-role.kubernetes.io/control-plane:NoSchedule`).
# On interroge donc le cluster plutôt que de faire confiance à WORKERS de lab.env, qui
# n'exprime qu'une intention.
# Cas WORKERS=0 : topologie SUPPORTÉE ici (`UNTAINT_CP=auto` déteinte alors les control
# planes, cf. lab.env) — ils deviennent les seuls nodes de stockage, on les compte.
# `|| true` : sous `pipefail`, un pipeline en échec ferait échouer l'affectation et, sous
# `set -e`, tuerait le script — même piège que `grep` plus haut.
STORAGE_NODES="$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)"
if [ "${STORAGE_NODES:-0}" -eq 0 ]; then
  STORAGE_NODES="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)"
fi
[ "${STORAGE_NODES:-0}" -gt 0 ] || { echo "ERREUR : aucun node planifiable — Longhorn n'a nulle part où stocker." >&2; exit 1; }

# Nb de réplicas bloc = nb de nodes de stockage, plafonné à 3 : `defaultReplicaCount` > nb
# de nodes laisse tous les volumes « Degraded » à vie (piège documenté du README).
REPLICAS="${REPLICAS:-$STORAGE_NODES}"
[ "$REPLICAS" -gt 3 ] && REPLICAS=3

# ============================================================================
log "[1/3] Namespace longhorn-system (PodSecurity privileged)"
# Les pods Longhorn sont privilégiés (iSCSI, hostPath). Sur Talos (PodSecurity `baseline` au
# niveau cluster) ce label est INDISPENSABLE : sans lui les pods sont refusés. Sur kubeadm,
# aucun niveau n'est appliqué par défaut — l'étiquette documente l'intention et garde le
# namespace fonctionnel si le cluster est durci plus tard (--admission-control-config-file).
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite

# ============================================================================
log "[2/3] Chart Longhorn ${LONGHORN_VERSION} (${REPLICAS} réplica(s) bloc, ${STORAGE_NODES} node(s) de stockage) + StorageClass longhorn-r1"
helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
helm repo update longhorn >/dev/null
# values.yaml porte 3 réplicas (topologie « pleine » du lab) ; on l'aligne sur le nombre de
# nodes de stockage réellement présents.
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version "${LONGHORN_VERSION}" \
  --values "${HERE}"/values.yaml \
  --set "defaultSettings.defaultReplicaCount=${REPLICAS}" \
  --set "persistence.defaultClassReplicaCount=${REPLICAS}" \
  --wait --timeout 10m
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=300s
kubectl apply -f "${HERE}"/longhorn-r1-storageclass.yaml

# ============================================================================
log "[3/3] HTTPRoute longhorn.${LAB_DOMAIN}"
# Le manifeste versionné porte le domaine neutre : substitué à la volée, comme
# partout ailleurs dans k8s-playground/ (cf. ../README.md).
rendre "${HERE}"/httproute.yaml | kubectl apply -f -

# ============================================================================
log "Longhorn installé."
echo "  StorageClass : longhorn (${REPLICAS} réplica(s), défaut du cluster) + longhorn-r1 (1 réplica)"
echo "  UI           : https://longhorn.${LAB_DOMAIN}   (AUCUNE authentification !)"
echo "  Sans exposer : kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80"
echo "  Vérifier     : kubectl -n longhorn-system get nodes.longhorn.io"
echo
echo "  /!\\ L'UI Longhorn n'a aucune auth et permet de SUPPRIMER des volumes : ne l'expose"
echo "      qu'en réseau de confiance, ou pose une SecurityPolicy Envoy (cf. README)."
