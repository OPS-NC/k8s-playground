<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 📈 `observability/` — metrics (Prometheus/Grafana) + logs (Loki/Alloy)

> The lab's observability stack, in one command: **kube-prometheus-stack** (Prometheus,
> Grafana, Alertmanager, node-exporter, kube-state-metrics) + **Loki** (logs) + **Grafana
> Alloy** (collection). Three UIs over HTTPS behind `main-gateway`.

> 🌐 **`lab.example.io` is the repo's NEUTRAL (public) domain**: `observability-up.sh`
> replaces it with `LAB_DOMAIN` (`lab.env`) in the Helm values **and** in the `HTTPRoute`s. See
> [`../README.md`](../README.md#-lab_domain--the-ui-domain).

## 🎯 Purpose

- Backing for the **PromQL / dashboards / alerting** modules (Prometheus + Grafana + Alertmanager).
- **Centralized logs**: Alloy reads `/var/log/pods` on every node → Loki → Grafana's *Explore*
  tab (Grafana is pre-wired with **both** datasources).
- The base you hook the other components' metrics onto (⚠️ nothing is hooked up by
  default, see Pitfalls).

### Two important design choices

- **Alloy in file mode (not API).** Reading logs through `loki.source.kubernetes` (k8s API)
  pushes **every log line through the kube-apiserver** → huge load (it contributed to this lab's
  CP incident). Here Alloy reads `/var/log/pods` directly on each node (one DaemonSet, each node
  handling its own share); `discovery.kubernetes` is only used for **labelling** (a lightweight
  metadata watch).
- **`longhorn-r1` storage (1 block replica).** Metrics and logs are rebuildable: no need to
  replicate the blocks 3×, that would fill up the shared OS disk.

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| `../platform-up.sh` (Cilium + Envoy Gateway + cert-manager) | exposes the 3 UIs over HTTPS:443 with the wildcard cert | `kubectl get gateway -n envoy-gateway-system` |
| **Longhorn** + **`longhorn-r1`** SC (`../longhorn/longhorn-r1-storageclass.yaml`) | PVCs for Prometheus (3Gi), Loki (3Gi), Grafana (1Gi); the script **aborts** without it | `kubectl get sc longhorn-r1` |
| **4 GB control planes** (`CP_MEM=4096` in `lab.env`) | this stack loads the apiserver (scrapes + watches) | `vagrant ssh k8s-cp1 -c 'free -h'` |

> ⚠️ **Control-plane RAM — `lab.env.example` ships `CP_MEM=3072`, which is NOT enough for this
> stack.** Raise it to **`CP_MEM=4096`** in your `lab.env` **before** installing, then
> `vagrant reload` the CPs **one at a time**.
>
> On **3 GB** CPs, stacking this pile on top of the rest of the lab **saturates etcd/apiserver**
> (lived through it: OOM loop, API unreachable). At **4 GB**, the stack sits at ~50 % of CP
> memory. 2 GB already **starve etcd** on their own.

## ⚡ Install

> 🎓 **Two paths, same result**: the all-in-one script below, or the **"Guided
> walkthrough"** section further down — the same commands, one at a time, for training.

Through the repository entry point:
```bash
./install.sh <distro> observability     # <distro> = talos | kubeadm
```

```bash
kubectl apply -f longhorn/longhorn-r1-storageclass.yaml   # if not already done
./observability/observability-up.sh <distro>
```

Versions pinned in the script (overridable by env var):

| Chart | Version | App |
|---|---|---|
| `prometheus-community/kube-prometheus-stack` | `88.0.1` (`KPS_VERSION`) | Prometheus Operator v0.93.0 |
| `grafana/loki` | `7.2.0` (`LOKI_VERSION`) | Loki v3.6.11 |
| `grafana/alloy` | `1.11.0` (`ALLOY_VERSION`) | Alloy v1.18.0 |

## 🧬 Talos vs kubeadm

One difference, but it changes what Prometheus can see (`KPS_SCRAPE_CONTROL_PLANE` in the
profiles):

| Chart monitor | Talos | kubeadm | Why |
|---|---|---|---|
| `kubeControllerManager` | **disabled** | enabled (`:10257`, HTTPS, `insecureSkipVerify`) | kubeadm sets `bind-address: 0.0.0.0` on the static pod; on Talos the component is not scrapable without dedicated TLS |
| `kubeScheduler` | **disabled** | enabled (`:10259`) | same |
| `kubeEtcd` | **disabled** | enabled (`:2381`, `scheme: http`) | the kubeadm lab passes `listen-metrics-urls: http://0.0.0.0:2381` at bootstrap; by default that endpoint is loopback-only |
| `kubeProxy` | disabled | disabled | either replaced by Cilium (eBPF), or metrics bound to `127.0.0.1:10249` |

The values file is **shared** (it encodes the kubeadm case): `observability-up.sh` adds the
`--set …enabled=false` flags on Talos. Without that, Prometheus would show unexplained "down"
targets — the worst possible outcome in a training session.

Alloy reads `/var/log/pods`: identical on both (containerd), with the `monitoring` namespace
labelled `privileged` (required on Talos, intent documentation on kubeadm).

## 🎓 Guided walkthrough (step by step)

> The commands below are **exactly** what the all-in-one script does, in order.
> Set up your shell first (once per session):
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig        # or ../Vagrant-KubeADM/kubeconfig
> export LAB_DOMAIN=talos.lab.example.io               # or your own (see the lab's lab.env)
> ```

### 1. Prerequisites

```bash
kubectl get sc longhorn-r1                  # Prometheus/Loki PVCs (1 block replica)
kubectl top nodes                           # metrics-server in place (platform)
free -g                                     # CP ≥ 4 GB: this stack is the hungriest
```

### 2. The `monitoring` namespace (privileged PodSecurity: node-exporter + Alloy)

```bash
kubectl apply -f observability/namespace.yaml
```

### 3. kube-prometheus-stack — **the `--set` flags differ per distribution**

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community
# values rendered with the domain (Grafana domain/root_url, externalUrl)
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" observability/kube-prometheus-stack-values.yaml > /tmp/kps.yaml

# Talos: disable the control-plane monitors (not scrapable)
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace --version 88.0.1 --values /tmp/kps.yaml \
  --set kubeControllerManager.enabled=false \
  --set kubeScheduler.enabled=false \
  --set kubeEtcd.enabled=false

# kubeadm: keep the values as they are (all three monitors enabled)
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace --version 88.0.1 --values /tmp/kps.yaml

kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana --timeout=300s
```

### 4. Loki (single binary, filesystem on Longhorn)

```bash
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update grafana
helm upgrade --install loki grafana/loki -n monitoring \
  --version 7.2.0 --values observability/loki-values.yaml
kubectl -n monitoring rollout status statefulset/loki --timeout=300s
```

### 5. Alloy (ships `/var/log/pods` → Loki)

```bash
helm upgrade --install alloy grafana/alloy -n monitoring \
  --version 1.11.0 --values observability/alloy-values.yaml
kubectl -n monitoring rollout status daemonset/alloy --timeout=180s
```

### 6. The three HTTPRoutes

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" observability/httproutes.yaml | kubectl apply -f -
```

### 7. Verify — targets UP, and logs flowing

```bash
# No "down" target: on Talos that is the whole point of step 3's --set flags
kubectl -n monitoring exec sts/prometheus-kube-prometheus-stack-prometheus -c prometheus -- \
  wget -qO- localhost:9090/api/v1/targets | tr ',' '\n' | grep -c '"health":"up"'
kubectl -n monitoring get servicemonitors
curl --resolve "grafana.${LAB_DOMAIN}:443:192.168.56.200" "https://grafana.${LAB_DOMAIN}/login" -kSI | head -1
echo "Grafana: https://grafana.${LAB_DOMAIN}  (admin / prom-operator — CHANGE IT)"
```

## 🔧 What the script does

1. **`monitoring` namespace** in PodSecurity `privileged` (node-exporter in hostNetwork/hostPath
   + Alloy with a hostPath on `/var/log/pods`);
2. **kube-prometheus-stack** → waits for the Grafana rollout;
3. **Loki** (SingleBinary, filesystem) → waits for the StatefulSet;
4. **Alloy** (DaemonSet) → waits for the DaemonSet;
5. **HTTPRoutes** grafana / prometheus / alertmanager.

### Files

| File | Purpose |
|---------|------|
| `namespace.yaml` | ns `monitoring` in PodSecurity `privileged` |
| `kube-prometheus-stack-values.yaml` | Prometheus (`retention: 2d`, 3Gi PVC on `longhorn-r1`) + Grafana (1Gi PVC + Loki datasource) + Alertmanager (emptyDir); controller-manager & scheduler **scraped**, etcd & kube-proxy off (see below); scrapes **every** ServiceMonitor/PodMonitor |
| `loki-values.yaml` | Loki **SingleBinary** + filesystem on a 3Gi `longhorn-r1` PVC; memcached caches **turned off** (otherwise ~9 GB of RAM requested) |
| `alloy-values.yaml` | Alloy **DaemonSet, file mode** (`/var/log/pods`) → Loki; **does NOT load the apiserver** |
| `httproutes.yaml` | 3 HTTPS `HTTPRoute`s on `main-gateway` (wildcard TLS already carried by the listener) |
| `observability-up.sh` | Installs everything in order (idempotent) |

### Control-plane targets: two on, two off

The Talos lab disabled **all four** control-plane monitors, because those components only
listened on loopback there. On kubeadm the situation differs component by component, so they are
enabled **one by one** — never a dead target:

| Monitor | State | Why |
|---|---|---|
| `kubeControllerManager` | **on**, `:10257` HTTPS | `kubeadm/templates/kubeadm-init.yaml.tpl` sets `bind-address: 0.0.0.0` on it. `insecureSkipVerify: true`: the serving cert is signed by the cluster CA but carries no DNS name for the Service. |
| `kubeScheduler` | **on**, `:10259` HTTPS | same thing. |
| `kubeEtcd` | **off** | etcd *is* a stacked static pod and *does* expose `:2381`, but kubeadm generates its manifest with `--listen-metrics-urls=http://127.0.0.1:2381` — **loopback only**, it serves the pod's liveness probe. To open it for real: add `listen-metrics-urls: http://0.0.0.0:2381` to `etcd.local.extraArgs` in `kubeadm/templates/kubeadm-init.yaml.tpl`, then flip `kubeEtcd.enabled: true` with `service.port: 2381` and `serviceMonitor.scheme: http`. |
| `kubeProxy` | **off** | there is **no kube-proxy**: `KUBE_PROXY_REPLACEMENT=true` (the `lab.env` default) runs `kubeadm init --skip-phases=addon/kube-proxy` and Cilium handles Services in eBPF. Equivalent metrics come from Cilium. |

Both static pods carry the `component: kube-controller-manager` / `component: kube-scheduler`
labels that the chart's headless Service selects on: nothing else to wire up.

## ✅ Verify

```bash
kubectl -n monitoring get pods                         # all Running (including 1 alloy per node)
kubectl -n monitoring get httproute                    # grafana/prometheus/alertmanager

# Control-plane targets actually UP (one line per control plane, twice):
kubectl -n monitoring exec sts/prometheus-kube-prometheus-stack-prometheus -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets?state=active' \
  | grep -o '"job":"kube-[a-z-]*"' | sort -u   # kube-controller-manager, kube-scheduler

# Endpoints (wildcard cert; --resolve bypasses DNS). -k if the cert is staging.
for h in grafana prometheus alertmanager; do
  curl -sk -o /dev/null -w "$h -> %{http_code}\n" \
    --resolve $h.lab.example.io:443:192.168.56.200 https://$h.lab.example.io/
done   # expected: grafana 302, prometheus 302, alertmanager 200

# Logs actually landing in Loki (labels set by Alloy):
kubectl -n monitoring exec deploy/loki-gateway -- \
  wget -qO- http://localhost:8080/loki/api/v1/labels     # app, container, namespace, pod…
```

## 🌐 Access

| Service | URL | Username | Password |
|---|---|---|---|
| Grafana | `https://grafana.lab.example.io` | `admin` | `kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' \| base64 -d; echo` |
| Prometheus | `https://prometheus.lab.example.io` | — | no authentication |
| Alertmanager | `https://alertmanager.lab.example.io` | — | no authentication |

## 🚑 Troubleshooting

- **404 on the UIs right after the install** → Envoy still propagating the HTTPRoutes; retry
  after ~30 s.
- **CPs saturating / apiserver flapping** → undersized CPs: move to **4 GB**
  (`CP_MEM`, then `vagrant reload` the CPs one at a time).
- **PVC `Pending` / `ReplicaSchedulingFailure`** → `longhorn-r1` missing, or disk full
  (lower the retention or the PVC sizes).
- **No logs in Loki** → is there one Alloy per node in `2/2`? `kubectl -n monitoring get ds alloy`.
  Then check `loki.write` in Alloy's logs.
- **A pod "with no logs"** → usually just too narrow a **time range**: healthy pods
  (prometheus, node-exporter…) log at startup then go quiet. Widen the window (12-24 h).
- **Control-plane logs (apiserver/scheduler/controller-manager/etcd)** → these are **static
  pods**: their `/var/log/pods` directory is named `<ns>_<pod>_<HASH>` (config hash), not the
  API `<uid>`. Alloy's `__path__` matches on `<ns>_<pod>_*` to cover both cases.
  Unlike the Talos lab — where etcd was a **Talos service**, invisible to Loki — here etcd is a
  regular static pod: **its logs do land in Loki** (`{pod=~"etcd-.*"}`). Only its *metrics*
  endpoint stays out of reach (see "Control-plane targets" above).

## ⚠️ Pitfalls

- **Loki retention relies on the compactor, not on `retention_period`.** In Loki,
  `limits_config.retention_period` only **states** the limit: the deletion itself is the
  **compactor**'s job, and its `retention_enabled` defaults to `false`. A configuration that
  only sets `retention_period` therefore lets logs pile up until the disk is full.
  `loki-values.yaml` enables both (**24 h** retention, `retention_enabled: true`,
  `delete_request_store: filesystem`, effective purge after `retention_delete_delay: 2h`).
  Check that the block really is rendered:
  ```bash
  kubectl -n monitoring get cm loki -o jsonpath='{.data.config\.yaml}' \
    | grep -A4 '^compactor:'
  ```
- **Prometheus has no `retentionSize`.** There is only `retention: 2d`, which bounds the **age**
  of the series, not the **volume** they take: a cardinality spike (new ServiceMonitors, churning
  pods) can fill the 3 Gi before the 2 days are up, and Prometheus then goes into a write error.
  A `retentionSize: 2GiB` in `prometheusSpec` would bound both.
- **Grafana keeps the chart's default admin password** (documented in a comment in
  `kube-prometheus-stack-values.yaml`, and **printed in clear text** by `observability-up.sh` at
  the end of its run) — while the UI is exposed **over public HTTPS** with a **prod** Let's
  Encrypt certificate (so a resolvable name and a trusted cert). A lab, yes, but a reachable
  one: change the password on the first login, or go through
  `grafana.admin.existingSecret`.
- **Prometheus and Alertmanager are exposed with NO authentication at all** (no filter on
  the HTTPRoutes): anyone who reaches the Gateway can read every metric and **silence
  alerts**.
- **Nothing emits application metrics by default.**
  `serviceMonitorSelectorNilUsesHelmValues: false` does make Prometheus scrape **every**
  ServiceMonitor/PodMonitor in the cluster… but **every emitter in the lab is switched off**.
  Flip them to `true` **after** this install (the `ServiceMonitor`/`PodMonitor` CRDs only exist
  afterwards), then re-run the `*-up.sh` of the component concerned:

  | File | Key to set to `true` |
  |---|---|
  | `../trivy-operator/values.yaml` | `serviceMonitor.enabled` |
  | `../cloudnative-pg/values.yaml` | `monitoring.podMonitorEnabled` (operator) |
  | `../cloudnative-pg/cluster-demo.yaml` | `monitoring.enablePodMonitor` (PG instances) |
  | `../node-problem-detector/values.yaml` | `metrics.serviceMonitor.enabled` |
  | `../vault-secret-operator/values.yaml` | `telemetry.serviceMonitor.enabled` |

## 📚 References

- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Grafana Loki (Helm)](https://grafana.com/docs/loki/latest/setup/install/helm/) ·
  [Loki retention (compactor)](https://grafana.com/docs/loki/latest/operations/storage/retention/)
- [Grafana Alloy](https://grafana.com/docs/alloy/latest/)
- Related addons: `../longhorn/` (`longhorn-r1` SC) · `../node-problem-detector/` (node
  health) · `../envoy-gateway/` + `../cert-manager/` (HTTPS exposure)
