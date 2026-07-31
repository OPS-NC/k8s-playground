<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# ⚖️ `kyverno/` — Kubernetes policy engine + Policy Reporter UI

> **Kyverno = an admission webhook + background controllers.** Three verbs: `validate`
> (accept / reject / audit), `mutate` (rewrite the incoming resource), `generate` (create a
> derived resource). Verdicts land in `PolicyReport` objects, aggregated by **Policy Reporter**
> into a web UI at `kyverno.lab.example.io`.

> 🌐 **`lab.example.io` is the repo's NEUTRAL domain (public)**: `kyverno-up.sh` swaps it
> for `LAB_DOMAIN` (`lab.env`) at `kubectl apply` time. See
> [`../README.md`](../README.md#-lab_domain--the-ui-domain).

## 🎯 Purpose

Show, on an already-running cluster, what a policy engine catches — **without breaking anything**:

- the 4 validation policies ship in **`Audit`** (they report, they do not block);
- every evaluation webhook is **fail-open** (see 🔧): even with Kyverno down, the cluster keeps
  accepting pod creations;
- one `mutate` policy and one `generate` policy round out the demo of the three verbs.

Read the existing violations in the UI first, then show a switch to `Enforce` on a single policy,
just for the demo.

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| Platform in place (`../platform-up.sh`) | the UI is exposed through `main-gateway` + the wildcard cert | `kubectl -n envoy-gateway-system get certificate` |
| DNS `kyverno.lab.example.io → 192.168.56.200` (**DNS-only**) | hostname of the `HTTPRoute` | `curl --resolve` otherwise (see ✅) |
| Nothing on the node side | Kyverno runs **unprivileged**, compliant with PodSecurity `restricted` | `kubectl -n kyverno get pods` |

## ⚡ Install

> 🎓 **Two paths, same result**: the all-in-one script below, or the **"Guided
> walkthrough"** section further down — the same commands, one at a time, for training.

Through the repository entry point:
```bash
./install.sh <distro> kyverno     # <distro> = talos | kubeadm
```

```bash
./kyverno/kyverno-up.sh <distro>
```

Versions pinned in the script: chart `kyverno/kyverno` **`3.8.2`** (app **v1.18.2**) and
`policy-reporter/policy-reporter` **`3.9.1`** (`KYVERNO_VERSION` / `POLICY_REPORTER_VERSION`
can be overridden). Idempotent (`helm upgrade --install` + `kubectl apply`).

## 🧬 Talos vs kubeadm

**No distribution-specific behaviour for this component**: same charts, same manifests, same
values on both labs. The distribution argument only drives two things here: the **default
domain** (`talos.lab.example.io` / `kubeadm.lab.example.io`) and **where the lab's `lab.env`
/ `kubeconfig` live** (`../Vagrant-Talos/` or `../Vagrant-KubeADM/`).

> ℹ️ One **teaching** nuance: the `04-disallow-privileged` policy overlaps the `baseline`
> PodSecurity level, which **is enforced cluster-wide on Talos** but **not on kubeadm**. On
> kubeadm, Kyverno is therefore what actually provides the guardrail; on Talos it doubles the
> existing admission (and shows it in `Audit` mode, which is instructive).

## 🎓 Guided walkthrough (step by step)

> The commands below are **exactly** what the all-in-one script does, in order.
> Set up your shell first (once per session):
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig        # or ../Vagrant-KubeADM/kubeconfig
> export LAB_DOMAIN=talos.lab.example.io               # or your own (see the lab's lab.env)
> ```

### 1. The engine

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/ && helm repo update kyverno
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace \
  --version 3.8.2 --values kyverno/values.yaml
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s
kubectl get crd | grep kyverno.io
```

### 2. The teaching policies (validate in **Audit**, mutate, generate)

`Audit`, not `Enforce`: nothing is blocked, everything is **reported**. That is the right mode
to observe without breaking a lab.

```bash
kubectl apply -f kyverno/policies/
kubectl get clusterpolicy
```

### 3. Policy Reporter + its UI

```bash
helm repo add policy-reporter https://kyverno.github.io/policy-reporter && helm repo update policy-reporter
helm upgrade --install policy-reporter policy-reporter/policy-reporter -n kyverno \
  --version 3.9.1 --values kyverno/policy-reporter-values.yaml
kubectl -n kyverno rollout status deploy/policy-reporter-ui --timeout=180s
```

### 4. The HTTPRoute

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" kyverno/httproute.yaml | kubectl apply -f -
```

### 5. Read the reports

```bash
kubectl get policyreport -A
kubectl get clusterpolicyreport
kubectl get policyreport -A -o custom-columns=\
'NS:.metadata.namespace,PASS:.summary.pass,FAIL:.summary.fail,WARN:.summary.warn'
```

### 6. See each policy type in action

```bash
# mutate: the label is added automatically
kubectl run demo --image=docker.io/library/busybox --restart=Never -- sleep 60
kubectl get pod demo -o jsonpath='{.metadata.labels}'; echo      # lab.k8s/managed-by=kyverno

# validate (Audit): the pod IS admitted, but the violation is reported
kubectl run bad --image=nginx:latest --restart=Never -- sleep 60  # :latest tag disallowed
kubectl get policyreport -o wide | grep bad

# generate: a default NetworkPolicy appears in a brand-new namespace
kubectl create ns gen-test && kubectl -n gen-test get netpol

kubectl delete pod demo bad --ignore-not-found; kubectl delete ns gen-test
echo "UI: https://kyverno.${LAB_DOMAIN}"
```

## 🔧 What the script does

1. installs **Kyverno** in the `kyverno` namespace with `values.yaml`, then waits for the
   `admission-controller`;
2. applies **`policies/`** (4 `validate` in Audit + 1 `mutate` + 1 `generate`) and lists them;
3. installs **Policy Reporter** (+ UI + the **kyverno** and **trivy** plugins) with
   `policy-reporter-values.yaml`;
4. applies **`httproute.yaml`** → `https://kyverno.lab.example.io`.

### The decisive choice in this lab: evaluation is fail-open

`values.yaml` sets `features.forceFailurePolicyIgnore.enabled: true`. The webhooks that
**evaluate your resources** therefore move to `failurePolicy: Ignore` — you can read it in their
names: `validate.kyverno.svc-ignore`, `mutate.kyverno.svc-ignore`.

| Situation | Consequence |
|---|---|
| Kyverno **unreachable** (pod down, timeout) | the request **goes through anyway** — no "Kyverno down ⇒ no pod ever starts" deadlock |
| Kyverno **reachable**, policy in `Audit` | the request goes through, a `fail` is written to the `PolicyReport` |
| Kyverno **reachable**, policy in `Enforce` | the request is **rejected** (fail-open does not disarm blocking) |

> ℹ️ Kyverno's **internal** webhooks (validation of `ClusterPolicy` and `PolicyException`,
> cleanup) stay on `failurePolicy: Fail`: only the evaluation of your own resources is fail-open.
> Check it yourself:
> ```bash
> kubectl get validatingwebhookconfigurations \
>   -o 'custom-columns=NAME:.metadata.name,POLICY:.webhooks[*].failurePolicy' | grep kyverno
> ```
> The quotes around `custom-columns=…` are required: without them the shell expands `[*]`.

### Files

| File | Purpose |
|---------|------|
| `values.yaml` | 1 replica per controller (4 controllers), chart default resources, **`forceFailurePolicyIgnore` enabled** |
| `policy-reporter-values.yaml` | Policy Reporter + **UI** + **kyverno** plugin + **trivy** plugin + metrics |
| `httproute.yaml` | HTTPS `HTTPRoute` `kyverno.lab.example.io` → `policy-reporter-ui:8080` |
| `kyverno-up.sh` | installs everything in order, idempotent |
| `policies/01-require-labels.yaml` | **validate/Audit** — requires `app.kubernetes.io/name` |
| `policies/02-disallow-latest-tag.yaml` | **validate/Audit** — explicit tag mandatory, `:latest` forbidden |
| `policies/03-require-requests-limits.yaml` | **validate/Audit** — `requests` + `limits` (cpu **and** memory) |
| `policies/04-disallow-privileged.yaml` | **validate/Audit** — forbids privileged containers |
| `policies/10-mutate-add-labels.yaml` | **mutate** — adds `lab.k8s/managed-by: kyverno` |
| `policies/20-generate-default-netpol.yaml` | **generate** — default-deny NetworkPolicy (opt-in by label) |

## ✅ Verify

```bash
kubectl -n kyverno get pods                    # 4 controllers + policy-reporter (+ui, +2 plugins)
kubectl get clusterpolicy                      # 6 policies, READY=True
kubectl get policyreport -A                    # per-namespace reports (PASS/FAIL/WARN)
kubectl get clusterpolicyreport                # cluster-scoped reports

# end-to-end test (trusted wildcard cert, served by Envoy):
curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  --resolve kyverno.lab.example.io:443:192.168.56.200 \
  https://kyverno.lab.example.io/            # expected: 200 verify=0
```

Count the `fail` results per policy (handy when preparing a demo):

```bash
kubectl get policyreport -A -o json | jq -r \
  '.items[].results[] | select(.result=="fail") | .policy' | sort | uniq -c | sort -rn
```

## 🌐 Access

| What | Where | Authentication |
|---|---|---|
| Policy Reporter UI | `https://kyverno.lab.example.io` | **none** — see ⚠️ Pitfalls |
| Policy Reporter API | `kubectl -n kyverno port-forward svc/policy-reporter 8080:8080` | none |

## 🧪 Scenarios

### 1. Read the violations (validate in Audit)

The **background scan** evaluates what already runs as soon as it is installed. In the UI:
violations per namespace, per policy, per severity. Nothing was blocked — this is audit. Start
with `require-requests-limits` and `require-labels`: they are the noisiest, and that is
**instructive** (see ⚠️ Pitfalls, "the repo violates its own policies").

### 2. Switch a policy to Enforce (real blocking)

```bash
kubectl patch clusterpolicy disallow-latest-tag --type merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}'
kubectl run bad --image=nginx:latest            # REJECTED by the Kyverno webhook
kubectl patch clusterpolicy disallow-latest-tag --type merge \
  -p '{"spec":{"validationFailureAction":"Audit"}}'
```

> ⚠️ **`spec.validationFailureAction` is deprecated** on this Kyverno (v1.18.2):
> `kubectl explain clusterpolicy.spec.validationFailureAction` answers "Deprecated, use
> validationFailureAction under the validate rule instead". The field still works (the repo's 4
> policies use it at the `spec` level), but the modern form is
> `spec.rules[].validate.failureAction`. Nothing to fix for the demo; worth knowing before a
> major Kyverno version bump.

### 3. See the mutation in action

```bash
kubectl run demo --image=nginx:1.27
kubectl get pod demo --show-labels              # lab.k8s/managed-by=kyverno added
kubectl delete pod demo
```

### 4. See generation in action (opt-in by label)

```bash
kubectl create ns demo-netpol
kubectl label ns demo-netpol kyverno-demo=true
kubectl -n demo-netpol get netpol               # default-deny generated by Kyverno
kubectl delete ns demo-netpol
```

### 5. Create a targeted exception (PolicyException)

`longhorn-system` MUST run privileged → it shows up as `fail` on
`disallow-privileged-containers`. In the real world you exempt it cleanly. `PolicyException`
objects are **disabled by default** in the chart; for the demo, reinstall with
`--set features.policyExceptions.enabled=true --set features.policyExceptions.namespace=kyverno`,
then create a `PolicyException` targeting `longhorn-system`. Otherwise, just show the `fail` in
the UI as an illustration of the need.

## 🚑 Troubleshooting

- **Nothing in the UI** → aggregation takes ~30 s. `kubectl get policyreport -A` should already
  list rows; if not, check that `policy-reporter-ui` and `policy-reporter-kyverno-plugin` are
  `Running` (`kubectl -n kyverno get pods`).
- **404 / route not attached** → `kubectl -n kyverno describe httproute policy-reporter-ui`
  (`sectionName: https` on `main-gateway`, hostname covered by the wildcard).
- **`clusterpolicy` stuck at `READY=False`** → `kubectl describe clusterpolicy <name>`: usually a
  `pattern` error, or a CRD missing on the generator side.

## ⚠️ Pitfalls

- **"System components are never subject to policies" is FALSE.** The chart does exclude
  `kube-system`, `kube-public`, `kube-node-lease` and `kyverno` via `config.resourceFilters`
  — but that filter applies to **admission**. The **background scan** evaluates those resources
  anyway and produces reports: on this lab, dozens of `fail` results in `kube-system`
  (cilium, kube-proxy…) and inside `kyverno` itself. Check it:
  `kubectl -n kube-system get policyreport`. Practical conclusion: no risk of **blocking** a
  system component, but the reports do include them. *(The comment in `values.yaml` is too
  categorical on this point.)*
- **The repo violates its own policies — deliberately, but it is noisy:**
  - `03-require-requests-limits` requires `limits.cpu`, which **no** manifest in the repo sets
    (deliberate choice: cap memory, do not *throttle* CPU). Result: by far the most-failing
    policy, and it drowns the others in the UI.
  - `01-require-labels` requires `app.kubernetes.io/name` while every in-house manifest uses
    `app:` → a systematic `fail` on the lab demos.
  - `02-disallow-latest-tag` only inspects `spec.containers`: a `:latest` inside
    **`initContainers`** slips through unnoticed. A good policy-extension exercise.
- **UI with no authentication.** Policy Reporter is published over HTTPS with no auth: anyone who
  reaches VIP `.200` (any authorized Tailscale peer) reads the cluster's inventory of weaknesses.
  To protect it: an Envoy Gateway `SecurityPolicy` (Basic Auth / OIDC) on the route.
- **A legitimate Pod rejected after a switch to `Enforce`** → put the policy back to `Audit`
  (scenario 2) or create a `PolicyException`. Never leave a badly calibrated `Enforce` policy on
  a shared cluster.
- **1 replica for the admission-controller** = an accepted SPOF (lab). Fail-open avoids the
  deadlock, but during a restart the policies simply stop applying. For robustness:
  `admissionController.replicas: 3` in `values.yaml` (costs RAM).

## 🧹 Uninstall

```bash
kubectl delete -f kyverno/httproute.yaml
kubectl delete -f kyverno/policies/
helm -n kyverno uninstall policy-reporter
helm -n kyverno uninstall kyverno            # also removes the CRDs → deletes the PolicyReports
kubectl delete ns kyverno
```

> ⚠️ If [`../trivy-operator/`](../trivy-operator/README.md) is installed, it **loses its UI**:
> Policy Reporter (namespace `kyverno`) is what hosts it.

## 📚 References

- [Kyverno — documentation](https://kyverno.io/docs/)
- [Kyverno — policy library](https://kyverno.io/policies/)
- [Kyverno — PolicyException](https://kyverno.io/docs/exceptions/)
- [Policy Reporter](https://kyverno.github.io/policy-reporter/)
- [`../trivy-operator/README.md`](../trivy-operator/README.md) — the **detective** side, same UI
