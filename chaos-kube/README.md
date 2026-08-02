<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🐒 `chaos-kube/` — chaos engineering (chaoskube 0.39)

> Deletes **one random pod per hour**, everywhere except `kube-system`,
> `longhorn-system`, `vault` and `cnpg-demo`. The point is not to break things: it is to prove that what the lab runs
> comes back **on its own**. Anything that does not come back was never really highly
> available.

## 🎯 Purpose

[chaoskube](https://github.com/linki/chaoskube) picks a pod at random on every tick and
deletes it. That single behaviour answers questions no amount of `kubectl get` will:

| Question | What a kill reveals |
|---|---|
| Is this workload actually managed? | a bare pod (no Deployment/StatefulSet) **never comes back** |
| Does the app tolerate losing a replica? | single-replica Deployments = visible downtime |
| Do the PVCs re-attach? | a `longhorn` RWO volume has to follow the pod to its new node |
| Is HA real or on paper? | `../vault-cluster/` survives losing 1 pod — but comes back **sealed**, which is why it is excluded |

Files in this directory:

| File | Purpose |
|---|---|
| `chaoskube-up.sh` | the install: chart, flags, and it prints back the flags actually live in the pod |
| `values.yaml` | Helm values: `interval: 1h`, the namespace exclusions, `no-dry-run` |

## 📋 Prerequisites

The lightest addon of the lab — no storage, no Gateway, no certificate.

| Prerequisite | Why | Verify |
|---|---|---|
| Cluster `Ready`, `KUBECONFIG` set | the script probes `/readyz` | `kubectl get nodes` |
| `helm` in `PATH` | install goes through the upstream chart | `helm version` |
| Something worth killing | on an empty cluster chaoskube has nothing to prove | `kubectl get deploy -A` |

> ℹ️ The chart creates its own `ServiceAccount` + `ClusterRole` (`pods: list, delete` and
> `events: create`, cluster-wide). Broad by nature — that **is** the tool's job.

## ⚡ Install

Through the repository entry point:
```bash
./install.sh <distro> chaos     # <distro> = talos | kubeadm
```

Pinned versions: chart **0.6.0**, app **v0.39.0**.

```bash
./chaos-kube/chaoskube-up.sh <distro>
```

Idempotent (`helm upgrade --install`), re-runnable. Two knobs:

```bash
CHAOS_DRY_RUN=1 ./chaos-kube/chaoskube-up.sh <distro>   # observe only, deletes nothing
CHAOSKUBE_VERSION=0.6.0 ./…                          # pin another chart version
```

The script ends by reading the flags **back out of the Deployment** rather than echoing
`values.yaml`: that is the only proof the exclusions and `--no-dry-run` actually landed in the
pod.

## 🧬 Talos vs kubeadm

**No distribution-specific behaviour for this component**: same charts, same manifests, same
values on both labs. The distribution argument only drives two things here: the **default
domain** (`talos.lab.example.io` / `kubeadm.lab.example.io`) and **where the lab's `lab.env`
/ `kubeconfig` live** (`../Vagrant-Talos/` or `../Vagrant-KubeADM/`).

> ⚠️ One consequence to keep in mind, identical on both labs: **every Vault pod that gets killed
> comes back SEALED**. After chaoskube hits the `vault` namespace, run
> `./vault-cluster/vault-up.sh <distro>` to unseal again. That is why `values.yaml` already
> excludes `vault` and `cnpg-demo`.

## 🎓 Guided walkthrough (step by step)

> The commands below are **exactly** what the all-in-one script does, in order.
> Set up your shell first (once per session):
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig        # or ../Vagrant-KubeADM/kubeconfig
> export LAB_DOMAIN=talos.lab.example.io               # or your own (see the lab's lab.env)
> ```

### 1. First, read what will be excluded

```bash
grep -A3 'namespaces' chaos-kube/values.yaml     # kube-system, longhorn-system, vault, cnpg-demo…
```

### 2. First run in **observation-only** mode (strongly recommended)

Removing `no-dry-run` makes chaoskube announce its victims in the logs without deleting
anything.

```bash
helm repo add chaoskube https://linki.github.io/chaoskube/ && helm repo update chaoskube
sed '/^ *no-dry-run:/d' chaos-kube/values.yaml > /tmp/chaos-dry.yaml
helm upgrade --install chaoskube chaoskube/chaoskube -n chaos-kube --create-namespace \
  --version 0.6.0 --values /tmp/chaos-dry.yaml --wait --timeout 5m
kubectl -n chaos-kube logs -f deploy/chaoskube      # "would kill pod …"
```

### 3. Switch to the real thing

```bash
helm upgrade --install chaoskube chaoskube/chaoskube -n chaos-kube --create-namespace \
  --version 0.6.0 --values chaos-kube/values.yaml --wait --timeout 5m
kubectl -n chaos-kube rollout status deploy/chaoskube --timeout=180s
```

### 4. Read the flags that are **actually active** (not the ones you think you set)

```bash
kubectl -n chaos-kube get deploy chaoskube \
  -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}'
```

### 5. Watch the victims

```bash
kubectl get events -A --field-selector reason=Killing --sort-by=.lastTimestamp | tail
kubectl -n chaos-kube logs -f deploy/chaoskube
```

### 6. Pause / uninstall

```bash
kubectl -n chaos-kube scale deploy/chaoskube --replicas=0     # pause, without uninstalling
helm -n chaos-kube uninstall chaoskube                        # uninstall
```

## 🔧 Under the hood

The whole configuration is four flags, from `values.yaml`:

```
--interval=1h
--namespaces=!kube-system,!longhorn-system,!vault,!cnpg-demo
--no-dry-run
--timezone=Pacific/Noumea
```

### The exclusion syntax

`--namespaces` takes a selector-like list where `!ns` means *exclude*, comma-separated. The four
exclusions of this lab are not arbitrary:

- **`kube-system`** — with a single control plane, killing `kube-apiserver`, `etcd`, `coredns`
  or the Cilium agent takes down the *cluster*, not an application. There is no HA to test
  there.
- **`longhorn-system`** — the CSI carries the volumes of everything else. Killing an
  `instance-manager` yanks volumes that are still mounted elsewhere; the damage lands on
  innocent bystanders instead of the pod under test.
- **`vault`** — Raft survives losing a pod, but the pod comes back **sealed** and this lab has
  no auto-unseal. After a few hours all 3 are sealed and Vault is down: that stops being a
  resilience test and becomes a chore (`../vault-cluster/vault-up.sh`, every time).
- **`cnpg-demo`** — the demo Postgres cluster (`Cluster/pg-demo`, see
  `../cloudnative-pg/cluster-demo.yaml`). Note this is the **cluster's** namespace, not the
  operator's: `cnpg-system` stays fair game, since killing the operator interrupts no data path.

Everything else is a target, including `envoy-gateway-system` — since #62 the data plane runs
2 replicas, so a kill there costs nothing (the controller restarts, the other envoy keeps
serving).

### Dry-run is the upstream default

chaoskube ships **dry-run on**: without `--no-dry-run` it logs `would kill …` forever and
deletes nothing. `values.yaml` therefore carries `no-dry-run: ""` — an empty value, because the
chart renders `--<key>` for any key whose value is empty.

Going back to dry-run means **removing that key**, not setting it to `false`: the chart template
emits `--<key>` for any falsy value, so `--set chaoskube.args.no-dry-run=null` leaves the flag in
place (verified with `helm template`), and `--no-dry-run=false` is not a chaoskube flag. That is
why `CHAOS_DRY_RUN=1` renders the values into a temporary file with the line stripped.

## ✅ Verify

```bash
# dryRun=false is the line that matters — dryRun=true means it is only talking
kubectl -n chaos-kube logs deploy/chaoskube | head -5

# the parsed filters, as chaoskube understood them (not as you wrote them)
kubectl -n chaos-kube logs deploy/chaoskube | grep 'setting pod filter'

# the body count, most recent last
kubectl get events -A --field-selector reason=Killing --sort-by=.lastTimestamp
```

Expected on startup: `dryRun=false interval=1h0m0s`, then
`namespaces="!cnpg-demo,!kube-system,!longhorn-system,!vault"` — chaoskube sorts them, so the
order will not match `values.yaml` — then a first `terminating pod`: it kills once at startup,
then every hour.

## 🌐 Access

**No UI, no `HTTPRoute`, no domain**: chaoskube is a control loop, it exposes nothing. It is
observed through its logs and the `Killing` Events it writes on its victims.

| Interface | Command |
|---|---|
| Live log | `kubectl -n chaos-kube logs -f deploy/chaoskube` |
| Victims | `kubectl get events -A --field-selector reason=Killing --sort-by=.lastTimestamp` |

Pause it without uninstalling — the fastest way to stop the bleeding during a debug session:

```bash
kubectl -n chaos-kube scale deploy/chaoskube --replicas=0
```

## ⚠️ Pitfalls

- **Un-excluding `vault` seals it.** It is excluded by default for that reason: Vault survives
  losing a pod (Raft, 3 replicas), but the restarted pod is sealed and stays `0/1` — no
  auto-unseal here. Drop `!vault` from the list and within a few hours all three are sealed and
  Vault is down; recovering means re-running `../vault-cluster/vault-up.sh` after every kill.
- **Excluding a namespace that does not exist is silently fine.** `cnpg-demo` is only there once
  `../cloudnative-pg/` is installed; chaoskube just filters on a name and never complains. So
  the exclusion can be pre-loaded before the addon exists — which is exactly the case here.
- **Dry-run is the upstream default** — the #1 way to believe chaos is running when nothing is
  being deleted. Check `dryRun=false` in the logs, not the manifest.
- **A bare pod never comes back.** chaoskube deletes pods, it does not care what owns them.
  Anything created with a plain `kubectl run` / a `Pod` manifest is gone for good — which is
  precisely the finding, not a bug.
- **chaoskube can kill itself**: its own namespace is not excluded. The Deployment recreates it,
  but the hourly timer restarts from zero, so a self-kill silently skips a round.
- **Single control plane**: `kube-system` is excluded for that reason. Do **not** remove that
  exclusion on this topology (`CONTROL_PLANES=1` in `lab.env`) — there is no second API server
  to take over.
- **`minimum-age` is not set**, so a pod that has just started is a valid target, including one
  in the middle of a rollout. Set `minimum-age: "1h"` in `values.yaml` to only ever hit
  workloads that have settled.
- **The timezone is `Pacific/Noumea`**, matching the lab's `LAB_DOMAIN` (`*.ops.nc`). It only
  affects log timestamps as long as no `excluded-weekdays` / `excluded-times-of-day` is set —
  add either of those and the timezone becomes load-bearing.

## 📚 References

- [chaoskube — flags](https://github.com/linki/chaoskube#flags)
- [chaoskube — Helm chart](https://github.com/linki/chaoskube/tree/master/chart)
- [`../vault-cluster/README.md`](../vault-cluster/README.md) — the unsealing that chaos forces
- [`../node-problem-detector/README.md`](../node-problem-detector/README.md) — the other side of
  the coin: detecting node-level trouble instead of causing it
