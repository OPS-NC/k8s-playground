<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# ☸️ k8s-playground — the Kubernetes layer for the Talos **and** kubeadm labs

> **One repository of manifests and charts for two Vagrant labs.** The application layer
> (CNI, Gateway API, storage, secrets, observability, security) used to be **duplicated**, in
> `Vagrant-Talos/_k8s/` and again in `Vagrant-KubeADM/_k8s/`. It now lives here **once** — and
> both labs mount *this* repository at that very same `_k8s/` path, as a **git submodule**.
> Mounted that way, the lab **and** its distribution are found on their own — no argument, no
> environment variable, no `lab.env` here:
>
> ```bash
> ./_k8s/platform-up.sh                # from either lab's root      (submodule layout)
> ./_k8s/install.sh platform           # same thing, via the entry point
> ./install.sh kubeadm platform        # from this repo's root       (sibling layout)
> ```

📖 **Browsable documentation**: <https://ops-nc.github.io/k8s-playground/> — a single
self-contained page, bilingual (EN/FR) with a dark/light theme, rebuilt from these very
`README.md` / `LISEZ-MOI.md` files on every push to `main` (`make docs` to build it locally).

Both labs remain responsible for **bootstrapping the cluster** (VMs, OS, `kubeadm init` /
`talosctl bootstrap`). This repository only covers what comes **after**, with `kubectl` and
`helm` from the host — **including the CNI**, because neither bootstrap leaves a usable pod
network behind.

## ⚡ Quick start

You never start here: you start **in a lab**, which is where the cluster and its state live.
This repository is mounted there as the `_k8s/` submodule.

```bash
# 1. The lab — its submodule included (Talos twin: OPS-NC/Vagrant-Talos)
git clone --recurse-submodules https://github.com/OPS-NC/Vagrant-kubeadm.git
cd Vagrant-kubeadm
cp lab.env.example lab.env               # the LAB's model: topology, domain, TLS mode, CNI
vagrant up && ./kubeadm/cluster-up.sh    # nodes are NotReady: no CNI yet

# 2. Lay down the base platform — nothing to declare
./_k8s/platform-up.sh                # CNI → Envoy Gateway → metrics-server → wildcard TLS

# 3. Add-ons, opt-in
./_k8s/install.sh longhorn vault argocd
./_k8s/install.sh list               # the full catalogue
./_k8s/install.sh all                # platform + every add-on, in dependency order
```

> 💡 **Nothing to declare, and that is the whole point.** From the lab root, this repository is
> `<lab>/_k8s`: the lab is its **parent**, recognised by its `Vagrantfile`, and the
> distribution is read off that lab's own structure — `kubeadm/cluster-up.sh` here,
> `talos/cluster-up.sh` in the Talos twin. `LAB_DIR` is no longer needed, and neither is the
> `talos`/`kubeadm` argument. `KUBECONFIG` is derived the same way (`<lab>/kubeconfig`); export
> it yourself only for **your own** `kubectl` calls, not for the scripts.

Passing the distribution explicitly still works, and still wins — useful to be sure of what you
are running, or in the sibling layout below:

```bash
./_k8s/install.sh kubeadm platform
```

<details>
<summary>Variant — the two repositories side by side (the pre-submodule layout, still supported)</summary>

```bash
cd ../Vagrant-Talos    && ./talos/cluster-up.sh        # or
cd ../Vagrant-KubeADM  && ./kubeadm/cluster-up.sh

cd ../k8s-playground                 # this repo, sibling of the lab
./install.sh talos platform          # here the distribution IS worth passing (see below)
```

Here the lab repository sits one level up, **next to** this one — not above it — so the
parent-`Vagrantfile` rule does not fire and the lab is only found through `LAB_REPO_NAME`
(`../Vagrant-Talos`, `../Vagrant-KubeADM`), which the **distribution profile** supplies. The
distribution therefore has to come from somewhere else than the lab: pass it as the argument.
That is the **only** difference between the two layouts.
</details>

Every component is still **runnable on its own**, bare in the submodule layout:

```bash
./_k8s/longhorn/longhorn-up.sh               # from the lab root    (submodule layout)
./observability/observability-up.sh talos    # from this repo root  (sibling layout)
```

> 🎓 **Training mode.** Every directory ships a `README.md` (EN) / `LISEZ-MOI.md` (FR) with a
> **"Guided walkthrough"** section: the same installation, **command by command**, with what to
> observe at each step and the per-distribution variants. The all-in-one script and the
> walkthrough do exactly the same thing.

## 🧩 Two layouts: submodule or sibling repositories

Both labs mount this repository as a **git submodule** on `_k8s/`, at their root. That is the
**normal** layout, the one every lab command assumes. Keeping the two repositories **side by
side** — what existed before — still works, and stays documented here as the variant.

| | **Submodule** (recommended) | **Sibling repositories** (variant) |
|---|---|---|
| On disk | `Vagrant-KubeADM/_k8s/` **is** this repo | `Vagrant-KubeADM/` and `k8s-playground/` in the same parent directory |
| Where you run the scripts | from the **lab** root: `./_k8s/install.sh …` | from **this** repo's root: `./install.sh <distro> …` |
| `LAB_DIR` | **not needed**: the parent carries a `Vagrantfile` ⇒ rule 2 below | **not needed** either: rule 3 below finds `../<lab repo>` on its own |
| Distribution argument | **not needed**: read off the lab's structure | **worth passing**: no lab is located before the profile is loaded, so only the last-resort signal is left |
| Version of the application layer | **pinned** by the lab to one commit ⇒ the lab is reproducible | whatever happens to be checked out next door |
| Getting it | `git clone --recurse-submodules …`, or `git submodule update --init --recursive` | one `git clone` per repository |
| Updating it | `git submodule update --remote _k8s`, then commit the moved pointer | `git pull` here |
| Naming constraint | none: `_k8s/` is imposed by the labs, and both use it | the lab directory **must** be named exactly `Vagrant-Talos` / `Vagrant-KubeADM` (`LAB_REPO_NAME`), otherwise `LAB_DIR` again |

Installing and updating the submodule, from the lab:

```bash
git clone --recurse-submodules https://github.com/OPS-NC/Vagrant-kubeadm.git
git submodule update --init --recursive   # fills _k8s/ on a clone already made
git submodule update --remote _k8s        # moves _k8s/ onto the latest commit of this repo
```

> ⚠️ **`git pull` in the lab does NOT update the submodule.** It moves the lab repository
> only; `_k8s/` stays on the commit pinned before, and you would be running the documented
> commands against an **older** application layer. Follow every pull with
> `git submodule update --init --recursive`. And an empty `_k8s/` — `./_k8s/install.sh: No
> such file or directory` — always means one single thing: the submodule was never
> initialised.

> 💡 **Changing this layer is a change made *here*.** Seen from a lab, `_k8s/` is a checkout
> of this repository on a **detached HEAD**: files edited in it belong to this repo, not to
> the lab, and a `git commit` run inside `_k8s/` commits **here**. The route is therefore: PR
> on this repository → merge → in the lab, `git submodule update --remote _k8s`, then commit
> the bumped pointer (`git status` shows `modified: _k8s (new commits)`). That commit **is**
> the application layer's version bump, and it is what keeps a lab reproducible.

## 📍 Where `lab.env` and `_out/` are found

The scripts store **nothing**. `lab.env` (the intent: domain, TLS mode, CNI, VM sizes) and
`_out/` (the facts: `talosconfig`, `cluster.env`, the local CA in `_out/self-signed/`,
`_out/vault-init.json`…) live in the **lab** repository, with the `kubeconfig` right beside
them at its root. There is exactly **one** source of truth for the topology, and it is the
lab's — which is why this repository ships no `lab.env` and no model for one.
`_resoudre_lab_dir()`, in `lib/common.sh`, looks for that directory in this order:

| # | Candidate | Applies when |
|---|---|---|
| 1 | `$LAB_DIR`, failing that the directory holding `$LAB_ENV` | either one is exported — explicit override, **always wins** |
| 2 | the **parent** directory of this repo, if it holds a `Vagrantfile` | **submodule layout**: this repo *is* `<lab>/_k8s`, so the lab is simply one level up |
| 3 | `<root of this repo>/../$LAB_REPO_NAME` — `Vagrant-Talos` or `Vagrant-KubeADM`, set by the distribution profile | that directory exists ⇒ **sibling layout** (only once the profile is loaded) |
| 4 | the root of **this** repository | a `lab.env` file or an `_out/` directory sits here (a symlink counts) — standalone use |
| 5 | fallback: the root of this repository | nothing above matched |

`KUBECONFIG` follows the same directory: unless it is already exported, it becomes
`<lab dir>/kubeconfig`.

> ℹ️ **Why the test is `Vagrantfile`, and why it comes before rule 4.** A `Vagrantfile` is the
> one unambiguous mark of a lab: it is there **from the clone**, before any `vagrant up`, and
> it never appears above this repo in the sibling layout — where the parent is just some
> working directory. Ordering it **before** the "root of this repo" rule is deliberate: a
> leftover `_out/` (or a `lab.env` dropped here for a one-off test) must never shadow the real
> lab sitting right above. Explicit `LAB_DIR`/`LAB_ENV` stays above everything, because an
> override that can be outvoted is not an override.

> ⚠️ **This is exactly the failure the parent rule removes.** Before it, the submodule layout
> resolved `<root>/../Vagrant-KubeADM` to `Vagrant-KubeADM/Vagrant-KubeADM` — a path that does
> not exist — and fell through to *this repository itself*, which carries neither `lab.env` nor
> `_out/`. Nothing failed loudly: the scripts ran on the **profile defaults** —
> `<distro>.lab.example.io` instead of your `LAB_DOMAIN` (hence a wildcard TLS Secret under a
> name no add-on would look for), `CNI=cilium` instead of the CNI you picked, guessed
> `POD_CIDR` / `HOSTONLY_IF` / `KUBE_PROXY_REPLACEMENT` instead of the ones `cluster-up.sh`
> detected, and a `KUBECONFIG` pointing at a file that does not exist. If you ever see that
> shape of symptom again, it is a **resolution** problem: read the summary line first.

> 💡 **One signal does fire, on kubeadm only.** `platform-up.sh` warns when
> `_out/cluster.env` is missing — *"`./kubeadm/cluster-up.sh` has not been run (or not to the
> end)"*. Two readings: either the bootstrap really did not finish, or the lab was not the one
> resolved. The warning is **non-blocking**, and on Talos there is no equivalent (that lab has
> no `cluster.env`).

Every script prints its resolution before touching anything — one line, worth reading:

```
    profil kubeadm (Debian 13 + kubeadm) · domaine *.kubeadm.lab.example.io · lab.env absent (défauts)
```

`lab.env absent (défauts)` on a lab that *does* have a `lab.env`, or a `domaine` that is not
the one you set: the resolution missed the lab — force it with `LAB_DIR`.

Overriding it all by hand stays possible — useful for a lab kept somewhere else entirely, or
to exercise this repository in isolation:

```bash
LAB_DIR=~/labs/my-lab   ./install.sh talos platform      # lab.env + _out/ + kubeconfig, all there
LAB_ENV=~/labs/my-lab/lab.env  ./install.sh talos platform   # its directory becomes the lab dir
LAB_ENV=~/labs/my-lab/lab.env  KUBECONFIG=~/labs/my-lab/kubeconfig  ./install.sh talos platform
```

> ⚠️ **Do not create a `lab.env` at this repo's root.** Rule 4 accepts one, and it is there for
> exercising this repo without any lab — but a second `lab.env` is a second truth, drifting
> from the lab's the moment either changes. That is precisely why there is **no
> `lab.env.example` here**: the model to copy lives in the lab.

## 🎯 How the distribution is selected

In priority order:

| # | Source | Example |
|---|---|---|
| 1 | first positional argument | `./install.sh talos longhorn` · `./longhorn/longhorn-up.sh talos` |
| 2 | `--distro=` | `./platform-up.sh --distro=kubeadm` |
| 3 | environment variable | `K8S_DISTRO=talos ./install.sh longhorn` |
| 4 | `DISTRO=` in the lab's `lab.env` | `DISTRO=kubeadm` |
| 5 | the lab's **structure** | `talos/cluster-up.sh` → `talos` · `kubeadm/cluster-up.sh` → `kubeadm` |
| 6 | the lab's **bootstrap artefacts** | `_out/talosconfig` → `talos` · `_out/cluster.env` → `kubeadm` |
| 7 | **probing** the cluster | first node's `osImage`: `Talos …` → `talos`, anything else → `kubeadm` |

Sources 5 to 7 are `_detecter_distro()`, three families of signals ordered by how early they
become available:

| Signal | Available from | Cost |
|---|---|---|
| **structure** — the bootstrap script of the distribution the lab implements | the `git clone`, **before any `vagrant up`** | none: a file test |
| **artefacts** — what the bootstrap wrote into `_out/` | after `cluster-up.sh` | none: a file test. Covers a lab whose directories were renamed |
| **probe** — `kubectl get nodes -o jsonpath=…osImage` | a cluster that is up **and** a `KUBECONFIG` that already points at it | last resort only |

> ℹ️ **Why the probe is last.** It needs a `KUBECONFIG` that is already correct — but
> `KUBECONFIG` is derived from the lab directory, which comes from the *profile*, which is
> loaded only once the distribution is known. By construction the probe is the least available
> signal at the exact moment it is needed, so it only ever answers for an ambient `kubectl`
> context. Sources 5 and 6 read the lab directly and have no such dependency.

With none of the above, the scripts **refuse to run**: applying a Talos-shaped manifest on
Debian (or the reverse) does not produce a clean error but a silent failure — a `Deployment`
that gets created while no pod ever starts, for instance.

> ℹ️ **Sources 4 to 6 need the lab to be located first — which is where layout matters.** In
> **submodule** layout the parent-`Vagrantfile` rule fires before any profile is loaded, so all
> three work bare: that is what makes `./_k8s/platform-up.sh` self-sufficient. In **sibling**
> layout the lab is only reachable through `LAB_REPO_NAME`, which the profile supplies — and
> the profile is what we are trying to choose. Resolution therefore falls through to the probe
> (source 7). From this repo's root: pass the distribution, or export `LAB_DIR`. An explicit
> argument short-circuits the whole question and stays the surest way to know what you ran.

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
install.sh                  entry point: ./install.sh [talos|kubeadm] <component...>
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
docs/build.py               builds the single-page site from every README (make docs)
Makefile                    docs, docs-check, validate — everything that runs without a cluster
```

In submodule layout, that whole tree hangs under the lab's `_k8s/` — `./_k8s/install.sh`,
`./_k8s/longhorn/longhorn-up.sh`, and so on. Nothing else moves: paths *inside* this
repository are the same either way, which is why every walkthrough is written from this
repository's root.

There is **no `Vagrantfile`, no `_out/` and no `lab.env` here**, by design: this repo owns the
manifests, the lab owns the cluster and its state. That absence is load-bearing — it is what
makes "the parent holds a `Vagrantfile`" an unambiguous way to spot the lab, and what keeps a
stray second `lab.env` from ever competing with the real one. See
[Where `lab.env` and `_out/` are found](#-where-labenv-and-_out-are-found).

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

## 🌐 `LAB_DOMAIN` — the UI domain

Alongside it, two more **neutral** markers. The repository is **public**: no manifest carries a real value. Three neutral markers are
substituted **on the fly** (the `rendre` helper in `lib/common.sh`), never rewriting a
versioned file — `git status` stays clean:

| Versioned marker | Replaced with | Comes from |
|---|---|---|
| `lab.example.io` | `$LAB_DOMAIN` (default `<distro>.lab.example.io`) | environment, then `lab.env` |
| `lab-example-io` | `$LAB_DOMAIN_DASH` — the wildcard TLS Secret name | derived from `LAB_DOMAIN` |
| `lab-kv` | `$VAULT_KV_MOUNT` (`talos-lab` / `kubeadm-lab`) | distribution profile |

`LAB_DOMAIN` is set in the **lab's** `lab.env`, never here — so from the lab root, whichever
layout you are in:

```bash
echo 'LAB_DOMAIN=k8s.my-domain.tld' >> lab.env      # in Vagrant-Talos/ or Vagrant-KubeADM/
```

> ⚠️ A domain that stays at `<distro>.lab.example.io` while `lab.env` says otherwise is the
> **first** symptom of a `lab.env` that was never found: check which lab got resolved (the
> summary line) before suspecting the substitution.

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

`./install.sh list` prints the same list, always up to date.

> ℹ️ The commands below spell out `<distro>` because they are written from **this** repo's
> root, where it is worth passing. From a lab root, drop it: `./_k8s/install.sh longhorn`.

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

## 🌍 Remote access (Tailscale + Cloudflare)

The `.200` VIP is a **host-only** IP announced over ARP: reachable from the host, not routable
as-is.

1. **L3** — the host advertises the route:
   ```bash
   sudo tailscale up --advertise-routes=192.168.56.200/32
   ```
   Then approve it in the Tailscale console.
   > ⚠️ Stay on the `/32` (or fence it with an ACL): a `/24` would also expose the Kubernetes
   > API (`:6443`) and SSH on every node.

2. **Name + TLS** — a public Cloudflare wildcard `*.<LAB_DOMAIN> → 192.168.56.200`, in
   **DNS-only (grey cloud)**: the Cloudflare proxy cannot reach a private `192.168.56.x` IP.
   TLS is therefore terminated by **Envoy**, not by Cloudflare → the Gateway must carry a
   **publicly trusted** certificate (Let's Encrypt, see [`cert-manager/`](cert-manager/README.md)).
   A *Cloudflare Origin CA* certificate would be rejected by browsers.

> 💡 With the default `SELF_SIGNED=true`, none of this is needed: an `/etc/hosts` line pointing
> at `192.168.56.200` is enough, and the domain never has to resolve publicly.

## ⚠️ Pitfalls

- **Running from *this* repo's root with no distribution argument.** In sibling layout no lab
  is located before the profile is loaded, so the only signal left is the probe on whatever
  `kubectl` context happens to be ambient — which may be another cluster entirely. Pass
  `talos`/`kubeadm`, or export `LAB_DIR`. From a **lab** root the question does not arise.
- **The lab directory renamed, in sibling layout.** Rule 3 matches on `LAB_REPO_NAME`
  literally: a `Vagrant-KubeADM-v2/` next door is not found, and resolution falls back to this
  repo — silently. `LAB_DIR` is the fix. In submodule layout the name is irrelevant.
- **Read the summary line, every time.** One line per script, printed before anything is
  touched: profile, domain, and whether a `lab.env` was found. It is the cheapest way to catch
  a resolution that went somewhere unexpected.
- **A `git pull` in a lab does not move `_k8s/`.** The submodule stays pinned to its previous
  commit: `git submodule update --init --recursive` after every pull.
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

- [OPS-NC/Vagrant-Talos](https://github.com/OPS-NC/Vagrant-Talos) — the Talos lab (from
  `vagrant up` to a ready cluster) · [browsable docs](https://ops-nc.github.io/Vagrant-Talos/)
- [OPS-NC/Vagrant-kubeadm](https://github.com/OPS-NC/Vagrant-kubeadm) — the Debian 13 + kubeadm
  lab · [browsable docs](https://ops-nc.github.io/Vagrant-kubeadm/)
- [Gateway API](https://gateway-api.sigs.k8s.io/) ·
  [Cilium](https://docs.cilium.io/) ·
  [Envoy Gateway](https://gateway.envoyproxy.io/) ·
  [cert-manager](https://cert-manager.io/docs/) ·
  [Talos Linux](https://www.talos.dev/latest/) ·
  [kubeadm](https://kubernetes.io/docs/reference/setup-tools/kubeadm/)

Both labs mount this repository as their `_k8s/` submodule; each one documents its own
bootstrap, its `lab.env` and its lifecycle. The relative paths that used to point at
`../Vagrant-Talos/` and `../Vagrant-KubeADM/` are gone: they resolved to nothing on the
published site, and to two different places depending on the layout.
