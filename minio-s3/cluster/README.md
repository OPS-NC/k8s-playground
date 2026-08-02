<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🧺 `minio-s3/cluster/` — distributed 4-node MinIO (erasure coding) on local-path

> The **resilient** variant of the standalone MinIO (`../`): a **4-pod StatefulSet**, 1 drive
> (`local-path` PVC) per pod, 1 pod per worker. MinIO **erasure-codes** objects across the 4
> drives → object storage survives node losses **without Longhorn**, exactly the way
> CloudNativePG handles Postgres replication itself.

> ⚠️ **BLOCKING prerequisite: 4 `Ready` workers.** The default shipped by both labs (their
> `lab.env.example`) is
> `WORKERS=3` → with that topology this component **cannot start at all**. See Prerequisites.

## 🎯 Purpose

This is the lab's "for real" S3: the target of the PostgreSQL backups
(`../../cloudnative-pg/pg-backup-up.sh` and `pg-app-backup-cnpg-up.sh` point at
`http://minio.minio-cluster.svc.cluster.local:9000`), and the teaching demo of erasure coding
against the standalone.

| | Standalone (`../`) | **Cluster (here)** |
|---|---|---|
| Workload | Deployment, 1 replica | **StatefulSet, 4 pods** |
| Drives | 1 (local-path 10 Gi) | **4** (1 PVC 10 Gi/pod, 1/worker) |
| Erasure coding | ❌ | ✅ **EC:2** (2 parity blocks) |
| Resilience | none (losing the node = losing the data) | **tolerates ~2 nodes/drives down** |
| Workers required | 1 | **4** |
| Namespace | `minio-s3` | `minio-cluster` (they coexist) |

Exposure (HTTPS via `main-gateway`, wildcard `*.lab.example.io`):

| Service | URL | Port |
|---|---|---|
| **S3 API** | `https://minio-cluster.lab.example.io` | 9000 |
| **Admin console** | `https://minio-cluster-console.lab.example.io` | 9001 |

Inside the cluster: `http://minio.minio-cluster.svc.cluster.local:9000`.

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| **≥ 4 `Ready` workers** | `replicas: 4` + **`requiredDuringScheduling`** anti-affinity on `kubernetes.io/hostname` (max 1 pod per node); control planes are tainted `NoSchedule` so they **do not count** | `kubectl get nodes -l '!node-role.kubernetes.io/control-plane'` |
| StorageClass **`local-path`** (`../../local-path-storage/`) | the 4 PVCs of the `volumeClaimTemplates`; the script bails out without it | `kubectl get storageclass local-path` |
| `main-gateway` + `https` listener + wildcard cert | both `HTTPRoute`s | `kubectl get gateway -n envoy-gateway-system` |
| DNS `minio-cluster` + `minio-cluster-console` → `192.168.56.200` | to reach the Envoy VIP | `getent hosts minio-cluster.lab.example.io` |

> ⚠️ **Set `WORKERS=4` (or more) in `lab.env` before building the cluster.**
> The lab's `lab.env.example` ships `WORKERS=3`, and `minio-cluster-up.sh` only **warns** (a plain
> `echo`, not an `exit`) when there are fewer than 4 workers. It applies the manifest anyway:
> the 4th pod stays **`Pending` forever** (strict anti-affinity, no eligible node left), so the
> `rollout status --timeout=300s` **fails after 5 minutes** and the deployment starts at best
> **degraded from day one** (3 drives out of 4, zero margin: one more failure and the erasure set
> loses its write quorum). Changing `WORKERS` requires a `vagrant destroy` and a cluster rebuild
> (see `CLAUDE.md`): decide **beforehand**.

## ⚡ Install

Through the repository entry point:
```bash
./install.sh <distro> minio-cluster     # <distro> = talos | kubeadm
```

```bash
./minio-s3/cluster/minio-cluster-up.sh <distro>
# Tunable credentials: MINIO_ROOT_USER (default "admin") / MINIO_ROOT_PASSWORD (generated)
```

Image pinned in `minio-cluster.yaml`:
**`docker.io/pgsty/minio:RELEASE.2026-06-18T00-00-00Z`** (Pigsty fork — recent + admin console,
see `../README.md`).

## 🧬 Talos vs kubeadm

**No distribution-specific behaviour for this component**: same charts, same manifests, same
values on both labs. The distribution argument only drives two things here: the **default
domain** (`talos.lab.example.io` / `kubeadm.lab.example.io`) and **where the lab's `lab.env`
/ `kubeconfig` live** (`../Vagrant-Talos/` or `../Vagrant-KubeADM/`).

> ℹ️ A **topology** constraint, not a distribution one: anti-affinity pins 1 pod per node, so
> **4 `Ready` workers** are required (otherwise pods stay `Pending`).

## 🎓 Guided walkthrough (step by step)

> The commands below are **exactly** what the all-in-one script does, in order.
> Set up your shell first (once per session):
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig        # or ../Vagrant-KubeADM/kubeconfig
> export LAB_DOMAIN=talos.lab.example.io               # or your own (see the lab's lab.env)
> ```

### 1. Check the prerequisites (storage + worker count)

```bash
kubectl get sc local-path
kubectl get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers | grep -c ' Ready '   # ≥ 4
```

### 2. Namespace + credentials Secret

```bash
kubectl create namespace minio-cluster --dry-run=client -o yaml | kubectl apply -f -
kubectl -n minio-cluster get secret minio-creds >/dev/null 2>&1 || \
kubectl -n minio-cluster create secret generic minio-creds \
  --from-literal=root-user=admin \
  --from-literal=root-password="$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)"
```

### 3. 4-node StatefulSet + Services + HTTPRoutes

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" minio-s3/cluster/minio-cluster.yaml | kubectl apply -f -
kubectl -n minio-cluster rollout status statefulset/minio --timeout=300s
kubectl -n minio-cluster get pods -o wide      # one pod per node
```

### 4. Verify erasure coding

```bash
mc alias set labc "https://minio-cluster.${LAB_DOMAIN}" <user> <pass> --insecure
mc admin info labc --insecure        # 4 drives online, tolerates ~2 nodes down
```

### 5. Exercise fault tolerance (optional, spectacular)

```bash
kubectl -n minio-cluster delete pod minio-0     # the StatefulSet recreates it
mc admin info labc --insecure                   # the service stays available
```

## 🔧 What the script does

1. Checks `kubectl`, the apiserver, the `local-path` StorageClass, then **counts the `Ready`
   workers** and warns if there are fewer than 4 (without blocking).
2. Creates the `minio-cluster` namespace and the `minio-creds` Secret — **not overwritten** if
   it exists.
3. Applies `minio-cluster.yaml` (headless Service, StatefulSet, ClusterIP Service, 2 `HTTPRoute`s).
4. Waits for `rollout status statefulset/minio --timeout=300s`, then prints the URLs **and the
   root credentials in clear text** (see Pitfalls).

### Why 4 nodes (and not 3)

MinIO requires a **minimum of 4 drives** per *erasure set*, spread **evenly** across the nodes.
With **1 drive per pod** (the clean K8s pattern on local-path):

- **3 nodes × 1 drive = 3 drives** → below the minimum **and** not even → rejected.
- **4 nodes × 1 drive = 4 drives** → 1 erasure set of 4, **EC:2** → the natural minimum.
- 3 nodes only becomes possible again with **≥ 2 drives/node** (3 × 2 = 6 drives = 1 set of 6),
  i.e. 2 PVCs per pod: more complex, not chosen here.

> ℹ️ EC:2 over 4 drives = 2 data + 2 parity. You can **lose up to 2 drives/nodes** and still
> **read**; writing requires a quorum (≥ half the drives + 1).

### Deployed topology

```
StatefulSet minio (podManagementPolicy: Parallel — the 4 pods boot TOGETHER and wait for each other)
  minio-0 @ worker A ─ PVC data-minio-0 (local-path 10Gi)  ┐
  minio-1 @ worker B ─ PVC data-minio-1                    ├─ 1 pool, 1 erasure set of 4, EC:2
  minio-2 @ worker C ─ PVC data-minio-2                    │
  minio-3 @ worker D ─ PVC data-minio-3                    ┘
  ▲ peer discovery via the HEADLESS Service minio-hl:
     server http://minio-{0...3}.minio-hl.minio-cluster.svc.cluster.local:9000/data
Service minio (ClusterIP) ── balances across the 4 pods ── HTTPRoutes (API + console)
```

Key points of the manifest:

- **`podManagementPolicy: Parallel`** (mandatory): with `OrderedReady`, `minio-0` would never be
  "ready" without its peers → deadlock. In parallel, all 4 boot and form the quorum.
- **Headless Service `minio-hl`** (`clusterIP: None`, `publishNotReadyAddresses: true`): stable
  per-pod DNS, resolved **before** the pods are ready.
- **`hostname` anti-affinity (`required…`)**: 1 pod/worker → erasure spread over 4 distinct nodes.
- **`startupProbe` `failureThreshold: 30` × 5 s**: up to 150 s to form the quorum at boot.

## ✅ Verify

```bash
kubectl -n minio-cluster get pods -o wide            # minio-0..3, 1/1, on 4 distinct workers
mc alias set clu https://minio-cluster.lab.example.io <user> <pass> --insecure
mc admin info clu                                    # "4 drives online, 0 offline", EC:2
```

## 🌐 Access

| What | How |
|---|---|
| Admin console | `https://minio-cluster-console.lab.example.io` |
| S3 API | `https://minio-cluster.lab.example.io` (path-style) |
| Root user | `kubectl -n minio-cluster get secret minio-creds -o jsonpath='{.data.root-user}' \| base64 -d; echo` |
| Root password | `kubectl -n minio-cluster get secret minio-creds -o jsonpath='{.data.root-password}' \| base64 -d; echo` |

Let's Encrypt **staging** cert → `--insecure` for `mc`, and a warning to accept in the browser.

## 🧪 Scenarios

**Test the resilience** — delete a pod: the cluster stays readable/writable.

```bash
kubectl -n minio-cluster delete pod minio-2
mc admin info clu       # 3/4 online, still operational; the pod comes back and resyncs
```

**Migrate from the standalone** — both MinIOs coexist (distinct namespaces and hostnames):

```bash
mc alias set std https://minio.lab.example.io <user> <pass> --insecure
mc alias set clu https://minio-cluster.lab.example.io <user> <pass> --insecure
mc mb clu/pg-backups clu/cnpg-backups
mc mirror --preserve std/pg-backups clu/pg-backups
mc mirror --preserve std/cnpg-backups clu/cnpg-backups
```

Then repoint the backup jobs (`MINIO_ENDPOINT` / `endpointURL`) at
`http://minio.minio-cluster.svc.cluster.local:9000` — already the case for the scripts in
`../../cloudnative-pg/` — and decommission the standalone.

## ⚠️ Pitfalls

- **Fewer than 4 workers = an install that never converges**: the 4th pod stays `Pending`
  (`required…` anti-affinity), `rollout status` fails after 5 min, and the erasure set runs at
  3/4 drives right from the start. The script does **not** fail at that point (just an `echo`
  warning, `minio-cluster-up.sh`): do not read its quiet start as proof the topology is right.
- **`minio-cluster-up.sh` prints the root user and password in clear text on stdout.**
  Read them back from the Secret instead (Access table).
- **The 4 × 10 Gi are not quotas.** `local-path` = a hostPath directory, the PVC size is **never**
  enforced. The allocatable `ephemeral-storage` measured here is **~16.9 GB per node** (20 GB disk
  shared with the OS and the images): filling the buckets causes `DiskPressure` and pod
  **eviction** on the affected workers — hence potentially the simultaneous loss of several MinIO
  drives. Watch it:
  ```bash
  kubectl get nodes -o custom-columns=NAME:.metadata.name,EPH:.status.allocatable.ephemeral-storage
  kubectl describe node <worker> | grep -i pressure
  ```
- **Node-local drives**: losing a worker = losing a drive. EC:2 absorbs 2 losses, no more; a
  `vagrant destroy` absorbs 4 (and the data with them).
- **Scaling**: MinIO grows by **adding server pools** (≥ 4 drives per pool), never by adding a
  lone drive. To grow, declare a 2nd pool in the args
  (`… /data http://minio2-{0...3}…/data`).
- **Performance**: 1 drive/pod on a node-local disk shared with the OS — fine for a lab, not for
  real load.
- **Console behind a separate hostname**: `MINIO_BROWSER_REDIRECT_URL` carries
  `https://minio-cluster-console.lab.example.io` in the manifest — the **neutral** domain of
  the public repo, substituted by `minio-cluster-up.sh` from `LAB_DOMAIN` (`lab.env`) along with
  the `HTTPRoute` hostnames. A direct `kubectl apply` keeps the example domain and breaks the
  login redirects. See [`../../README.md`](../../README.md#-lab_domain--the-ui-domain).

## 📚 References

- `../README.md` — standalone MinIO, and the details of **why the `pgsty/minio` fork**.
- `../../local-path-storage/` — the StorageClass consumed by the 4 drives.
- `../../cloudnative-pg/` — the PostgreSQL backups that target this cluster.
- [MinIO documentation (Kubernetes)](https://min.io/docs/minio/kubernetes/upstream/) — distributed
  deployment, erasure coding and quorum.
