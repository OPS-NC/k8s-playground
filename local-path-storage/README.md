<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 📁 `local-path-storage/` — dynamic local storage (no Longhorn)

> Deploys **[Rancher local-path-provisioner](https://github.com/rancher/local-path-provisioner)**
> `v0.0.36` and a **default `local-path` StorageClass**: PVs carved out of the worker's disk
> (`/opt/local-path-provisioner`). This is the lab's **"no Longhorn"** alternative — zero CSI
> driver, zero extra package on the nodes, two resources and provisioning just works.

## 🎯 Purpose

A kubeadm cluster ships **no** storage provisioner at all: `kubectl get storageclass` returns nothing and
every PVC stays `Pending`. Components that **require** a PVC (CloudNativePG does not support
`emptyDir` for PGDATA, MinIO wants a `/data`) never start at all. This provisioner fills the gap
with no external dependency.

> ⚠️ **NODE-LOCAL storage, not replicated.** A PV lives on **one single** worker. It **survives**
> a pod restart / reschedule (as long as the pod comes back on the same node), but it is **lost
> if that node dies**. No HA at the storage level: keep it for rebuildable data or for
> "knowingly ephemeral" use cases. For replicated storage, see **`../longhorn/`**.

Who uses it in this lab:

| Addon | Usage |
|---|---|
| `../minio-s3/` | 1 PVC, 10 Gi (standalone) |
| `../minio-s3/cluster/` | 4 PVCs, 10 Gi — MinIO does its own resilience (erasure coding) on top |

> ℹ️ `../cloudnative-pg/` has **no** local-path variant: `cluster-demo.yaml` mandates
> `storageClass: longhorn-r1` and `cloudnative-pg-up.sh` bails out if that StorageClass is
> missing. A "3 PostgreSQL nodes on local-path" variant is an **unimplemented idea**.
> Same for `../databasement/`, which stays on `emptyDir` (`values.yaml`).

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| Cluster with a working CNI (`./kubeadm/cluster-up.sh` or `./talos/cluster-up.sh`, then `./platform-up.sh <distro>`) | the provisioner is a plain Deployment | `kubectl get nodes` |
| ≥ 1 schedulable worker | each PV lands on the node of the **first consuming pod** (`WaitForFirstConsumer`) | `kubectl get nodes -l '!node-role.kubernetes.io/control-plane'` |
| Free space on the worker's root filesystem | PVs are hostPath directories under `/opt`, not sized volumes | `vagrant ssh k8s-w1 -c 'df -h /opt'` |

## ⚡ Install

Through the repository entry point:
```bash
./install.sh <distro> local-path     # <distro> = talos | kubeadm
```

```bash
./local-path-storage/local-path-up.sh <distro>
```

Idempotent (`kubectl apply` + `rollout status`). Manual equivalent:
`kubectl apply -f local-path-storage/local-path-storage.yaml`.

## 🧬 Talos vs kubeadm

One difference only, but a **blocking** one if ignored: the **provisioning path**
(`LOCAL_PATH_DIR` in the profiles).

| | Talos | kubeadm |
|---|---|---|
| PV path | `/var/local-path-provisioner` | `/opt/local-path-provisioner` (upstream path) |
| Why | `/` and `/etc` are READ-ONLY, only `/var` is writable: a helper pod can create NOTHING under `/opt` | `/opt` is writable, the helper pod creates it without asking |
| `privileged` PodSecurity labels | **required** (cluster default `baseline`; helper pods mount hostPath) | intent documentation |

The versioned manifest carries the upstream path; `local-path-up.sh` substitutes it on the fly
(`sed`) from the profile. Check afterwards: `kubectl -n local-path-storage get cm
local-path-config -o yaml | grep paths`.

## 🎓 Guided walkthrough (step by step)

> The commands below are **exactly** what the all-in-one script does, in order.
> Set up your shell first (once per session):
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig        # or ../Vagrant-KubeADM/kubeconfig
> export LAB_DOMAIN=talos.lab.example.io               # or your own (see the lab's lab.env)
> ```

### 1. Pick the path for your distribution

```bash
LOCAL_PATH_DIR=/var/local-path-provisioner    # Talos
# LOCAL_PATH_DIR=/opt/local-path-provisioner  # kubeadm (upstream path)
```

### 2. Apply the manifest with the path substituted

```bash
sed "s#/opt/local-path-provisioner#${LOCAL_PATH_DIR}#g" \
    local-path-storage/local-path-storage.yaml | kubectl apply -f -
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=120s
```

### 3. Check the effective config (the classic trap)

```bash
kubectl -n local-path-storage get cm local-path-config -o jsonpath='{.data.config\.json}'; echo
kubectl get sc local-path -o jsonpath='{.metadata.annotations}'; echo   # is-default-class
```

### 4. End-to-end test: a PVC must bind as soon as a pod consumes it

`volumeBindingMode: WaitForFirstConsumer` ⇒ a lone PVC stays `Pending`, which is expected.

```bash
kubectl create ns lp-test
kubectl -n lp-test apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: test }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: { requests: { storage: 128Mi } }
---
apiVersion: v1
kind: Pod
metadata: { name: writer }
spec:
  containers:
    - name: c
      image: docker.io/library/busybox
      command: ["sh","-c","echo ok > /data/hello && sleep 3600"]
      volumeMounts: [{ name: d, mountPath: /data }]
  volumes: [{ name: d, persistentVolumeClaim: { claimName: test } }]
EOF
kubectl -n lp-test wait --for=condition=Ready pod/writer --timeout=120s
kubectl -n lp-test exec writer -- cat /data/hello
kubectl get pv | grep lp-test
```

### 5. Look at the directory on the node, then clean up

```bash
# Talos   : talosctl -n <worker-ip> ls ${LOCAL_PATH_DIR}
# kubeadm : vagrant ssh k8s-w1 -c "sudo ls -l ${LOCAL_PATH_DIR}"
kubectl delete ns lp-test
```

## 🔧 Two deviations from the upstream manifest

The vendored manifest ([`local-path-storage.yaml`](./local-path-storage.yaml)) starts from
upstream `v0.0.36` and keeps its **`/opt/local-path-provisioner`** path — on Debian 13 that
directory is writable, so there is nothing to move:

| # | Change | Why |
|---|---|---|
| 1 | Namespace `local-path-storage` in **PodSecurity `privileged`** | The **helper pods** (creating/deleting the PV directories) mount **hostPath**. kubeadm enforces **nothing** at cluster level by default, so this label unblocks nothing today — it is kept because it states the intent and keeps the component working the day admission is hardened (Kyverno, a default `AdmissionConfiguration`, a managed cluster). |
| 2 | StorageClass `local-path` marked **default** (`is-default-class`) | PVCs without a `storageClassName` use it automatically. |

### Tuning

Everything is tuned in `local-path-storage.yaml`:

- **Storage path** — `ConfigMap local-path-config`, key `config.json`:
  ```json
  { "nodePathMap":[ { "node":"DEFAULT_PATH_FOR_NON_LISTED_NODES",
                      "paths":["/opt/local-path-provisioner"] } ] }
  ```
  You can map a path per node (`"node":"k8s-w1"`), for instance onto an extra disk mounted on
  that worker (`/etc/fstab` inside the VM — the nodes are plain Debian). After editing:
  `kubectl -n local-path-storage rollout restart deploy/local-path-provisioner`.
- **`reclaimPolicy: Delete`** — the PV directory is **deleted** along with the PVC. Use `Retain`
  to keep the data.
- **`volumeBindingMode: WaitForFirstConsumer`** — the PV is only provisioned when the pod is
  scheduled (storage follows the pod onto its node). Keep it.

## ✅ Verify

```bash
kubectl get storageclass                      # local-path (default)
kubectl -n local-path-storage get pods        # local-path-provisioner 1/1 Running

# Test: a PVC only binds once a pod shows up (WaitForFirstConsumer)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: lp-test, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 128Mi } }
EOF
kubectl -n default run lp-test --image=busybox:1.38 --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"lp-test"}}],"containers":[{"name":"c","image":"busybox:1.38","command":["sh","-c","echo ok>/data/x && cat /data/x && sleep 3"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}]}}'
kubectl -n default get pvc lp-test            # STATUS Bound
kubectl -n default delete pod lp-test; kubectl -n default delete pvc lp-test
```

## ⚠️ Pitfalls

- **The size requested by a PVC is NOT enforced.** A local-path PV is a plain hostPath
  directory: `requests.storage: 10Gi` is purely declarative, nothing caps the writes. A workload
  can fill the worker's `/var` partition up to `DiskPressure` (and pod eviction). Measured on
  this lab: **~16.9 GB of allocatable `ephemeral-storage` per node** for a 20 GB disk
  (`Vagrantfile`, `DISK_SIZE_MB = 20480`) — two 10 Gi PVCs "fit" side by side on paper, not in
  reality. Watch it:
  ```bash
  kubectl get nodes -o custom-columns=NAME:.metadata.name,EPH:.status.allocatable.ephemeral-storage
  kubectl describe node <worker> | grep -i pressure
  ```
- **Two default StorageClasses** if `../longhorn/` is installed alongside: `local-path` is
  annotated `is-default-class: "true"` and `longhorn/values.yaml` sets
  `persistence.defaultClass: true`. A PVC without `storageClassName` becomes **non-deterministic**.
  Drop one of the two defaults:
  ```bash
  kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class-
  ```
- **The helper pod runs `image: busybox` with no tag** (so `:latest`, see
  `local-path-storage.yaml`). That violates the `disallow-latest-tag` policy of
  `../kyverno/policies/02-disallow-latest-tag.yaml`: both of its rules (tag present, tag ≠
  `latest`) will surface a failing `PolicyReport` on `helper-pod`. The policy runs in **Audit**
  mode → nothing is blocked, but it is an expected "offender" in the Policy Reporter UI.
- **PVs stuck after uninstall**: already provisioned PVs (and their directories under
  `/opt/local-path-provisioner`) are not cleaned up while PVCs still reference them.
  Delete the consuming workloads/PVCs first.

## 🧹 Uninstall

```bash
kubectl delete -f local-path-storage/local-path-storage.yaml
```

Removes the StorageClass and the provisioner (read the last pitfall before running it).

## 📚 References

- [Rancher local-path-provisioner](https://github.com/rancher/local-path-provisioner)
- Original upstream manifest:
  <https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml>
- `../longhorn/` — the replicated / HA alternative.
