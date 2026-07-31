<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🪣 `minio-s3/` — standalone MinIO (S3 + admin console) on local-path

> An **S3-compatible** endpoint inside the cluster, in a **single pod**, with a **full admin
> console** (Pigsty fork). This is the simple version: one `local-path` PVC, zero resilience.
> The resilient version lives in **[`cluster/`](./cluster/)**.

## 🎯 Purpose

Get a local S3 to test backups, SDKs, `mc`, bucket policies — with no cloud account. Two
hostnames exposed over HTTPS via `main-gateway` (wildcard `*.lab.example.io`):

| Service | URL | Container port |
|---|---|---|
| **S3 API** | `https://minio.lab.example.io` | 9000 |
| **Admin console** | `https://minio-console.lab.example.io` | 9001 |

Inside the cluster: `http://minio.minio-s3.svc.cluster.local:9000`.

### Standalone (here) or distributed ([`cluster/`](./cluster/))?

| | **Standalone (here)** | **Cluster** (`cluster/`) |
|---|---|---|
| Workload | Deployment, 1 replica | StatefulSet, **4 pods** (`podManagementPolicy: Parallel`) |
| Drives | 1 `local-path` PVC, 10 Gi | **4** `local-path` PVCs, 10 Gi (1/pod, 1/worker) |
| Erasure coding | ❌ none | ✅ **EC:2** |
| Resilience | none: the node dies ⇒ data gone | tolerates ~2 nodes/drives down |
| Workers required | 1 | **4** (strict anti-affinity) |
| Namespace | `minio-s3` | `minio-cluster` (both coexist) |
| Hostnames | `minio` / `minio-console` | `minio-cluster` / `minio-cluster-console` |

> ℹ️ **The lab backups no longer target this standalone.** Since the move to the MinIO cluster,
> `../cloudnative-pg/pg-backup-up.sh` and `pg-app-backup-cnpg-up.sh` point at
> `http://minio.minio-cluster.svc.cluster.local:9000`. This directory remains the simple sandbox
> (and the teaching component for "before/after erasure coding").

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| StorageClass **`local-path`** (`../local-path-storage/`) | the 10 Gi PVC behind `/data`; `minio-up.sh` bails out without it | `kubectl get storageclass local-path` |
| `main-gateway` + `https` listener (`../envoy-gateway/`) | carries both `HTTPRoute`s | `kubectl get gateway -n envoy-gateway-system` |
| Wildcard cert `*.lab.example.io` (`../cert-manager/`) | TLS for both hostnames | `kubectl -n envoy-gateway-system get certificate` |
| DNS `minio` + `minio-console` → `192.168.56.200` | to reach the Envoy VIP | `getent hosts minio.lab.example.io` |
| `openssl` on the host | generates the default root password | `openssl version` |

## ⚡ Install

> 🎓 **Two paths, same result**: the all-in-one script below, or the **"Guided
> walkthrough"** section further down — the same commands, one at a time, for training.

Through the repository entry point:
```bash
./install.sh <distro> minio     # <distro> = talos | kubeadm
```

```bash
./minio-s3/minio-up.sh <distro>
# Tunable credentials: MINIO_ROOT_USER (default "admin") / MINIO_ROOT_PASSWORD (generated)
MINIO_ROOT_PASSWORD='MyLabPass' ./minio-s3/minio-up.sh <distro>
```

Image pinned in `minio-s3.yaml`: **`docker.io/pgsty/minio:RELEASE.2026-06-18T00-00-00Z`**.

## 🧬 Talos vs kubeadm

**No distribution-specific behaviour for this component**: same charts, same manifests, same
values on both labs. The distribution argument only drives two things here: the **default
domain** (`talos.lab.example.io` / `kubeadm.lab.example.io`) and **where the lab's `lab.env`
/ `kubeconfig` live** (`../Vagrant-Talos/` or `../Vagrant-KubeADM/`).

> ℹ️ The only prerequisite is the `local-path` StorageClass — whose **path** does depend on the
> distribution (see [`../local-path-storage/`](../local-path-storage/README.md)).

## 🎓 Guided walkthrough (step by step)

> The commands below are **exactly** what the all-in-one script does, in order.
> Set up your shell first (once per session):
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig        # or ../Vagrant-KubeADM/kubeconfig
> export LAB_DOMAIN=talos.lab.example.io               # or your own (see the lab's lab.env)
> ```

### 1. Check the storage prerequisite

```bash
kubectl get sc local-path      # otherwise: ./install.sh <distro> local-path
```

### 2. Namespace + credentials Secret (generated once, never overwritten)

```bash
kubectl create namespace minio-s3 --dry-run=client -o yaml | kubectl apply -f -
kubectl -n minio-s3 get secret minio-creds >/dev/null 2>&1 || \
kubectl -n minio-s3 create secret generic minio-creds \
  --from-literal=root-user=admin \
  --from-literal=root-password="$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)"
```

### 3. Deployment + Service + HTTPRoutes (domain substituted)

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" minio-s3/minio-s3.yaml | kubectl apply -f -
kubectl -n minio-s3 rollout status deploy/minio --timeout=180s
```

### 4. Read the credentials back

```bash
kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-user}' | base64 -d; echo
kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-password}' | base64 -d; echo
```

### 5. Verify the S3 API and the console

```bash
kubectl -n minio-s3 get httproute
curl --resolve "minio.${LAB_DOMAIN}:443:192.168.56.200" "https://minio.${LAB_DOMAIN}/minio/health/live" -kSI | head -1
# mc client (from the host):
mc alias set lab "https://minio.${LAB_DOMAIN}" <user> <pass> --insecure
mc mb lab/demo --insecure && mc ls lab --insecure
```

## 🔧 What the script does

1. Checks `kubectl`, the apiserver and the presence of the `local-path` StorageClass.
2. Creates the `minio-s3` namespace and the `minio-creds` Secret (`root-user` / `root-password`) —
   **never overwritten** if it exists: re-running the script does not change the password.
3. Applies `minio-s3.yaml`: 10 Gi PVC, Deployment (`strategy: Recreate`, since the RWO volume
   cannot take two pods), ClusterIP Service, two `HTTPRoute`s.
4. Waits for the `rollout` (180 s) then prints the URLs **and the root credentials in clear text
   on stdout** (see Pitfalls).

### Why the Pigsty fork (`pgsty/minio`)

Neither the "official" image nor Bitnami:

- **Bitnami** (`bitnami/minio`) has relied since **August 2025** on **frozen** images
  (`bitnamilegacy/*`, no longer updated).
- **Upstream `minio/minio`** **gutted the community console** around
  `RELEASE.2025-05-24` (only an object browser is left: no more user / bucket / policy /
  lifecycle management from the web), then the repo was **archived as
  "no longer maintained"** (Feb 2026).
- **Pigsty** rebuilds the MinIO server **and restores the full admin console** → a **recent** AND
  **manageable** image. It is the most active fork (see the "MinIO is Dead, Long Live MinIO"
  post).

Other options: upstream pinned at `RELEASE.2025-04-22T22-12-26Z` (the last release with the
official admin console, but frozen), other console forks (`huncrys/minio-console`,
`georgmangold/console`), the paid **AIStor** edition, or simply the **`mc`** CLI.

## ✅ Verify

```bash
kubectl -n minio-s3 get pods,pvc,svc,httproute
curl -sk -o /dev/null -w '%{http_code}\n' --resolve minio.lab.example.io:443:192.168.56.200 \
  https://minio.lab.example.io/minio/health/ready      # 200
```

## 🌐 Access

| What | How |
|---|---|
| Admin console | `https://minio-console.lab.example.io` |
| S3 API | `https://minio.lab.example.io` (path-style, any `region`: `us-east-1`) |
| Root user | `kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-user}' \| base64 -d; echo` |
| Root password | `kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-password}' \| base64 -d; echo` |

The wildcard cert is issued by Let's Encrypt **staging** → a TLS warning to accept in the
browser, and `--insecure` for `mc` (see `../cert-manager/`).

```bash
mc alias set lab https://minio.lab.example.io <user> <pass> --insecure
mc mb lab/my-bucket --insecure                        # create a bucket
mc admin user add lab bob <password> --insecure       # manage users
mc ls lab --insecure
```

## ⚠️ Pitfalls

- **`minio-up.sh` prints the root user AND password in clear text on stdout** (end of the run).
  That ends up in your shell history, CI logs, a screenshot… Prefer reading them back from the
  Secret (table above), and remember to scrub the output if you share it.
- **No resilience at all.** A 1-replica Deployment + 1 `local-path` PVC = **node-local** storage.
  If the worker hosting the PV dies, the objects are gone. For real object resilience, use
  **[`cluster/`](./cluster/)** (4 drives, EC:2, on local-path as well — no need for Longhorn:
  MinIO replicates on its own).
- **The 10 Gi of the PVC is not a limit.** `local-path` provisions a hostPath directory: nothing
  stops MinIO from filling the worker's `/var` partition. The allocatable `ephemeral-storage`
  measured on this lab is **~16.9 GB/node** (20 GB disk shared with the OS and the container
  images) → filling a bucket triggers `DiskPressure` and pod **eviction** on that node. Watch
  `kubectl describe node <worker> | grep -i pressure`.
- **The `minio-creds` Secret is not in git** (the script creates it). Losing it means losing root
  access: `kubectl -n minio-s3 delete secret minio-creds` then re-running the script regenerates
  a password, but MinIO keeps the old one until the pod is recreated.
- **Console behind a separate hostname**: `MINIO_BROWSER_REDIRECT_URL` carries
  `https://minio-console.lab.example.io` in `minio-s3.yaml` — the **neutral** domain of the
  public repo. `minio-up.sh` substitutes it, along with the `HTTPRoute` hostnames, from `LAB_DOMAIN`
  (`lab.env`). A **direct** `kubectl apply -f minio-s3.yaml` keeps the example domain and breaks
  the login redirects. See [`../README.md`](../README.md#-lab_domain--the-ui-domain).

## 📚 References

- MinIO removes admin features from the community console:
  <https://blocksandfiles.com/2025/06/19/minio-removes-management-features-from-basic-community-edition-object-storage-code/>
- Official discussion: <https://github.com/minio/minio/discussions/21326>
- Fork images: <https://hub.docker.com/r/pgsty/minio/tags>
- [`cluster/`](./cluster/) — the distributed 4-node variant (erasure coding).
