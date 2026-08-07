<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 💬 `mattermost/` — Mattermost (chat) + Alertmanager alerts in a channel

> **Self-hosted chat, and the lab's alerting endpoint.** Mattermost **Team Edition** (the free
> community edition) on PostgreSQL, exposed over HTTPS through Envoy Gateway, plus two CRDs that
> turn Prometheus alerts into messages in a dedicated channel — `PrometheusRule` for the rules,
> `AlertmanagerConfig` for the routing. The same routing block works for **Slack** and
> **Microsoft Teams** (see [Other destinations](#-other-destinations-slack-microsoft-teams)).

> 🌐 `lab.example.io` is this repository's NEUTRAL (public) domain: `mattermost-up.sh` replaces it
> with `LAB_DOMAIN` (`lab.env`) in the Helm values **and** in the `HTTPRoute`. See
> [`../README.md`](../README.md#-lab_domain--the-ui-domain).

## 🎯 Purpose

- Give the lab a **notification destination it owns**: no external SaaS, no outbound webhook to
  the internet, no token to rotate.
- Show the **alerting chain end to end**: a rule in Prometheus → a route in Alertmanager → a
  message in a channel, all declared as **Kubernetes CRDs**.
- Serve as the practical backing for the "how do I get alerted?" question that always follows the
  [`observability/`](../observability/README.md) module.

### Three design choices worth knowing

- **PostgreSQL, not the chart's bundled MySQL.** Mattermost **v11 removed the MySQL driver from
  its codebase**. The chart still defaults to `mysql.enabled: true`, which is broken out of the
  box on this app version (see ⚠️ Pitfalls). The database is a
  [CloudNativePG](../cloudnative-pg/README.md) cluster, like Keycloak's.
- **Slack-compatible webhook, no plugin.** Mattermost's incoming webhooks accept Slack's payload
  format, so Alertmanager's stock `slackConfigs` receiver posts to it directly. Nothing to
  install on either side.
- **Bootstrap through `mmctl --local`.** Creating the admin, the team, the channel and the webhook
  happens over a **unix socket inside the pod**, so it needs neither DNS, nor the ingress, nor
  TLS, nor a password on a command line.

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| `../platform-up.sh` (Cilium + Envoy Gateway + cert-manager) | exposes the UI over HTTPS:443 with the wildcard certificate | `kubectl get gateway -n envoy-gateway-system` |
| **`longhorn-r1`** SC ([`../longhorn/`](../longhorn/README.md)) | 3 PVCs: data 5Gi, plugins 1Gi, PostgreSQL 5Gi | `kubectl get sc longhorn-r1` |
| **CloudNativePG** ([`../cloudnative-pg/`](../cloudnative-pg/README.md)) | provides the database; the script **aborts** without the CRD | `kubectl get crd clusters.postgresql.cnpg.io` |
| **kube-prometheus-stack** ([`../observability/`](../observability/README.md)) | Alertmanager + the `PrometheusRule`/`AlertmanagerConfig` CRDs | `kubectl -n monitoring get alertmanager` |

> ℹ️ Alertmanager is the only **soft** prerequisite: without it, steps 4 and 5 are skipped with a
> warning and Mattermost is installed on its own. Re-run the script after installing
> `observability` to wire the alerting up.

## ⚡ Install

Through the repository entry point:
```bash
./install.sh <distro> mattermost     # <distro> = talos | kubeadm
```

```bash
./mattermost/mattermost-up.sh <distro>
```

Versions pinned in the script (overridable by env var):

| Chart | Version | App |
|---|---|---|
| `mattermost/mattermost-team-edition` | `6.6.104` (`MATTERMOST_CHART_VERSION`) | Mattermost 11.9.0 |

The admin password is **generated on the first run** and kept in a Secret, so re-running the
script never changes it:

```bash
kubectl -n mattermost get secret mattermost-admin -o jsonpath='{.data.password}' | base64 -d; echo
```

## 🧬 Talos vs kubeadm

**No distribution-specific behaviour**: same chart, same manifests, same values on both labs. The
distribution only decides the **domain** (`mattermost.talos.lab.example.io` /
`mattermost.kubeadm.lab.example.io`) and where the lab's `lab.env` / `kubeconfig` live.

## 🎓 Guided walkthrough (step by step)

> The commands below are **exactly** what the script does, in order.
> Set up your shell first (once per session):
> ```bash
> export KUBECONFIG=../Vagrant-KubeADM/kubeconfig    # or ../Vagrant-Talos/kubeconfig
> export LAB_DOMAIN=kubeadm.lab.example.io           # your own (see the lab's lab.env)
> ```

### 1. Prerequisites

```bash
kubectl get sc longhorn-r1                              # the 3 PVCs
kubectl get crd clusters.postgresql.cnpg.io             # CloudNativePG
kubectl -n monitoring get alertmanager                  # the alerting target
```

### 2. The database

```bash
kubectl apply -f mattermost/namespace.yaml
kubectl apply -f mattermost/postgres-cluster.yaml
kubectl -n mattermost wait --for=condition=Ready cluster/mattermost-db --timeout=300s
```

### 3. Mattermost itself

The password CloudNativePG generated is injected into the values; it is never written to a
versioned file.

```bash
PGPASS=$(kubectl -n mattermost get secret mattermost-db-app -o jsonpath='{.data.password}' | base64 -d)
sed -e "s/lab\.example\.io/${LAB_DOMAIN}/g" -e "s|@@PGPASSWORD@@|${PGPASS}|" \
  mattermost/values.yaml > /tmp/mm-values.yaml

helm repo add mattermost https://helm.mattermost.com && helm repo update mattermost
helm upgrade --install mattermost mattermost/mattermost-team-edition -n mattermost \
  --version 6.6.104 --values /tmp/mm-values.yaml
kubectl -n mattermost rollout status deploy/mattermost-mattermost-team-edition --timeout=300s
```

### 4. Exposure

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" mattermost/httproute.yaml | kubectl apply -f -
```

### 5. Bootstrap: admin, team, channel, webhook

`mmctl --local` talks to the server over a unix socket in the pod — no authentication needed.

```bash
mm() { kubectl -n mattermost exec deploy/mattermost-mattermost-team-edition \
         -c mattermost-team-edition -- mmctl --local "$@"; }

# NOT `tr -dc … | head -c 24`: head closes the pipe, tr takes a SIGPIPE and the
# script dies on 141 under `set -o pipefail`. Bound the read, not the write.
ADMIN_PASS=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)
kubectl -n mattermost create secret generic mattermost-admin \
  --from-literal=username=admin --from-literal=password="$ADMIN_PASS"

mm user create --email "admin@${LAB_DOMAIN}" --username admin --password "$ADMIN_PASS" --system-admin
mm team create --name lab --display-name "Lab k8s"
mm team users add lab "admin@${LAB_DOMAIN}"
mm channel create --team lab --name alertes-k8s --display-name "Alertes k8s"

# `--channel` and `--user` accept team:channel and an email, despite what --help says.
# The answer's first line is "Id: <26-char id>".
mm webhook create-incoming --channel lab:alertes-k8s --user "admin@${LAB_DOMAIN}" \
   --display-name Alertmanager --lock-to-channel
```

Then store the webhook URL where Alertmanager will read it. **The in-cluster URL on purpose**:
delivering an alert must not depend on the public DNS, on the Gateway or on the certificate.

```bash
HOOK_ID=<the id from the previous command>
kubectl -n monitoring create secret generic mattermost-webhook \
  --from-literal=url="http://mattermost-team-edition.mattermost:8065/hooks/${HOOK_ID}"
```

### 6. The alerting, as two CRDs

```bash
# Without this, NODE alerts are never delivered — see the ⚠️ below.
kubectl -n monitoring patch alertmanager kube-prometheus-stack-alertmanager --type=merge \
  -p '{"spec":{"alertmanagerConfigMatcherStrategy":{"type":"None"}}}'

kubectl apply -f mattermost/prometheusrule-lab-alerts.yaml
kubectl apply -f mattermost/alertmanagerconfig.yaml
```

## 🔧 What the script does

1. **PostgreSQL** — applies the namespace and the CloudNativePG `Cluster`, then waits for
   `condition=Ready` (initdb + first start).
2. **Mattermost** — reads the password CloudNativePG generated, renders the values (domain +
   password) into a temp file, `helm upgrade --install`, waits for the rollout.
3. **HTTPRoute** — renders and applies the exposure.
4. **Bootstrap** — through `mmctl --local`: admin (password generated into a Secret **only once
   the account is really created**), team, channel, and **one** incoming webhook, reused across
   runs. Stores its in-cluster URL in the `mattermost-webhook` Secret.
5. **Alerting** — patches `alertmanagerConfigMatcherStrategy`, applies the `PrometheusRule` and
   the `AlertmanagerConfig`.

Steps 4 and 5 are skipped with a warning if there is no Alertmanager: Mattermost alone still
works.

### Files

| File | Purpose |
|---|---|
| `namespace.yaml` | the `mattermost` namespace (no PodSecurity label needed) |
| `postgres-cluster.yaml` | CloudNativePG `Cluster`: PG 18, 1 instance, 5Gi on `longhorn-r1`, no superuser |
| `values.yaml` | Helm values: bundled MySQL **off**, `externalDB` on PostgreSQL, PVCs on `longhorn-r1`, no Ingress, `Recreate` strategy, local mode on |
| `httproute.yaml` | `mattermost.<LAB_DOMAIN>` → `mattermost-team-edition:8065`, `https` listener |
| `prometheusrule-lab-alerts.yaml` | 6 lab alerts, **faster** than the bundled ones |
| `alertmanagerconfig.yaml` | routing to the Mattermost webhook + `severity: none` dropped |
| `mattermost-up.sh` | the whole thing, idempotent |

### The six alerts, and why they exist next to the bundled ones

kube-prometheus-stack already ships ~150 kubernetes-mixin rules, `KubePodCrashLooping`,
`KubeNodeNotReady`, `NodeCPUHighUsage` and `NodeMemoryHighUtilization` included. They are
**calibrated for production**: `for: 15m` to `30m`, and `NodeCPUHighUsage` sits at
`severity: info`. In a lab nobody waits 15 minutes to see whether alerting works. The `Lab`
prefix means both sets live side by side.

| Alert | Condition | `for` | Severity |
|---|---|---|---|
| `LabPodCrashLooping` | a container in `CrashLoopBackOff` | 2m | critical |
| `LabPodNotReady` | pod `Pending`/`Unknown`/`Failed` (Jobs excluded) | 5m | warning |
| `LabNodeNotReady` | node `Ready != true` | 2m | critical |
| `LabNodeCPUHigh` | node CPU > 85 % (idle/iowait/**steal** excluded) | 5m | warning |
| `LabNodeMemoryHigh` | node RAM > 85 % (on `MemAvailable`) | 5m | warning |
| `LabNodeDiskAlmostFull` | `/` below 15 % free | 5m | warning |

## ✅ Verify

```bash
kubectl -n mattermost get pods,pvc              # 2 pods Running, 3 PVCs Bound on longhorn-r1
curl -s "https://mattermost.${LAB_DOMAIN}/api/v4/system/ping"        # {"status":"OK"}

# The rules are loaded and healthy (6 of them, health=ok):
curl -sk "https://prometheus.${LAB_DOMAIN}/api/v1/rules" \
  | grep -o '"name":"Lab[A-Za-z]*"' | sort -u

# The routing is live in Alertmanager (the receiver must be listed):
curl -sk "https://alertmanager.${LAB_DOMAIN}/api/v2/receivers"
```

## 🧪 Scenario — the alert chain, end to end

The only test that proves anything: provoke a real failure and wait for the message.

```bash
kubectl create deployment crashtest --image=busybox:1.36 -- sh -c 'exit 1'
# ~4 min later (2 min of CrashLoopBackOff + `for: 2m` + 30s groupWait) a
# 🔴 [FIRING:1] LabPodCrashLooping message lands in ~alertes-k8s
kubectl delete deployment crashtest
# and a ✅ [RESOLVED] follows within ~2 min (sendResolved: true)
```

> ℹ️ **Give it four minutes, not one.** `kube_pod_container_status_waiting_reason` is a **sparse**
> series: kube-state-metrics only emits it while the container actually sits in `Waiting`. A
> container that restarts fast is often scraped in `terminated` instead, and the alert only fires
> once the restart backoff has grown enough for a scrape to land in the `CrashLoopBackOff`
> window. That is exactly why the rule uses `max_over_time(...[5m])` and not an instant query.

## 🌐 Access

| What | Where |
|---|---|
| Mattermost | `https://mattermost.<LAB_DOMAIN>` |
| Admin account | `admin` — `kubectl -n mattermost get secret mattermost-admin -o jsonpath='{.data.password}' \| base64 -d` |
| Alert channel | team **Lab k8s**, channel **~alertes-k8s** |

## 📮 Other destinations: Slack, Microsoft Teams

The rules ([`prometheusrule-lab-alerts.yaml`](prometheusrule-lab-alerts.yaml)) never change — only
the receiver in [`alertmanagerconfig.yaml`](alertmanagerconfig.yaml) does.

### Slack

**Identical to Mattermost**, which is the whole point of the Slack-compatible webhook: create an
[incoming webhook](https://api.slack.com/messaging/webhooks) on your workspace, then only the
Secret's content changes.

```bash
kubectl -n monitoring create secret generic slack-webhook \
  --from-literal=url="https://hooks.slack.com/services/<WORKSPACE_ID>/<WEBHOOK_ID>/<TOKEN>"
```

```yaml
      slackConfigs:
        - apiURL: { name: slack-webhook, key: url }
          channel: "#alerts-k8s"      # with the leading # on Slack
          sendResolved: true
          title: '...'                # same templates
          text: '...'
```

Two differences to keep in mind:

- The channel name **takes a `#`** on Slack; Mattermost accepts it with or without.
- Slack renders `*bold*` and `` `code` `` the same way, but **not** `_italics_` inside an
  attachment field the way Mattermost does. Harmless — only the styling differs.

### Microsoft Teams

Teams does **not** understand Slack payloads: it expects a *MessageCard* / *Adaptive Card*. Two
supported routes, depending on your prometheus-operator version:

**1. `msteamsv2Configs` (Power Automate Workflows — the current path).** Microsoft
[retired Office 365 connectors](https://devblogs.microsoft.com/microsoft365dev/retirement-of-office-365-connectors-within-microsoft-teams/);
the replacement is a *Workflow* that gives you an HTTP POST URL. Requires
prometheus-operator ≥ v0.79 and Alertmanager ≥ v0.28 — the versions this repo pins
(operator v0.93.0, Alertmanager v0.33.1) both support it.

```bash
kubectl -n monitoring create secret generic msteams-webhook \
  --from-literal=url="https://prod-00.westeurope.logic.azure.com:443/workflows/…"
```

```yaml
      msteamsv2Configs:
        - webhookURL: { name: msteams-webhook, key: url }
          sendResolved: true
          title: '{{ if eq .Status "firing" }}🔴{{ else }}✅{{ end }} [{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}'
          text: |-
            {{ range .Alerts -}}
            **{{ .Annotations.summary }}**
            {{ .Annotations.description }}
            {{ end }}
```

**2. `msteamsConfigs`** — the older field, for the legacy `webhook.office.com` connector URLs.
Same shape, `webhookUrl` instead of `webhookURL`. Only worth using on an already-wired tenant.

> ⚠️ **Teams is stricter about the payload than Mattermost or Slack.** `title` must stay short and
> Markdown is limited to **bold** and line breaks — no `_italics_`, no `` `code` `` spans. Reuse
> the templates above rather than the Mattermost ones, otherwise the card shows raw backticks.

> 💡 Check what your cluster actually supports before writing the manifest — the field is silently
> dropped if the CRD does not know it:
> ```bash
> kubectl explain alertmanagerconfig.spec.receivers --recursive | grep -i msteams
> ```

### Several destinations at once

Add the receivers and split with matchers — for instance criticals to Teams, everything to
Mattermost:

```yaml
  route:
    receiver: mattermost
    routes:
      - receiver: "null"
        matchers: [{ name: severity, value: none }]
      - receiver: msteams
        matchers: [{ name: severity, value: critical }]
        continue: true          # WITHOUT this, Mattermost never sees the criticals
```

> ⚠️ **`continue: true` is the trap.** Alertmanager stops at the **first** matching route. A
> `critical` route placed before the catch-all silently steals every critical alert from the
> channel below it.

## 🚑 Troubleshooting

| Symptom | Where to look |
|---|---|
| No message at all | `kubectl -n monitoring logs sts/alertmanager-kube-prometheus-stack-alertmanager \| grep -i mattermost` — a 4xx means the webhook URL is wrong or the hook was deleted |
| Pod alerts arrive, node alerts do not | `kubectl -n monitoring get alertmanager kube-prometheus-stack-alertmanager -o jsonpath='{.spec.alertmanagerConfigMatcherStrategy.type}'` must print `None` |
| The receiver is missing | `curl -sk https://alertmanager.<LAB_DOMAIN>/api/v2/receivers` — if `monitoring/mattermost/mattermost` is absent, the operator has not reloaded the CRD yet (wait ~30s) |
| Rules absent from Prometheus | `kubectl -n monitoring get prometheusrule lab-alerts` then `curl -sk https://prometheus.<LAB_DOMAIN>/api/v1/rules \| grep Lab` |
| Mattermost restarts in a loop | `kubectl -n mattermost logs deploy/mattermost-mattermost-team-edition --previous` — almost always the database (see the MySQL pitfall) |
| `mmctl` answers nothing | local mode is off: check `MM_SERVICESETTINGS_ENABLELOCALMODE` in the values |

## ⚠️ Pitfalls

- **Mattermost v11 removed MySQL — the chart's default is broken.** `mysql.enabled: true` (the
  chart's default) builds `MM_CONFIG=mysql://…`; v11 no longer recognises that as a database DSN,
  treats it as a **file path** and dies on
  `could not create config file: open /mattermost/config/mysql:/mattermost:<pwd>@tcp(...)`.
  The mangled path (`mysql:/` with a single slash, from path cleaning) is the tell. Hence
  `mysql.enabled: false` + `externalDB` on PostgreSQL.
- **`deploymentStrategy: Recreate` is mandatory** with RWO Longhorn volumes. With the chart's
  default `RollingUpdate`, the new pod tries to attach a volume the old one still holds →
  `Multi-Attach error for volume … Volume is already used by pod(s) …` and the rollout hangs
  forever. Same trap as [`../wordpress-example/`](../wordpress-example/README.md).
  ⚠️ **Switching an already-deployed release** to `Recreate` fails twice over. First on
  `spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy type is 'Recreate'`
  (the leftover field). And if you clear it with `kubectl patch`, the *next* `helm upgrade` fails
  on `conflict with "kubectl-patch" using apps/v1: .spec.strategy.type` — the patch took
  ownership of the field away from Helm, and server-side apply refuses to steal it back. Delete
  the Deployment instead and let Helm recreate it cleanly; the PVCs are separate objects, so
  nothing is lost:
  ```bash
  kubectl -n mattermost delete deploy mattermost-mattermost-team-edition
  ./mattermost/mattermost-up.sh <distro>
  ```
  (Helm 4 also accepts `--force-conflicts`, but that silences *every* conflict, including the
  ones worth reading.)
- **Node alerts never arrive** → `alertmanagerConfigMatcherStrategy` is still the default
  `OnNamespace`. prometheus-operator then injects a `namespace="monitoring"` matcher into the
  route generated from the CRD, and node alerts (`LabNodeNotReady`, `LabNodeCPUHigh`…) carry **no
  `namespace` label**. The failure is silent and looks like success, because the *pod* alerts do
  arrive. `type: None` is the fix.
- **The channel drowns in `Watchdog` / `InfoInhibitor`** → these are Alertmanager's own plumbing,
  **always firing by design**. Route `severity: none` to a null receiver (this is what
  `alertmanagerconfig.yaml` does); matching the severity rather than the two alert names also
  covers any future one.
- **Every notification arrives twice** → two incoming webhooks point at the channel. The script
  reuses the one named `Alertmanager`; a hook created by hand under another name adds a second
  delivery. `mmctl --local webhook list lab`.
- **`MM_SERVICESETTINGS_SITEURL` must be the `https://` URL.** Mattermost builds its own links
  *and its webhook URLs* from it; with a wrong value the webhooks answer but the permalinks in
  the messages point somewhere unreachable.
- **No shell in the image.** `kubectl exec … -- sh` fails with
  `exec: "sh": executable file not found`. Call `mmctl` directly, without a shell wrapper.
- **The chart's containers have no CPU limit**, which trips the lab's Kyverno
  `require-requests-limits` policy. It is in **Audit** mode, so it only produces a
  `PolicyViolation` warning — nothing is blocked. This repo caps RAM and deliberately does not
  throttle CPU.

## 🧹 Uninstall

```bash
kubectl -n monitoring delete alertmanagerconfig mattermost
kubectl -n monitoring delete prometheusrule lab-alerts
kubectl -n monitoring delete secret mattermost-webhook
helm uninstall mattermost -n mattermost
kubectl delete ns mattermost          # ⚠️ deletes the PVCs, so the messages and the database
```

## 📚 References

- [Mattermost Team Edition Helm chart](https://github.com/mattermost/mattermost-helm/tree/master/charts/mattermost-team-edition)
- [Mattermost — removed and deprecated features (MySQL in v11)](https://docs.mattermost.com/product-overview/deprecated-features.html)
- [Mattermost — incoming webhooks (Slack-compatible)](https://developers.mattermost.com/integrate/webhooks/incoming/)
- [`mmctl` — local mode](https://docs.mattermost.com/manage/mmctl-command-line-tool.html)
- [prometheus-operator — `AlertmanagerConfig` API](https://prometheus-operator.dev/docs/api-reference/api/#monitoring.coreos.com/v1alpha1.AlertmanagerConfig)
- [Alertmanager — routing tree and `continue`](https://prometheus.io/docs/alerting/latest/configuration/#route)
- [`../observability/README.md`](../observability/README.md) — where the alerts come from
