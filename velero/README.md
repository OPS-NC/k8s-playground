<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# ⛵ `velero/` — backup and restore of the cluster (objects **and** Longhorn PV data) to MinIO

> Velero writes two things into the same S3 bucket: the **Kubernetes objects** (every manifest,
> namespaced and cluster-scoped) and the **content of the persistent volumes** — Longhorn
> included — through File System Backup. A namespace deleted by mistake, PVC and data alike,
> comes back with a single `velero restore create`.

> 🌐 Unlike most add-ons here, **nothing in this directory carries the neutral domain**: Velero
> exposes no UI and reaches MinIO through the in-cluster Service. There is nothing to
> substitute, and `kubectl apply -f velero/schedule.yaml` by hand is exactly what the script
> does.

## 🎯 Purpose

Backing up a Kubernetes cluster is two problems that people keep conflating:

| What | Where it lives | How Velero takes it |
|---|---|---|
| **The objects** — Deployments, Secrets, PVC *definitions*, CRDs, ClusterRoles… | etcd | listed through the API server, written as one tarball per backup into the bucket |
| **The data** — the bytes inside a Longhorn (or `local-path`) volume | the workers' disks | **File System Backup**: the `node-agent` DaemonSet reads the volume where the kubelet already mounted it and uploads it to the **same** bucket with kopia |

Restoring only the first gives you a cluster full of empty PVCs. This component does both, and
does them in one place — the `velero` bucket of the lab's MinIO.

### The setup in one sentence

`deployNodeAgent: true` + `defaultVolumesToFsBackup: true`: every pod volume is backed up
**without any per-workload annotation**, and the object store is
`http://minio.minio-cluster.svc.cluster.local:9000`, reached through the pod network only.

### Why File System Backup rather than CSI snapshots

| | CSI snapshot | File System Backup (what we use) |
|---|---|---|
| Where the copy lands | **inside Longhorn**, on the very worker disks being protected | in **MinIO**, i.e. outside the volume being protected |
| Survives `vagrant destroy` | ❌ no | ✅ yes |
| Extra prerequisites | the external-snapshotter controller + a `VolumeSnapshotClass` — **neither is installed by this lab** | none beyond the `node-agent` DaemonSet |
| Storage classes covered | those with a CSI driver that supports snapshots | **all of them** — `longhorn`, `longhorn-r1`, `local-path` |
| Cost | instant (copy-on-write) | reads and uploads the bytes, deduplicated by kopia |

A snapshot is a *rollback* mechanism, a backup is a *copy elsewhere* mechanism. On a lab whose
whole point is that it gets destroyed and rebuilt, only the second one is worth the name.

> ℹ️ Longhorn also has its **own** S3 backup target, configured in its UI. It is a fine tool
> and it covers Longhorn volumes only — not the manifests, not `local-path`. The two coexist
> without conflict; this component deliberately covers the whole cluster instead.

### Files

| File | Purpose |
|---|---|
| `velero-up.sh` | **the install**: MinIO bucket + scoped user, namespace, credentials Secret, chart, Schedule |
| `values.yaml` | Helm values: the AWS plugin init container, the `BackupStorageLocation`, FSB defaults, `node-agent` |
| `schedule.yaml` | `Schedule daily-full` — whole cluster, 02:00, TTL 7 days |

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| A **MinIO** in the cluster — `../minio-s3/cluster/` preferred, `../minio-s3/` accepted | the object store. `velero-up.sh` picks `minio-cluster` first, falls back to `minio-s3`, and `VELERO_MINIO_NS=…` overrides both | `kubectl -n minio-cluster get svc minio` |
| Namespace `velero` with PodSecurity `privileged` | the `node-agent` mounts the kubelet's pod directory (hostPath), which `baseline` forbids — **applied by `velero-up.sh`** | `kubectl get ns velero --show-labels` |
| `helm`, `curl`, `openssl` in `PATH` | the chart, the `mc` download, the generated access key | `helm version` |
| `mc` (MinIO client) | creates the bucket and the scoped user — **downloaded automatically** if missing | `mc --version` |
| `velero` CLI — **optional** | everything here is plain CRDs, but a restore without the CLI is painful | `velero version --client-only` |
| A **storage** add-on, if you want volume data to back up | with no PVC in the cluster, Velero backs up objects only — which is not a failure, just an empty half | `kubectl get pvc -A` |

> ℹ️ **No LoadBalancer IP, no Gateway, no DNS record.** Velero talks to
> `minio.<ns>.svc.cluster.local:9000`, a ClusterIP: this add-on behaves identically whether the
> LoadBalancer IPs of the lab come from Cilium's L2 announcer or from [`../metallb/`](../metallb/README.md),
> and it keeps working when neither is installed.

## ⚡ Install

> 🎓 **Two paths, same result**: the all-in-one script below, or the **"Guided walkthrough"**
> section further down — the same commands, one at a time, for training.

Through the repository entry point:
```bash
./install.sh <distro> velero       # <distro> = talos | kubeadm
```

Pinned versions: chart **Velero 12.1.0** (app **v1.18.1**), plugin
**`velero/velero-plugin-for-aws:v1.14.2`**.

```bash
./velero/velero-up.sh <distro>
```

Idempotent: `helm upgrade --install` + `kubectl apply`, and the MinIO user **keeps its existing
access key** (re-minting it on every run would silently 403 every upload).

| Variable | Default | Effect |
|---|---|---|
| `VELERO_VERSION` | `12.1.0` | chart version |
| `VELERO_AWS_PLUGIN_VERSION` | `v1.14.2` | object store plugin — must match the Velero minor (v1.14.x ↔ v1.18.x) |
| `VELERO_MINIO_NS` | detected | which MinIO to target (`minio-cluster`, then `minio-s3`) |
| `VELERO_BUCKET` | `velero` | bucket name — created if absent |
| `VELERO_S3_USER` | `velero` | MinIO user, scoped to that bucket alone |
| `VELERO_NS` | `velero` | Velero's own namespace |

## 🧬 Talos vs kubeadm

**No divergence in the install**: the same 4 steps, the same chart, the same values on both
labs. The single line that would break on Talos if it were left implicit is carried by a
profile variable, `VELERO_POD_VOLUME_PATH`.

| | Talos | kubeadm |
|---|---|---|
| `node-agent` hostPath | `/var/lib/kubelet/pods` — works **because** the kubelet root dir sits under `/var`, the only writable filesystem (`/` and `/usr` are read-only) | `/var/lib/kubelet/pods` — the upstream path on an ordinary filesystem, nothing special about it |
| `privileged` PodSecurity label on `velero` | **required**: `baseline` is enforced cluster-wide and forbids hostPath volumes. Without the label the DaemonSet exists and creates **no pod** — silently | documents the need; enforces nothing today |
| Host tooling | `kubectl`, `helm`, `curl`, `openssl` (`mc` auto-downloaded) | identical — **no `talosctl`**, Velero never touches the node configuration |
| Script steps | **4** | **4** |
| What ends up in the backup | identical: the objects, plus every pod volume that is mounted | identical |

Why a variable for a value that is the same on both sides: it turns "the chart default happens
to work on Talos" into a **checked fact**. An installer image that moved the kubelet root
(`--root-dir`) would need exactly one line changed, in `lib/profiles/talos.sh`, and not a single
`if` in this component — the rule this repository applies to every divergence
(see [`../README.md`](../README.md#-what-actually-differs-between-the-two-labs)).

## 🎓 Guided walkthrough (step by step)

> The commands below are **exactly** what `velero-up.sh` does, in order.
> Set up your shell first (once per session):
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig      # or ../Vagrant-KubeADM/kubeconfig
> export MINIO_NS=minio-cluster                      # or minio-s3
> ```

### 1. Namespace + `privileged` PodSecurity

```bash
kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace velero \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite
```

> ⚠️ On Talos, skipping this label is the classic **silent** failure: `kubectl -n velero get ds`
> shows `DESIRED 6 / READY 0` and no pod at all. The reason is in the ReplicaSet/DaemonSet
> events, nowhere else: `violates PodSecurity "baseline": hostPath volumes`.

### 2. The bucket and a MinIO user scoped to it

Never hand a cluster-admin agent the MinIO root credentials.

```bash
ROOTPW=$(kubectl -n "$MINIO_NS" get secret minio-creds -o jsonpath='{.data.root-password}' | base64 -d)
kubectl -n "$MINIO_NS" port-forward svc/minio 19010:9000 &
mc alias set _lab http://127.0.0.1:19010 admin "$ROOTPW"

mc mb --ignore-existing _lab/velero
cat > /tmp/velero-policy.json <<'JSON'
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::velero","arn:aws:s3:::velero/*"]} ]}
JSON
mc admin policy create _lab velero-rw /tmp/velero-policy.json
SK=$(openssl rand -base64 21 | tr -d '/+=' | head -c 28)
mc admin user add _lab velero "$SK"
mc admin policy attach _lab velero-rw --user velero
kill %1                                  # the port-forward has done its job
```

### 3. The credentials Secret — one `cloud` key, an AWS credentials file

```bash
kubectl -n velero create secret generic velero-s3 \
  --from-literal=cloud="$(printf '[default]\naws_access_key_id=velero\naws_secret_access_key=%s\n' "$SK")" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 4. The chart

```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts && helm repo update vmware-tanzu
# values.yaml defaults to minio-cluster; point it at yours if it lives elsewhere:
sed "s#minio\.minio-cluster\.svc#minio.${MINIO_NS}.svc#" velero/values.yaml > /tmp/velero-values.yaml
helm upgrade --install velero vmware-tanzu/velero \
  --namespace velero \
  --version 12.1.0 \
  --values /tmp/velero-values.yaml \
  --set nodeAgent.podVolumePath=/var/lib/kubelet/pods \
  --wait --timeout 10m
kubectl -n velero rollout status deploy/velero
kubectl -n velero rollout status ds/node-agent
```

### 5. Velero's own verdict on the bucket

`helm install` succeeding proves nothing about the credentials. This does:

```bash
kubectl -n velero get backupstoragelocation default
# NAME      PHASE       LAST VALIDATED   AGE   DEFAULT
# default   Available   10s              1m    true
```

### 6. The recurring backup

```bash
kubectl apply -f velero/schedule.yaml
kubectl -n velero get schedules
```

## 🔧 What the script does

| Step | Action |
|---|---|
| `[1/4]` | namespace `velero` + the three `privileged` PodSecurity labels |
| `[2/4]` | MinIO: bucket `velero`, policy `velero-rw`, user `velero` scoped to it, then the `velero-s3` Secret |
| `[3/4]` | Helm chart with the resolved endpoint, then waits for `BackupStorageLocation: Available` |
| `[4/4]` | `kubectl apply -f schedule.yaml` |

### The Helm settings that matter

| Setting | Value | Why |
|---|---|---|
| `initContainers[0]` | `velero-plugin-for-aws:v1.14.2` | the Velero image ships **no** provider plugin; without it the server loops on `unable to locate ObjectStore plugin for aws` |
| `config.s3ForcePathStyle` | `"true"` | MinIO serves a bucket as a **path** (`minio:9000/velero`), not as a subdomain |
| `config.region` | `us-east-1` | MinIO ignores it, the AWS SDK **refuses to sign** without one |
| `deployNodeAgent` | `true` | no DaemonSet, no volume data — objects only |
| `defaultVolumesToFsBackup` | `true` | covers every pod volume with no per-workload annotation |
| `uploaderType` | `kopia` | deduplicated and compressed; restic is legacy |
| `snapshotsEnabled` | `false` | no `VolumeSnapshotLocation`: there is no snapshot controller in this lab, and an AWS-provider VSL would only produce errors |
| `defaultBackupTTL` | `168h` | 7 days — every byte lands on the workers' shared disk |

### The objects Velero creates

| Kind | Role |
|---|---|
| `BackupStorageLocation` | the bucket + its health (`Available` / `Unavailable`) |
| `Schedule` | a `Backup` factory — one object per tick |
| `Backup` / `Restore` | one run each; the tarball lives in the bucket, the object in etcd |
| `PodVolumeBackup` / `PodVolumeRestore` | **one per volume**: this is where FSB progress and failures show up |
| `BackupRepository` | the kopia repository, one per (namespace, storage location) |

## ✅ Verify

```bash
kubectl -n velero get backupstoragelocation default        # PHASE=Available
kubectl -n velero get pods                                 # velero + one node-agent PER NODE
kubectl -n velero get schedules                            # daily-full

# The real proof: a backup that completes, with its volumes
velero backup create smoke --wait
velero backup describe smoke --details | sed -n '/Phase/p;/Item/p'
kubectl -n velero get podvolumebackups                     # one line per mounted volume, Completed
```

Without the CLI, the same thing with `kubectl` only:

```bash
kubectl -n velero create -f - <<'EOF'
apiVersion: velero.io/v1
kind: Backup
metadata: { name: smoke, namespace: velero }
spec: { defaultVolumesToFsBackup: true, ttl: 168h }
EOF
kubectl -n velero get backup smoke -o jsonpath='{.status.phase}{"\n"}'    # Completed
```

And the objects really landed in MinIO:

```bash
kubectl -n minio-cluster port-forward svc/minio 19010:9000 &
mc ls -r _lab/velero/backups/smoke/
kill %1
```

## 🧪 Scenario — delete a namespace with its Longhorn data, and get it back

The demo that justifies the component. It needs a storage class
([`../longhorn/`](../longhorn/README.md); `local-path` works too).

```bash
# 1. An application with a volume, and a byte we can recognise
kubectl create namespace demo-backup
kubectl apply -n demo-backup -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: data }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources: { requests: { storage: 1Gi } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: writer }
spec:
  replicas: 1
  selector: { matchLabels: { app: writer } }
  template:
    metadata: { labels: { app: writer } }
    spec:
      containers:
        - name: sh
          image: busybox:1.37
          command: ["sh", "-c", "sleep infinity"]
          volumeMounts: [{ name: data, mountPath: /data }]
      volumes:
        - { name: data, persistentVolumeClaim: { claimName: data } }
EOF
kubectl -n demo-backup rollout status deploy/writer
kubectl -n demo-backup exec deploy/writer -- sh -c 'echo "precious" > /data/proof.txt'

# 2. Back it up — the PVC definition AND the bytes
velero backup create demo-backup-1 --include-namespaces demo-backup --wait
kubectl -n velero get podvolumebackups           # one Completed line for the `data` volume

# 3. The disaster
kubectl delete namespace demo-backup
kubectl get pvc -n demo-backup                   # gone, volume included

# 4. The restore
velero restore create --from-backup demo-backup-1 --wait
kubectl -n demo-backup rollout status deploy/writer
kubectl -n demo-backup exec deploy/writer -- cat /data/proof.txt      # precious

# 5. Clean up
kubectl delete namespace demo-backup
```

> ℹ️ Step 4 is where FSB shows itself: Velero recreates the PVC, then the `node-agent` injects
> a `restore-wait` init container into the pod, which blocks startup until the data has been
> written back. A pod stuck in `Init:0/1` for a while is normal — watch
> `kubectl -n velero get podvolumerestores`.

## 🚑 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `BackupStorageLocation` `Unavailable` | wrong credentials, bucket missing, MinIO down | `kubectl -n velero logs deploy/velero \| tail -30`; re-run `velero-up.sh` (it fixes the bucket, the policy and the Secret) |
| Server logs `unable to locate ObjectStore plugin for aws` | the init container never ran (values overridden, `initContainers` emptied) | `kubectl -n velero get deploy velero -o jsonpath='{.spec.template.spec.initContainers[*].image}'` |
| `node-agent` `DESIRED n / READY 0`, **no pod** | the namespace is not labelled `privileged` (Talos) | `kubectl label ns velero pod-security.kubernetes.io/enforce=privileged --overwrite` |
| Backup `PartiallyFailed`, a `PodVolumeBackup` in `Failed` | a volume the agent cannot read (hostPath, unmounted volume) | `kubectl -n velero get podvolumebackups -o wide`, then the pod's own logs |
| Everything 403s after a re-install of MinIO | MinIO lost the `velero` user, the Secret still holds the old key | delete the Secret and re-run: `kubectl -n velero delete secret velero-s3 && ./velero/velero-up.sh <distro>` |
| Upload fails on a checksum/signature error | some S3 implementations reject the SDK's default checksum | add `checksumAlgorithm: ""` to the `config:` block of `values.yaml` ([plugin README](https://github.com/vmware-tanzu/velero-plugin-for-aws#compatibility)) |
| `velero: command not found` | the CLI is optional and not installed | use the `kubectl` forms above, or install it (see References) |

## ⚠️ Pitfalls

- **FSB only backs up a volume that a pod is mounting.** A PVC bound to nothing — or bound to a
  pod that is scaled to zero — has its *definition* backed up and its *content* skipped, with
  no error. Scale the workload up before backing up data you care about, and check
  `kubectl -n velero get podvolumebackups` rather than trusting `Phase: Completed` on the
  Backup alone.
- **`hostPath` volumes are never backed up by FSB** (by design). In this lab that mostly means
  the system DaemonSets, which is fine — but do not expect `local-path` *node* directories to
  come back through anything other than their PVC.
- **`defaultVolumesToFsBackup: true` also picks up `emptyDir`s.** Prometheus' WAL and similar
  scratch volumes will be uploaded. Opt a pod out volume by volume:
  ```bash
  kubectl -n <ns> annotate pod <pod> backup.velero.io/backup-volumes-excludes=cache,tmp
  ```
- **Do not count on Velero to restore MinIO itself.** The backup of the `minio-cluster`
  namespace lives *in* `minio-cluster`: if MinIO is gone, so is the backup. MinIO's own
  resilience is its erasure coding, not this component.
- **A restored `LoadBalancer` Service does not necessarily get the same IP.** The announcer
  (Cilium L2 or MetalLB) re-allocates from the pool. If a DNS record points at `.200`, check
  where the Gateway landed after a full-cluster restore.
- **A full-cluster restore includes the `velero` namespace** unless you exclude it. Into a
  fresh cluster, use `velero restore create --from-backup <b> --exclude-namespaces velero`,
  otherwise the restore fights the Velero that is running it.
- **The `Schedule` cron is read in the server's timezone** (UTC in this lab), not your
  workstation's. `0 2 * * *` is 13:00 in Nouméa.
- **`velero backup delete` removes the objects from the bucket too**; `kubectl delete backup`
  removes only the Kubernetes object and leaves the tarball orphaned in MinIO.
- **TTL is 7 days.** A lab left off for a fortnight comes back with an empty bucket — the GC
  runs on Velero's clock, not on how much you needed that backup.

## 🧹 Uninstall

```bash
kubectl delete -f velero/schedule.yaml
helm uninstall velero -n velero
kubectl delete namespace velero          # also drops the CRs; the CRDs survive
kubectl get crd | sed -n '/velero.io/p' | awk '{print $1}' | xargs -r kubectl delete crd
# The bucket is NOT deleted: mc rb --force _lab/velero
```

## 📚 References

- [Velero — File System Backup](https://velero.io/docs/v1.18/file-system-backup/) — what FSB does and does not cover
- [Velero — Backup reference](https://velero.io/docs/v1.18/backup-reference/) · [Restore reference](https://velero.io/docs/v1.18/restore-reference/)
- [Velero — Install the CLI](https://velero.io/docs/v1.18/basic-install/#install-the-cli)
- [velero-plugin-for-aws](https://github.com/vmware-tanzu/velero-plugin-for-aws) — the version matrix and the S3-compatible provider notes
- [`../minio-s3/cluster/README.md`](../minio-s3/cluster/README.md) — the backup target
- [`../longhorn/README.md`](../longhorn/README.md) — the volumes whose data ends up in the bucket
