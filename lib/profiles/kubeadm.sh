#!/usr/bin/env bash
#
# lib/profiles/kubeadm.sh — profil « Debian 13 + kubeadm » (dépôt Vagrant-KubeADM).
#
# Ce que ce profil dit, en une phrase : l'OS est un Linux ORDINAIRE. Rien n'est en lecture
# seule, systemd est là, les paquets s'installent (`open-iscsi` pour Longhorn), et
# l'admission PodSecurity n'applique AUCUN niveau au niveau cluster par défaut. La plupart
# des contournements écrits pour Talos deviennent donc inutiles ici — on les documente
# comme tels au lieu de les supprimer, pour que la comparaison reste lisible.
#
# La contrepartie : `kubeadm init` n'installe AUCUN réseau pod (les nodes restent NotReady
# jusqu'à ce que la couche CNI passe) et kube-proxy est OPTIONNEL — il peut être remplacé
# par Cilium en eBPF (`KUBE_PROXY_REPLACEMENT=true`, le défaut du lab).

# shellcheck shell=bash

DISTRO_LABEL="Debian 13 + kubeadm"
LAB_REPO_NAME="Vagrant-KubeADM"          # dépôt Vagrant voisin (lab.env, _out/)
DEFAULT_LAB_DOMAIN="kubeadm.lab.example.io"
CA_ORG="Vagrant-KubeADM lab"             # sujet de l'AC auto-signée (self-signed/)
CA_FILE_NAME="vagrant-kubeadm-lab.crt"   # nom suggéré à l'import dans le trust store
CLUSTER_UP_HINT="./kubeadm/cluster-up.sh (dépôt Vagrant-KubeADM)"
CLUSTER_RESET_HINT="./kubeadm/cluster-reset.sh && ./kubeadm/cluster-up.sh"

# --- Réseau ------------------------------------------------------------------
# Interface host-only : Debian 13 utilise les noms prédictibles (`enp0s8`) mais certaines
# box Vagrant gardent `eth1`. cluster-up.sh la DÉTECTE dans la VM et l'écrit dans
# `_out/cluster.env` — ce défaut n'est qu'un dernier recours.
DEFAULT_HOSTONLY_IF="eth1"
# CIDR pod : `networking.podSubnet` passé à `kubeadm init`.
DEFAULT_POD_CIDR="10.244.0.0/16"
# kube-proxy remplaçable en eBPF par Cilium (défaut du lab kubeadm).
KUBE_PROXY_REPLACEABLE=true
DEFAULT_KUBE_PROXY_REPLACEMENT="true"
# Le lab kubeadm est en HA : l'apiserver se joint par la VIP keepalived, jamais par l'IP
# de cp1 (la VIP survit à la perte de cp1 et c'est elle qui est dans les certificats).
DEFAULT_VIP="192.168.56.5"
# flannel : AUCUN CNI n'est posé au bootstrap, c'est donc à la couche plateforme de
# l'installer (chart flannel/flannel).
FLANNEL_PRE_INSTALLED=false

# --- Cilium ------------------------------------------------------------------
# Sur Debian, les défauts du chart sont les bons : le chart monte lui-même le cgroup2 et
# calcule les capabilities de l'agent. Les `cgroup.autoMount.enabled=false`,
# `cgroup.hostRoot` et `securityContext.capabilities.*` que documente Cilium sont propres
# à Talos — ici ils seraient NUISIBLES.
CILIUM_IPAM_MODE="cluster-pool"          # le pool pod est géré par l'opérateur Cilium
cilium_sets_specifiques() { :; }         # rien à ajouter

# --- Stockage ----------------------------------------------------------------
# local-path-provisioner : chemin de l'AMONT. Sur Debian 13 `/opt` est inscriptible et le
# helper-pod le crée sans rien demander à personne.
LOCAL_PATH_DIR="/opt/local-path-provisioner"
# Longhorn : le prérequis iSCSI est un PAQUET (`open-iscsi`, posé par kubeadm/provision.sh),
# pas une extension d'image système — rien à vérifier ni à patcher avant le chart, et
# `/var/lib/longhorn` est un dossier ordinaire dont la propagation de montage est déjà bonne.
LONGHORN_PREP_REQUISE=false

# --- Sécurité / admission ----------------------------------------------------
# Aucun niveau PodSecurity appliqué au niveau cluster : les labels `privileged` posés sur
# les namespaces ne débloquent rien AUJOURD'HUI. On les garde parce qu'ils documentent le
# besoin réel des pods et qu'ils protègent le jour où l'admission est durcie.
PODSECURITY_DEFAUT="(aucun niveau appliqué par défaut)"
# trivy-operator : le node-collector bind-monte /etc/systemd, /lib/systemd, /etc/kubernetes…
# Tous ces chemins existent et sont lisibles sur Debian → les deux scanners « node »
# fonctionnent tels quels.
TRIVY_NODE_COLLECTOR=true

# --- Observabilité -----------------------------------------------------------
# controller-manager et scheduler écoutent sur 0.0.0.0 (bind-address posé par
# kubeadm/templates/kubeadm-init.yaml.tpl) et etcd expose ses métriques sur 0.0.0.0:2381 :
# les trois moniteurs du chart sont donc SCRUTABLES. kube-proxy reste hors-jeu (soit
# absent car remplacé par Cilium, soit métriques en loopback uniquement).
KPS_SCRAPE_CONTROL_PLANE=true

# --- Authentification OIDC du serveur d'API (dex/) ----------------------------
# Le kube-apiserver est un POD STATIQUE : son manifeste est un fichier sur le disque de
# chaque control plane, régénéré par `kubeadm` depuis la ConfigMap `kubeadm-config`. Il
# n'existe donc aucune API pour le modifier — il faut une session sur chaque node.
APISERVER_OIDC_PATCH="apiserver-oidc.kubeadm.yaml"
APISERVER_OIDC_MECANISME="ConfigMap kubeadm-config + kubeadm init phase, sur chaque control plane"
# $1 = chemin du fragment à fusionner. Écrit sur stdout les commandes à lancer : ce dépôt
# n'exécute PAS ces commandes, elles redémarrent le serveur d'API (cf. dex/README.md).
apiserver_oidc_commandes() {
  cat <<EOF
    # 1. fusionner le fragment dans la source de vérité (éditeur interactif)
    kubectl -n kube-system edit configmap kubeadm-config     # coller le bloc apiServer de ${1}

    # 2. sur CHAQUE control plane, régénérer le manifeste statique depuis cette ConfigMap
    vagrant ssh k8s-cp1 -c '
      kubectl -n kube-system get cm kubeadm-config -o jsonpath="{.data.ClusterConfiguration}" \\
        | sudo tee /tmp/kubeadm.yaml >/dev/null
      sudo kubeadm init phase control-plane apiserver --config /tmp/kubeadm.yaml'
    kubectl get --raw=/readyz && echo   # vérifier AVANT de passer au control plane suivant
EOF
}

# --- Vault / VSO -------------------------------------------------------------
# Montage KV-v2 de démonstration, propre au lab (les policies HCL y font référence).
VAULT_KV_MOUNT="kubeadm-lab"

# --- Divers ------------------------------------------------------------------
# metrics-server : le certificat « serving » du kubelet est auto-signé par le kubelet
# lui-même sur les deux distributions → `--kubelet-insecure-tls` dans les deux cas.
METRICS_KUBELET_INSECURE=true
