<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# ☸️ k8s-playground — the Kubernetes layer for the Talos **and** kubeadm labs

> **One repository of manifests and charts for two Vagrant labs.** The application layer
> (CNI, Gateway API, storage, secrets, observability, security) used to be duplicated in
> `Vagrant-Talos/_k8s/` and `Vagrant-KubeADM/_k8s/`. It now lives here **once**, and the
> target distribution became an **argument**:
>
> ```bash
> ./install.sh talos platform          # on the Talos cluster
> ./install.sh kubeadm platform        # on the kubeadm/Debian 13 cluster
> ```

Both labs remain responsible for **bootstrapping the cluster** (VMs, OS, `kubeadm init` /
`talosctl bootstrap`). This repository only covers what comes **after**, with `kubectl` and
`helm` from the host — **including the CNI**, because neither bootstrap leaves a usable pod
network behind.

## ⚡ Quick start

```bash
# 1. Bring up the cluster from the matching lab (sibling repository)
cd ../Vagrant-Talos    && ./talos/cluster-up.sh        # or
cd ../Vagrant-KubeADM  && ./kubeadm/cluster-up.sh

# 2. Come back here and lay down the base platform
cd ../k8s-playground
./install.sh talos platform          # CNI → Envoy Gateway → metrics-server → wildcard TLS

# 3. Add-ons, opt-in
./install.sh talos longhorn vault argocd
./install.sh talos list              # the full catalogue
./install.sh talos all               # platform + every add-on, in dependency order
```

Every component is still **runnable on its own**, with the distribution as its argument:

```bash
./longhorn/longhorn-up.sh talos
./observability/observability-up.sh kubeadm
```

> 🎓 **Training mode.** Every directory ships a `README.md` (EN) / `LISEZ-MOI.md` (FR) with a
> **"Guided walkthrough"** section: the same installation, **command by command**, with what to
> observe at each step and the per-distribution variants. The all-in-one script and the
> walkthrough do exactly the same thing.

## 🎯 How the distribution is selected

In priority order:

| # | Source | Example |
|---|---|---|
| 1 | first positional argument | `./install.sh talos longhorn` · `./longhorn/longhorn-up.sh talos` |
| 2 | `--distro=` | `./platform-up.sh --distro=kubeadm` |
| 3 | environment variable | `K8S_DISTRO=talos ./install.sh longhorn` |
| 4 | `DISTRO=` in the lab's `lab.env` | `DISTRO=kubeadm` |
| 5 | **detection** on the cluster | first node's `osImage`: `Talos …` → `talos`, anything else → `kubeadm` |

With none of the above, the scripts **refuse to run**: applying a Talos-shaped manifest on
Debian (or the reverse) does not produce a clean error but a silent failure — a `Deployment`
that gets created while no pod ever starts, for instance.

## 🧬 What actually differs between the two labs

Everything is concentrated in **`lib/profiles/talos.sh`** and **`lib/profiles/kubeadm.sh`**:
the install scripts never test the distribution through scattered `if`s, they read variables.

| Topic | Talos Linux | Debian 13 + kubeadm | Profile variable |
|---|---|---|---|
| **Default UI domain** | `talos.lab.example.io` | `kubeadm.lab.example.io` | `DEFAULT_LAB_DOMAIN` |
| **PodSecurity (cluster level)** | `baseline` **enforced** → a privileged pod needs a namespace labelled `privileged`, otherwise it fails **silently** | no level enforced → the same labels unblock nothing, they document intent | `PODSECURITY_DEFAUT` |
| **Filesystem** | immutable: `/` and `/usr` read-only, only `/var` is writable | ordinary, everything is writable | — |
| **local-path-provisioner** | `/var/local-path-provisioner` | `/opt/local-path-provisioner` (upstream path) | `LOCAL_PATH_DIR` |
| **iSCSI prerequisite (Longhorn)** | an **extension** (`iscsi-tools`) baked into the installer image (not fixable at runtime) + `rshared` kubelet mount via `talosctl patch mc` | a **package** (`open-iscsi`) installed by `provision.sh`; `/var/lib/longhorn` is an ordinary directory | `LONGHORN_PREP_REQUISE` |
| **kube-proxy** | always installed by the bootstrap, not replaceable here | **optional**: replaceable by Cilium in eBPF (`KUBE_PROXY_REPLACEMENT=true`, the lab default) | `KUBE_PROXY_REPLACEABLE` |
| **Cilium — IPAM** | `ipam.mode=kubernetes` (podCIDRs come from kube-controller-manager) | `ipam.mode=cluster-pool` (the Cilium operator carves the pod CIDR) | `CILIUM_IPAM_MODE` |
| **Cilium — OS values** | `cgroup.autoMount=false` + `cgroup.hostRoot` + explicit capabilities (**required**) | none: the chart defaults are the right ones, forcing them would be **harmful** | `cilium_sets_specifiques()` |
| **Calico** | `flexVolumePath: None` and CSI `None` **mandatory** (`/usr` is read-only) | same settings, but purely as a slim-down | (shared manifest) |
| **flannel (`CNI=flannel`)** | already installed by the Talos bootstrap → nothing to do | installed here via the `flannel/flannel` chart | `FLANNEL_PRE_INSTALLED` |
| **Trivy — "node" scanners** | **disabled**: the `node-collector` bind-mounts `/etc/systemd` → `read-only file system` | enabled: those paths exist and are readable | `TRIVY_NODE_COLLECTOR` |
| **Prometheus — control plane** | etcd/scheduler/controller-manager monitors **off** (not scrapable without dedicated TLS) | **on**: `bind-address: 0.0.0.0` and `listen-metrics-urls` set at bootstrap | `KPS_SCRAPE_CONTROL_PLANE` |
| **Host-only interface** | `enp0s8` | `eth1` or `enp0s8` depending on the box → **detected** into `_out/cluster.env` | `DEFAULT_HOSTONLY_IF` |
| **Cluster facts** | `_out/controlplane.yaml` (`podSubnets`) | `_out/cluster.env` (CIDR, interface, kube-proxy) | — |
| **Demo Vault KV mount** | `talos-lab/` | `kubeadm-lab/` | `VAULT_KV_MOUNT` |
| **Self-signed CA** | `O=Vagrant-Talos lab` | `O=Vagrant-KubeADM lab` | `CA_ORG`, `CA_FILE_NAME` |

Everything else — Argo CD, Kyverno, MinIO, CloudNativePG, Vault, Envoy Gateway, cert-manager,
chaoskube, node-problem-detector, WordPress — is **strictly identical** on both distributions.

## 🗂️ Repository layout

```
install.sh                  entry point: ./install.sh <talos|kubeadm> <component...>
platform-up.sh              the base platform (CNI → Gateway → metrics → TLS)
metric-server.yaml          metrics-server (applied by platform-up.sh)
lib/
  common.sh                 shared core: distro resolution, lab.env reading, helpers
  profiles/talos.sh         EVERYTHING specific to Talos
  profiles/kubeadm.sh       EVERYTHING specific to kubeadm/Debian
<component>/
  <component>-up.sh         the all-in-one install
  values.yaml / *.yaml      manifests and values (NEUTRAL values, substituted on the fly)
  README.md / LISEZ-MOI.md  EN/FR docs + guided walkthrough
```

The scripts store **nothing**: `lab.env` and `_out/` (kubeconfig, talosconfig, generated
secrets) stay in the lab repository. They are located automatically (`../Vagrant-Talos/` or
`../Vagrant-KubeADM/`, depending on the distribution), and that is overridable:

```bash
LAB_ENV=~/labs/my-lab/lab.env  KUBECONFIG=~/labs/my-lab/kubeconfig  ./install.sh talos platform
```

## 🔗 Dependency chain

Every link assumes the previous one: no LoadBalancer IP without an L2 announcer, no HTTPS
without the Gateway, no UI without a certificate on the `:443` listener.

```
bootstrapped cluster  (Talos lab or kubeadm lab — nodes NotReady, no CNI yet)
   │
   ├─ 1. CNI              cilium/ (default, + L2 pool → LoadBalancer IP .200)
   │                      or calico/ (CNI only) or flannel (CNI only) or nothing
   ├─ 2. envoy-gateway/   Envoy controller + main-gateway (listeners :80 and :443)
   ├─ 3. metric-server    metrics.k8s.io API  (kubectl top, HPA)
   └─ 4. wildcard TLS     *.<LAB_DOMAIN> — two modes, per SELF_SIGNED
              │             true (default) → self-signed/   openssl, local CA
              │             false          → cert-manager/  Let's Encrypt DNS-01 Cloudflare
              │
              └─ add-ons: storage → databases → secrets → observability → security
```

That is exactly the order of `platform-up.sh` (`[1/4]` → `[4/4]`). Both TLS modes fill the
**same** Secret (`wildcard-<LAB_DOMAIN with dashes>-tls`), so no add-on ever has to know which
one you picked.

## 🌐 The domain, and the three "neutral" values

The repository is **public**: no manifest carries a real value. Three neutral markers are
substituted **on the fly** (the `rendre` helper in `lib/common.sh`), never rewriting a
versioned file — `git status` stays clean:

| Versioned marker | Replaced with | Comes from |
|---|---|---|
| `lab.example.io` | `$LAB_DOMAIN` (default `<distro>.lab.example.io`) | environment, then `lab.env` |
| `lab-example-io` | `$LAB_DOMAIN_DASH` — the wildcard TLS Secret name | derived from `LAB_DOMAIN` |
| `lab-kv` | `$VAULT_KV_MOUNT` (`talos-lab` / `kubeadm-lab`) | distribution profile |

```bash
echo 'LAB_DOMAIN=k8s.my-domain.tld' >> ../Vagrant-Talos/lab.env
```

> ⚠️ **Manifests applied by hand** (without a `*-up.sh`) get no substitution:
> `wordpress-example/wordpress-mariadb.yaml`, `vault-secret-operator/k8s/*.yaml`,
> `cert-manager/04-gateway-https-example.yaml`. Pipe them through the same `sed`:
> ```bash
> sed 's/lab\.example\.io/k8s.my-domain.tld/g' <file> | kubectl apply -f -
> ```

## 📦 Pinned versions

Audited on **1 August 2026**: everything is on the latest stable release published at that
date (`helm search repo <chart> --versions`). Every version is overridable by environment
variable.

| Component | Chart / image | Version | Where | Variable |
|---|---|---|---|---|
| Cilium | `cilium/cilium` | `1.20.0` | `cilium/cilium-up.sh` | `CILIUM_VERSION` |
| Calico | `projectcalico/tigera-operator` | `v3.32.1` | `calico/calico-up.sh` | `CALICO_VERSION` |
| Envoy Gateway | `oci://docker.io/envoyproxy/gateway-helm` | `1.8.3` | `platform-up.sh` | `ENVOY_GW_VERSION` |
| cert-manager | `jetstack/cert-manager` | `v1.21.1` | `platform-up.sh` | `CERT_MANAGER_VERSION` |
| metrics-server | image `registry.k8s.io/…` | `v0.9.0` | `metric-server.yaml` | — |
| Longhorn | `longhorn/longhorn` | `1.12.0` | `longhorn/longhorn-up.sh` | `LONGHORN_VERSION` |
| local-path-provisioner | image `rancher/…` | `v0.0.36` | `local-path-storage/local-path-storage.yaml` | — |
| CloudNativePG | `cnpg/cloudnative-pg` | `0.29.0` (app 1.30.0) | `cloudnative-pg/cloudnative-pg-up.sh` | `CNPG_VERSION` |
| Vault | `hashicorp/vault` | `0.34.0` | `vault-cluster/vault-up.sh` | `VAULT_CHART_VERSION` |
| Vault Secrets Operator | `hashicorp/vault-secrets-operator` | `1.5.0` | `vault-secret-operator/` (docs) | — |
| kube-prometheus-stack | `prometheus-community/…` | `88.0.1` (op. v0.93.0) | `observability/observability-up.sh` | `KPS_VERSION` |
| Loki | `grafana/loki` | `7.2.0` (app 3.6.11) | idem | `LOKI_VERSION` |
| Alloy | `grafana/alloy` | `1.11.0` (app v1.18.0) | idem | `ALLOY_VERSION` |
| node-problem-detector | `deliveryhero/…` | `2.3.14` (app v0.8.19) | `node-problem-detector/…-up.sh` | `NPD_VERSION` |
| Kyverno | `kyverno/kyverno` | `3.8.2` (app v1.18.2) | `kyverno/kyverno-up.sh` | `KYVERNO_VERSION` |
| Policy Reporter | `policy-reporter/policy-reporter` | `3.9.1` | `kyverno/`, `trivy-operator/` | `POLICY_REPORTER_VERSION` |
| Trivy Operator | `aqua/trivy-operator` | `0.34.0` (app 0.32.0) | `trivy-operator/…-up.sh` | `TRIVY_OPERATOR_VERSION` |
| Argo CD | `argo/argo-cd` | `10.2.2` (app v3.4.6) | `argocd/argocd-up.sh` | `ARGOCD_VERSION` |
| chaoskube | `chaoskube/chaoskube` | `0.6.0` (app 0.39.0) | `chaos-kube/chaoskube-up.sh` | `CHAOSKUBE_VERSION` |
| flannel | `flannel/flannel` | not pinned (latest: `v0.28.8`) | `platform-up.sh` | `FLANNEL_VERSION` |

> ℹ️ **Demo** images (WordPress, MariaDB, nginx, alpine, busybox, PostgreSQL, MinIO) are pinned
> on purpose and are not part of this audit: bumping them only matters when a demo breaks.

## 🗺️ The catalogue

`./install.sh <distro> list` prints the same list, always up to date.

### 🌐 Networking & TLS

| Directory | Purpose | Command |
|---|---|---|
| [`cilium/`](cilium/README.md) | **default CNI** + LoadBalancer IP pool + L2 announcement (ARP) | `./install.sh <distro> cilium` |
| [`calico/`](calico/README.md) | **alternative CNI** (Tigera operator) — CNI **only**, no L2 announcement | `./install.sh <distro> calico` |
| [`envoy-gateway/`](envoy-gateway/README.md) | Envoy controller + `main-gateway` (`:80`/`:443`) + demo apps | via `platform` |
| [`self-signed/`](self-signed/README.md) | **default TLS mode** — wildcard signed by a local CA | via `platform` |
| [`cert-manager/`](cert-manager/README.md) | automatic wildcard TLS (ACME DNS-01 Cloudflare) | via `platform` when `SELF_SIGNED=false` |

### 💾 Storage

| Directory | Purpose | Command | StorageClass |
|---|---|---|---|
| [`longhorn/`](longhorn/README.md) | replicated block storage (iSCSI prerequisite **differs per distro**) | `./install.sh <distro> longhorn` | `longhorn`, `longhorn-r1` |
| [`local-path-storage/`](local-path-storage/README.md) | dynamic local storage (hostPath; **path differs per distro**) | `./install.sh <distro> local-path` | `local-path` |
| [`minio-s3/`](minio-s3/README.md) | S3 object storage + console, **1 node** | `./install.sh <distro> minio` | — |
| [`minio-s3/cluster/`](minio-s3/cluster/README.md) | **distributed** MinIO, 4 nodes (EC:2) — the backup target | `./install.sh <distro> minio-cluster` | — |

### 🐘 Databases

| Directory | Purpose | Command | Prerequisites |
|---|---|---|---|
| [`cloudnative-pg/`](cloudnative-pg/README.md) | PostgreSQL HA operator + 3-node cluster, automatic failover, **S3 backups + PITR** | `./install.sh <distro> cnpg` | SC `longhorn-r1` |

### 🔐 Secrets

| Directory | Purpose | Command | Prerequisites |
|---|---|---|---|
| [`vault-cluster/`](vault-cluster/README.md) | Vault HA (Raft), 3 nodes, HTTPS UI/API | `./install.sh <distro> vault` | SC `longhorn` |
| [`vault-secret-operator/`](vault-secret-operator/README.md) | Vault secrets → native K8s `Secret`s (static KV, dynamic DB, PKI) | Helm + `vault/*.sh` | unsealed Vault |

### 📈 Observability

| Directory | Purpose | Command | Prerequisites |
|---|---|---|---|
| [`observability/`](observability/README.md) | Prometheus + Grafana + Alertmanager + Loki + Alloy | `./install.sh <distro> observability` | SC `longhorn-r1`, CP ≥ 4 GB |
| [`node-problem-detector/`](node-problem-detector/README.md) | node health (kernel) | `./install.sh <distro> npd` | — |
| [`chaos-kube/`](chaos-kube/README.md) | chaos: deletes **1 random pod per hour** | `./install.sh <distro> chaos` | — |

### 🛡️ Security

| Directory | Purpose | Command | Prerequisites |
|---|---|---|---|
| [`kyverno/`](kyverno/README.md) | policy engine + Policy Reporter (UI), teaching policies in Audit | `./install.sh <distro> kyverno` | `main-gateway` |
| [`trivy-operator/`](trivy-operator/README.md) | continuous scanner (CVEs, config, secrets, RBAC) | `./install.sh <distro> trivy` | `kyverno` (shared UI) |

### 🧪 Demos

| Directory | Purpose | Command |
|---|---|---|
| [`argocd/`](argocd/README.md) | Argo CD (GitOps), UI at `argo.<LAB_DOMAIN>` | `./install.sh <distro> argocd` |
| [`wordpress-example/`](wordpress-example/README.md) | WordPress + MariaDB on Longhorn, exposed through Envoy | `kubectl apply` (see README) |

## ⚠️ Pitfalls

- **Two default StorageClasses.** `longhorn/values.yaml` sets `persistence.defaultClass:
  true` and `local-path-storage.yaml` sets the `is-default-class: "true"` annotation. With
  both add-ons installed ⇒ a PVC without an explicit `storageClassName` lands on the most
  recently created SC, non-deterministically. **Always name your SC.**
- **`CNI=cilium` is the only "everything on" choice.** This layer needs a `LoadBalancer`
  Service that really gets an IP, and only Cilium's L2 announcement (ARP) does that here.
  With `calico`, `flannel` or `none`, the Gateway stays at `EXTERNAL-IP <pending>` and **no UI
  is reachable**.
- **Switching CNI on a live cluster is not supported**: flatten the cluster from the lab
  (`./kubeadm/cluster-reset.sh`, or `vagrant destroy`), then re-bootstrap.
- **The repo's own Kyverno policies are violated by the repo** (`require-requests-limits`
  demands a `limits.cpu` the in-house manifests deliberately never set). The report is noisy
  by construction — see [`kyverno/`](kyverno/README.md).
- **Metric emitters are off by default** (`serviceMonitor`/`podMonitor` are `false` in
  trivy-operator, CloudNativePG and node-problem-detector): Prometheus scrapes nothing from
  them until you flip them on after installing `observability`.
- **Never lower `CP_MEM` below `3072`** in the lab's `lab.env`: stacking these add-ons on 2 GB
  control planes starves etcd. `observability` needs `4096`.

## 📚 References

- [`../Vagrant-Talos/`](../Vagrant-Talos/) — the Talos lab (from `vagrant up` to a ready cluster)
- [`../Vagrant-KubeADM/`](../Vagrant-KubeADM/) — the Debian 13 + kubeadm lab
- [Gateway API](https://gateway-api.sigs.k8s.io/) ·
  [Cilium](https://docs.cilium.io/) ·
  [Envoy Gateway](https://gateway.envoyproxy.io/) ·
  [cert-manager](https://cert-manager.io/docs/) ·
  [Talos Linux](https://www.talos.dev/latest/) ·
  [kubeadm](https://kubernetes.io/docs/reference/setup-tools/kubeadm/)
