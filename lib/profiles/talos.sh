#!/usr/bin/env bash
#
# lib/profiles/talos.sh — profil « Talos Linux » (dépôt Vagrant-Talos).
#
# Ce que ce profil dit, en une phrase : l'OS est IMMUABLE. `/` et `/usr` sont en lecture
# seule (seul `/var` est inscriptible), il n'y a ni systemd ni journald, l'admission
# PodSecurity applique `baseline` au niveau cluster par défaut, et la configuration des
# nodes passe par `talosctl` (API) — pas par SSH.
#
# Conséquences concrètes, toutes portées par les variables ci-dessous :
#   - un chemin hostPath doit vivre sous /var (local-path-provisioner) ;
#   - un pod privilégié exige un namespace étiqueté `privileged` (sinon refus SILENCIEUX :
#     le Deployment existe, le ReplicaSet ne crée AUCUN pod) ;
#   - les prérequis « paquet » deviennent des EXTENSIONS cuites dans l'image d'installation
#     (iscsi-tools pour Longhorn) : elles ne s'ajoutent pas à chaud ;
#   - tout ce qui bind-monte /etc/systemd ou /lib/systemd échoue (trivy node-collector) ;
#   - Cilium a besoin de valeurs spécifiques (cgroup déjà monté par Talos, capabilities
#     explicites) documentées par l'upstream Cilium pour Talos.

# shellcheck shell=bash

DISTRO_LABEL="Talos Linux (OS immuable)"
LAB_REPO_NAME="Vagrant-Talos"            # dépôt Vagrant voisin (lab.env, _out/)
DEFAULT_LAB_DOMAIN="talos.lab.example.io"
CA_ORG="Vagrant-Talos lab"               # sujet de l'AC auto-signée (self-signed/)
CA_FILE_NAME="vagrant-talos-lab.crt"     # nom suggéré à l'import dans le trust store
CLUSTER_UP_HINT="./talos/cluster-up.sh (dépôt Vagrant-Talos)"
CLUSTER_RESET_HINT="vagrant destroy && vagrant up && ./talos/cluster-up.sh"

# --- Réseau ------------------------------------------------------------------
# Talos nomme l'interface host-only `enp0s8` (noms prédictibles, box officielle).
DEFAULT_HOSTONLY_IF="enp0s8"
# CIDR pod : `cluster.network.podSubnets` de la config machine (défaut Talos ET du lab).
DEFAULT_POD_CIDR="10.244.0.0/16"
# kube-proxy est TOUJOURS posé par Talos dans ce lab : on ne le remplace pas.
KUBE_PROXY_REPLACEABLE=false
DEFAULT_KUBE_PROXY_REPLACEMENT="false"
DEFAULT_VIP="192.168.56.5"               # VIP de l'apiserver (cf. talos/patch-cp.yaml)
# flannel : quand CNI=flannel, Talos l'a DÉJÀ posé au bootstrap — la couche plateforme
# n'a rien à installer.
FLANNEL_PRE_INSTALLED=true

# --- Cilium ------------------------------------------------------------------
# `ipam.mode=kubernetes` : c'est le kube-controller-manager de Talos qui découpe les
# podCIDR par node ; Cilium se contente de les suivre.
CILIUM_IPAM_MODE="kubernetes"
# Valeurs EXIGÉES par Cilium sur Talos (cf. docs Cilium « Talos Linux ») :
#   - cgroup.autoMount.enabled=false + hostRoot : Talos monte déjà cgroup2, et le pod ne
#     peut pas remonter /sys/fs/cgroup lui-même (système de fichiers en lecture seule) ;
#   - capabilities explicites : Talos refuse le `privileged` implicite du chart.
cilium_sets_specifiques() {
  printf '%s\n' \
    '--set' 'cgroup.autoMount.enabled=false' \
    '--set' 'cgroup.hostRoot=/sys/fs/cgroup' \
    '--set' 'securityContext.capabilities.ciliumAgent={CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}' \
    '--set' 'securityContext.capabilities.cleanCiliumState={NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}'
}

# --- Stockage ----------------------------------------------------------------
# local-path-provisioner : `/opt` n'existe pas en écriture sur Talos, seul /var est
# inscriptible → on déplace le chemin de provisionnement.
LOCAL_PATH_DIR="/var/local-path-provisioner"
# Longhorn : deux prérequis PROPRES À TALOS, pris en charge par longhorn-up.sh —
#   1. extensions `iscsi-tools` + `util-linux-tools` cuites dans INSTALLER_IMAGE
#      (cf. longhorn/schematic.yaml) : sans elles, les pods CSI partent en
#      CrashLoopBackOff (`iscsiadm: not found`) et rien ne les répare à chaud ;
#   2. montage kubelet `rshared` sur /var/lib/longhorn (longhorn/patch-longhorn.yaml) :
#      le kubelet Talos tourne dans un conteneur sans propagation bidirectionnelle.
LONGHORN_PREP_REQUISE=true

# --- Sécurité / admission ----------------------------------------------------
# `baseline` appliqué au niveau cluster : tout pod privilégié (hostNetwork, hostPath,
# hostPID) exige un namespace étiqueté `pod-security.kubernetes.io/enforce: privileged`.
PODSECURITY_DEFAUT="baseline (appliqué au niveau cluster)"
# trivy-operator : le node-collector bind-monte /etc/systemd, /lib/systemd, /etc/kubernetes.
# Talos n'a pas de systemd et / + /etc sont en lecture seule → `CreateContainerError:
# mkdir /etc/systemd: read-only file system`. On coupe les deux scanners qui le lancent
# (infra assessment + cluster compliance) ; les scans images/config/secrets/RBAC continuent.
TRIVY_NODE_COLLECTOR=false

# --- Observabilité -----------------------------------------------------------
# etcd, scheduler, controller-manager et kube-proxy n'exposent pas de métriques scrutables
# sans configuration TLS dédiée sur Talos → moniteurs désactivés pour éviter des cibles
# « down » inexplicables en formation.
KPS_SCRAPE_CONTROL_PLANE=false

# --- Authentification OIDC du serveur d'API (dex/) ----------------------------
# La configuration machine EST l'API : `talosctl patch mc` suffit, Talos régénère le
# manifeste statique du kube-apiserver et le redémarre. Ni SSH, ni fichier à éditer.
APISERVER_OIDC_PATCH="apiserver-oidc.talos.yaml"
APISERVER_OIDC_MECANISME="talosctl patch mc (la configuration machine est une API)"
# $1 = chemin du patch à appliquer. Écrit sur stdout les commandes à lancer : ce dépôt
# n'exécute PAS ces commandes, elles redémarrent le serveur d'API (cf. dex/README.md).
apiserver_oidc_commandes() {
  cat <<EOF
    for ip in \$(kubectl get nodes -l node-role.kubernetes.io/control-plane \\
                   -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}'); do
      talosctl -n "\$ip" patch mc --patch @${1}
      kubectl get --raw=/readyz && echo   # vérifier AVANT de passer au suivant
    done
EOF
}

# --- Vault / VSO -------------------------------------------------------------
VAULT_KV_MOUNT="talos-lab"

# --- Divers ------------------------------------------------------------------
METRICS_KUBELET_INSECURE=true
# Config talosctl : nécessaire pour les composants qui parlent à l'API Talos (Longhorn).
TALOSCONFIG_DEFAUT="_out/talosconfig"
