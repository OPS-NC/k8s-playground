#!/usr/bin/env bash
#
# lib/profiles/talos.sh — the "Talos Linux" profile (Vagrant-Talos repository).
#
# What this profile says, in one sentence: the OS is IMMUTABLE. `/` and `/usr` are read-only
# (only `/var` is writable), there is neither systemd nor journald, PodSecurity admission
# enforces `baseline` cluster-wide by default, and node configuration goes through `talosctl`
# (an API) — not through SSH.
#
# Concrete consequences, all carried by the variables below:
#   - a hostPath must live under /var (local-path-provisioner);
#   - a privileged pod needs a namespace labelled `privileged` (otherwise it is refused
#     SILENTLY: the Deployment exists, the ReplicaSet creates NO pod);
#   - "package" prerequisites become EXTENSIONS baked into the installer image (iscsi-tools
#     for Longhorn): they cannot be added at runtime;
#   - anything bind-mounting /etc/systemd or /lib/systemd fails (trivy node-collector);
#   - Cilium needs specific values (cgroup already mounted by Talos, explicit capabilities)
#     documented by Cilium upstream for Talos.

# shellcheck shell=bash

DISTRO_LABEL="Talos Linux (immutable OS)"
LAB_REPO_NAME="Vagrant-Talos"            # neighbouring Vagrant repository (lab.env, _out/)
DEFAULT_LAB_DOMAIN="talos.lab.example.io"
CA_ORG="Vagrant-Talos lab"               # subject of the self-signed CA (self-signed/)
CA_FILE_NAME="vagrant-talos-lab.crt"     # suggested name when importing into the trust store
CLUSTER_UP_HINT="./talos/cluster-up.sh (Vagrant-Talos repository)"
CLUSTER_RESET_HINT="vagrant destroy && vagrant up && ./talos/cluster-up.sh"

# --- Network -----------------------------------------------------------------
# Talos names the host-only interface `enp0s8` (predictable names, official box).
DEFAULT_HOSTONLY_IF="enp0s8"
# Pod CIDR: `cluster.network.podSubnets` of the machine config (Talos AND lab default).
DEFAULT_POD_CIDR="10.244.0.0/16"
# kube-proxy is OPTIONAL, exactly as on kubeadm: `KUBE_PROXY_REPLACEMENT=true` (the lab
# default) makes talos/cluster-up.sh add `talos/patch-no-kube-proxy.yaml`
# (`cluster.proxy.disabled: true`) to the generated machine config, so the Talos bootstrap
# renders NO kube-proxy manifest and Cilium serves the Services in eBPF.
# ⚠️ On Talos this value is an INTENT read from `lab.env` — there is no `_out/cluster.env`
#    here to turn it into a detected fact. It MUST match what the bootstrap actually did:
#    the ground truth is `kubectl -n kube-system get ds kube-proxy` (or `cluster.proxy` in
#    `_out/controlplane.yaml`). Same hazard as `CNI`, and the same rule — it is decided at
#    bootstrap, never switched live.
KUBE_PROXY_REPLACEABLE=true
DEFAULT_KUBE_PROXY_REPLACEMENT="true"
DEFAULT_VIP="192.168.56.5"               # apiserver VIP (see talos/patch-cp.yaml)
# flannel: with CNI=flannel, Talos ALREADY installed it at bootstrap — the platform layer has
# nothing to lay down.
FLANNEL_PRE_INSTALLED=true

# --- Cilium ------------------------------------------------------------------
# `ipam.mode=kubernetes`: Talos' kube-controller-manager carves the per-node podCIDRs; Cilium
# merely follows them.
CILIUM_IPAM_MODE="kubernetes"
# Values REQUIRED by Cilium on Talos (see the Cilium "Talos Linux" docs):
#   - cgroup.autoMount.enabled=false + hostRoot: Talos already mounts cgroup2, and the pod
#     cannot remount /sys/fs/cgroup itself (read-only filesystem);
#   - explicit capabilities: Talos refuses the chart's implicit `privileged`.
cilium_specific_sets() {
  printf '%s\n' \
    '--set' 'cgroup.autoMount.enabled=false' \
    '--set' 'cgroup.hostRoot=/sys/fs/cgroup' \
    '--set' 'securityContext.capabilities.ciliumAgent={CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}' \
    '--set' 'securityContext.capabilities.cleanCiliumState={NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}'
}

# --- Storage -----------------------------------------------------------------
# local-path-provisioner: `/opt` is not writable on Talos, only /var is → we move the
# provisioning path.
LOCAL_PATH_DIR="/var/local-path-provisioner"
# Longhorn: two prerequisites SPECIFIC TO TALOS, handled by longhorn-up.sh —
#   1. the `iscsi-tools` + `util-linux-tools` extensions baked into INSTALLER_IMAGE
#      (see longhorn/schematic.yaml): without them the CSI pods go into CrashLoopBackOff
#      (`iscsiadm: not found`) and nothing fixes that at runtime;
#   2. an `rshared` kubelet mount on /var/lib/longhorn (longhorn/patch-longhorn.yaml): the
#      Talos kubelet runs in a container with no bidirectional mount propagation.
LONGHORN_PREP_REQUIRED=true

# --- Backup (velero/) ---------------------------------------------------------
# Velero's node-agent reads the volume data where the KUBELET has already mounted it, through a
# hostPath on its pod directory. On Talos that path deserves a variable rather than the chart
# default: `/` and `/usr` are read-only, so a hostPath anywhere else would be a dead end — and
# it works only because the kubelet root dir sits under `/var`, the one writable filesystem.
# Same value as kubeadm today; the variable is what makes that a CHECKED fact instead of a
# lucky coincidence (an installer image that moved the kubelet root would only need this line).
VELERO_POD_VOLUME_PATH="/var/lib/kubelet/pods"

# --- Security / admission ----------------------------------------------------
# `baseline` enforced cluster-wide: any privileged pod (hostNetwork, hostPath, hostPID) needs
# a namespace labelled `pod-security.kubernetes.io/enforce: privileged`.
PODSECURITY_DEFAULT="baseline (enforced cluster-wide)"
# trivy-operator: the node-collector bind-mounts /etc/systemd, /lib/systemd, /etc/kubernetes.
# Talos has no systemd and / + /etc are read-only → `CreateContainerError: mkdir /etc/systemd:
# read-only file system`. We turn off the two scanners that launch it (infra assessment +
# cluster compliance); the image/config/secret/RBAC scans carry on.
TRIVY_NODE_COLLECTOR=false

# --- Observability -----------------------------------------------------------
# etcd, scheduler and controller-manager expose no scrapable metrics without dedicated TLS
# configuration on Talos → monitors disabled, to avoid unexplainable "down" targets during
# training. kube-proxy is out of the picture anyway (absent when Cilium replaced it, and
# metrics on loopback only otherwise).
KPS_SCRAPE_CONTROL_PLANE=false

# --- API-server OIDC authentication (dex/) -----------------------------------
# The machine configuration IS the API: `talosctl patch mc` is enough, Talos regenerates the
# kube-apiserver static manifest and restarts it. No SSH, no file to edit.
APISERVER_OIDC_PATCH="apiserver-oidc.talos.yaml"
APISERVER_OIDC_MECHANISM="talosctl patch mc (the machine configuration is an API)"
# $1 = path of the patch to apply. Writes the commands to run on stdout: this repository does
# NOT run them, they restart the API server (see dex/README.md).
apiserver_oidc_commands() {
  cat <<EOF
    for ip in \$(kubectl get nodes -l node-role.kubernetes.io/control-plane \\
                   -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}'); do
      talosctl -n "\$ip" patch mc --patch @${1}
      kubectl get --raw=/readyz && echo   # check BEFORE moving on to the next one
    done
EOF
}

# --- Vault / VSO -------------------------------------------------------------
VAULT_KV_MOUNT="talos-lab"

# --- Misc --------------------------------------------------------------------
METRICS_KUBELET_INSECURE=true
# talosctl config: needed by the components that talk to the Talos API (Longhorn).
TALOSCONFIG_DEFAULT="_out/talosconfig"
