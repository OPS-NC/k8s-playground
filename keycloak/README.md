<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🛂 `keycloak/` — Keycloak through its **operator**, exposed with the Gateway API

> **An identity provider the cluster can rebuild from a file.** Keycloak is deployed by its
> **operator**: a thirty-line `Keycloak` CR replaces the StatefulSet, the Service and the whole
> server configuration, and a `KeycloakRealmImport` CR makes the `lab` realm **reproducible**.
> The admin console and the OIDC endpoints are published at `keycloak.lab.example.io` behind
> the same `main-gateway` as the rest of the lab, on the **`*.lab.example.io` wildcard** that is
> already issued — nothing new on the certificate side.

> 🌐 **`lab.example.io` is the repo's NEUTRAL domain (public)**: `keycloak-up.sh` swaps it for
> `LAB_DOMAIN` (`lab.env`) in the `Keycloak` CR, the realm and the `HTTPRoute`. See
> [`../README.md`](../README.md#-lab_domain--the-ui-domain).

## 🎯 Purpose

- Give the lab a **real identity provider**: realms, users, groups, OIDC and SAML clients.
- Show a **CRD-driven deployment**: you declare *what you want* (`Keycloak`,
  `KeycloakRealmImport`), the operator derives the *how* and keeps reconciling it.
- Serve as the **upstream IdP** for anything that authenticates afterwards — starting with
  `kubectl` itself, through the Dex add-on.

> ℹ️ **Standalone add-on**: Keycloak is **not** installed by `../platform-up.sh` (which only lays
> down the CNI + Envoy Gateway + metrics-server + the wildcard TLS). It installs on demand, like
> `../longhorn/`, `../vault-cluster/`, `../argocd/`…

### The setup in one sentence

**Envoy terminates TLS, Keycloak speaks plaintext — and is told so.** `http.httpEnabled: true`
makes the pod listen on plain `8080`; `proxy.headers: xforwarded` makes Keycloak trust the
`X-Forwarded-*` headers Envoy sets; `hostname.hostname` pins the **public** URL. Miss the second
one and Keycloak builds its redirects from its internal name — the browser loops and OAuth
breaks. Miss the third and the `issuer` advertised in the discovery document does not match the
URL clients actually call, so every token is rejected.

### Why the operator and not a chart

A Helm chart hands you a StatefulSet and leaves you with the keystore, the proxy options, the
schema migration on every upgrade and the Infinispan cache. The operator takes a `Keycloak`
object and derives all of it. More importantly it gives you the thing that matters in a lab: a
**declared realm** you can version, therefore reproduce — and, for downstream components, an
OIDC client declared as a CR instead of a `kcadm.sh` script.

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| `main-gateway` with the **`https:443`** listener ([`../envoy-gateway/`](../envoy-gateway/README.md)) | carries the console and the OIDC endpoints over HTTPS | `kubectl get gateway -n envoy-gateway-system` |
| Wildcard cert `wildcard-lab-example-io-tls` **`READY=True`** ([`../cert-manager/`](../cert-manager/README.md) or [`../self-signed/`](../self-signed/README.md)) | otherwise TLS is untrusted, and OIDC clients refuse the issuer | `kubectl -n envoy-gateway-system get certificate` |
| StorageClass **`longhorn-r1`** ([`../longhorn/`](../longhorn/README.md)) | the PostgreSQL PVC | `kubectl get sc longhorn-r1` |
| **CloudNativePG** operator ([`../cloudnative-pg/`](../cloudnative-pg/README.md)) | reconciles the `keycloak-db` cluster | `kubectl get crd clusters.postgresql.cnpg.io` |
| DNS `keycloak.lab.example.io → 192.168.56.200` in **DNS-only** | hostname of the `HTTPRoute` | `curl --resolve` otherwise (see ✅) |
| `openssl` on the host | generates the demo user's password | `openssl version` |
| Nothing on the node side | no `hostPath`, no `hostNetwork`, no privilege | `kubectl -n keycloak get pods` |

## ⚡ Install

> 🎓 **Two paths, same result**: the all-in-one script below, or the **"Guided walkthrough"**
> section further down — the same commands, one at a time, for training.

Through the repository entry point:
```bash
./install.sh <distro> cnpg keycloak     # <distro> = talos | kubeadm
```

```bash
./keycloak/keycloak-up.sh <distro>
```

Keycloak **`26.7.0`** (operator **and** server: the operator manifests carry the server image),
pinned in the script via `KEYCLOAK_VERSION` (can be overridden). Idempotent (`kubectl apply`
everywhere; the demo password is generated only if its Secret is missing).

<details>
<summary>Manual equivalent</summary>

```bash
V=26.7.0
B=https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$V/kubernetes
kubectl create namespace keycloak
kubectl apply -f keycloak/01-postgres.yaml
kubectl -n keycloak wait --for=condition=Ready cluster/keycloak-db --timeout=300s
# --server-side is mandatory: the keycloaks CRD is larger than the 262 144-byte cap on the
# last-applied-configuration annotation that a client-side apply would write.
for c in keycloaks keycloakrealmimports keycloakoidcclients keycloaksamlclients; do
  kubectl apply --server-side -f "$B/$c.k8s.keycloak.org-v1.yml"
done
kubectl apply -n keycloak -f "$B/kubernetes.yml"
kubectl -n keycloak rollout status deploy/keycloak-operator
kubectl apply -f keycloak/02-keycloak.yaml            # after substituting the domain
kubectl -n keycloak create secret generic keycloak-demo-user \
  --from-literal=password="$(openssl rand -base64 18)"
kubectl apply -f keycloak/03-realm-lab.yaml
kubectl apply -f keycloak/httproute.yaml
```
</details>

## 🧬 Talos vs kubeadm

**No distribution-specific behaviour for this component.** Same manifests, same CRs, same
versions on both labs — and, unusually for this repository, **not even a `privileged` namespace
label**: the Keycloak and PostgreSQL pods use no `hostPath`, no `hostNetwork`, no privilege, so
they already satisfy the `baseline` PodSecurity level Talos enforces cluster-wide.

The distribution argument only drives two things here: the **default domain**
(`talos.lab.example.io` / `kubeadm.lab.example.io`) and **where the lab's `lab.env` /
`kubeconfig` live** (`../Vagrant-Talos/` or `../Vagrant-KubeADM/`).

> ℹ️ The one thing that *does* differ per lab is the **trust in the certificate**, and it only
> bites downstream. With `SELF_SIGNED=true` (the repo default) the issuer
> `https://keycloak.<LAB_DOMAIN>` is signed by the lab's local CA: a browser warns, and any OIDC
> client — including the Kubernetes apiserver — must be handed that CA explicitly. See
> [`../self-signed/README.md`](../self-signed/README.md).

## 🎓 Guided walkthrough (step by step)

> The commands below are **exactly** what the all-in-one script does, in order.
> Set up your shell first (once per session):
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig        # or ../Vagrant-KubeADM/kubeconfig
> export LAB_DOMAIN=talos.lab.example.io               # or your own (see the lab's lab.env)
> ```

### 1. The namespace and the database

Keycloak stores **everything** in the database — realms, clients, users, offline sessions.
Without one it starts from scratch on every pod restart.

```bash
kubectl create namespace keycloak
kubectl apply -f keycloak/01-postgres.yaml
kubectl -n keycloak wait --for=condition=Ready cluster/keycloak-db --timeout=300s
kubectl -n keycloak get secret keycloak-db-app -o jsonpath='{.data.username}' | base64 -d; echo
```

The `keycloak-db-app` Secret is produced by CloudNativePG, not by us: that is the whole point of
going through the operator rather than writing a `postgres:17` Deployment by hand.

### 2. The Keycloak operator

```bash
V=26.7.0
B=https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$V/kubernetes
for c in keycloaks keycloakrealmimports keycloakoidcclients keycloaksamlclients; do
  kubectl apply --server-side -f "$B/$c.k8s.keycloak.org-v1.yml"
done
kubectl apply -n keycloak -f "$B/kubernetes.yml"
kubectl -n keycloak rollout status deploy/keycloak-operator --timeout=300s
kubectl api-resources --api-group=k8s.keycloak.org
```

Two details worth knowing: the CRDs must go in with **`--server-side`** (the `keycloaks` one is
larger than the 262 144-byte annotation cap of a client-side apply), and the operator **must**
live in the `keycloak` namespace (its `ClusterRoleBinding` names that namespace in its subject).

### 3. The `Keycloak` CR — the whole deployment

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" keycloak/02-keycloak.yaml | kubectl apply -f -
kubectl -n keycloak get statefulset,svc          # created by the operator, not by you
kubectl -n keycloak wait --for=condition=Ready keycloak/keycloak --timeout=600s
```

First start takes a couple of minutes: Keycloak creates its schema. Watch it with
`kubectl -n keycloak logs -f keycloak-0`.

### 4. The `lab` realm, with no password in git

```bash
kubectl -n keycloak create secret generic keycloak-demo-user \
  --from-literal=password="$(openssl rand -base64 18)"
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" keycloak/03-realm-lab.yaml | kubectl apply -f -
kubectl -n keycloak wait --for=condition=Done keycloakrealmimport/lab --timeout=300s
kubectl -n keycloak get jobs                     # the import job, run once
```

`spec.placeholders` exposes the Secret key as an environment variable of the import job, and
Keycloak substitutes `${DEMO_PASSWORD}` while importing. The repository is public: **no
credential is ever versioned.**

### 5. The route, and the discovery document

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" keycloak/httproute.yaml | kubectl apply -f -
curl -sk "https://keycloak.${LAB_DOMAIN}/realms/lab/.well-known/openid-configuration" | jq .issuer
```

The `issuer` must read exactly `https://keycloak.<LAB_DOMAIN>/realms/lab`. If it shows an
internal name instead, `proxy.headers` or `hostname.hostname` is wrong — see 🚑 below.

## 🔧 What the script does

1. creates the `keycloak` namespace and the CloudNativePG `keycloak-db` cluster, then waits for
   it to be `Ready`;
2. applies the four CRDs (`--server-side`) and the operator, in the `keycloak` namespace;
3. applies the `Keycloak` CR with the domain substituted, and waits for `condition=Ready`;
4. generates the demo password **only if its Secret is missing**, then applies the realm import;
5. applies the `HTTPRoute` and prints the URLs and the commands that read the credentials.

### Files

| File | Purpose |
|---|---|
| `01-postgres.yaml` | CloudNativePG `Cluster` `keycloak-db` — 1 instance, 2Gi on `longhorn-r1`, database and owner `keycloak` |
| `02-keycloak.yaml` | the `Keycloak` CR: database, `httpEnabled`, `proxy.headers: xforwarded`, public hostname, operator Ingress disabled |
| `03-realm-lab.yaml` | `KeycloakRealmImport`: realm `lab`, groups `k8s-admins` / `k8s-viewers`, `groups` client scope, the `demo` and `viewer` users whose passwords come from Secrets |
| `httproute.yaml` | HTTPS `HTTPRoute` `keycloak.lab.example.io` → `keycloak-service:8080`, `sectionName: https` |
| `keycloak-up.sh` | the all-in-one install (idempotent) |

## ✅ Verify

```bash
kubectl -n keycloak get keycloak,keycloakrealmimport      # Ready=True, Done=True
kubectl -n keycloak get pods                              # keycloak-0, keycloak-db-1, operator
kubectl -n keycloak get httproute keycloak                # Accepted + ResolvedRefs = True
# end-to-end test, TLS served by Envoy:
curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  --resolve keycloak.lab.example.io:443:192.168.56.200 \
  https://keycloak.lab.example.io/realms/lab            # expected: 200 verify=0
```

`--resolve` bypasses DNS: handy for testing **before** you create the record.
`verify=0` only holds with a publicly trusted certificate; with `SELF_SIGNED=true`, add `-k` or
pass the lab CA with `--cacert`.

## 🌐 Access

| What | Value |
|---|---|
| Admin console | `https://keycloak.lab.example.io/admin/` |
| Bootstrap admin | `kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.username}' \| base64 -d ; echo` |
| Its password | `kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.password}' \| base64 -d ; echo` |
| Realm | `lab` — `https://keycloak.lab.example.io/realms/lab` |
| Discovery | `https://keycloak.lab.example.io/realms/lab/.well-known/openid-configuration` |
| Demo user | `demo`, member of `k8s-admins` |
| Its password | `kubectl -n keycloak get secret keycloak-demo-user -o jsonpath='{.data.password}' \| base64 -d ; echo` |
| View-only user | `viewer`, member of `k8s-viewers` |
| Its password | `kubectl -n keycloak get secret keycloak-viewer-user -o jsonpath='{.data.password}' \| base64 -d ; echo` |

> 💡 Create your own admin in the `master` realm, then **delete the bootstrap Secret**:
> `kubectl -n keycloak delete secret keycloak-initial-admin`.

## 🧪 Scenario — the realm survives its cluster

The point of a declared realm is that it comes back. Destroy it and let the operator rebuild it:

```bash
# 1. Note what exists
kubectl -n keycloak get keycloakrealmimport lab -o jsonpath='{.status.conditions}' | jq

# 2. Blow the whole deployment away — CR only, the database survives
kubectl -n keycloak delete keycloak keycloak
kubectl -n keycloak get pods -w            # the operator rebuilds the StatefulSet

# 3. Re-apply: same URL, same realm, same users — the state was in PostgreSQL all along
kubectl apply -f keycloak/02-keycloak.yaml
curl -sk https://keycloak.lab.example.io/realms/lab | jq .realm
```

Now the other direction — a genuinely empty database:

```bash
kubectl -n keycloak delete keycloakrealmimport lab
kubectl -n keycloak delete cluster keycloak-db          # ⚠️ destroys the data
./keycloak/keycloak-up.sh <distro>                      # everything comes back from the files
```

Second run, the `demo` password is **the same**: the script does not regenerate a Secret that
already exists.

## 🚑 Troubleshooting

- **`issuer` shows an internal name, or the browser loops on login** → `proxy.headers` is not
  `xforwarded`, or `hostname.hostname` does not match the `HTTPRoute` hostname:
  `kubectl -n keycloak get keycloak keycloak -o jsonpath='{.spec.hostname}{"\n"}{.spec.proxy}'`.
- **`metadata.annotations: Too long` while applying a CRD** → you used a client-side apply. The
  `keycloaks` CRD is over 500 KiB; use `kubectl apply --server-side`.
- **The operator starts but reconciles nothing** → it is not in the `keycloak` namespace, so its
  `ClusterRoleBinding` (which names that namespace explicitly) grants it nothing:
  `kubectl -n keycloak logs deploy/keycloak-operator`.
- **`keycloak-0` in `CrashLoopBackOff` at first start** → almost always the database. Check
  `kubectl -n keycloak get cluster keycloak-db` and the credentials in `keycloak-db-app`. An
  OOMKill during the Liquibase migration looks the same: raise `spec.resources.limits.memory`.
- **The realm import job never finishes** → `kubectl -n keycloak get keycloakrealmimport lab -o yaml`
  then the job's logs. A missing placeholder Secret fails the import with an obscure message.
- **You edited `03-realm-lab.yaml` and nothing changed** → expected. The import does **not**
  overwrite an existing realm. Delete the CR *and* the realm, then re-apply.
- **`404` on the route** → `kubectl -n keycloak describe httproute keycloak`; `sectionName: https`
  must exist on `main-gateway` and the hostname must match the wildcard.

## ⚠️ Pitfalls

- **`proxy.headers: xforwarded` is only safe behind a proxy you control.** It makes Keycloak
  trust `X-Forwarded-Host`. If the Service were reachable directly, anyone could poison the
  links in password-reset emails. Keep it a `ClusterIP` behind the Gateway.
- **`keycloak-initial-admin` is a full admin credential in plaintext** for as long as you keep
  it: readable by anything holding `get secrets` in the namespace.
- **The IdP is published on the VIP**: every authorized Tailscale peer can reach the login page.
  Brute-force protection is on in the realm, but a real password is still mandatory.
- **The realm import is one-shot.** It documents the *initial* state, not the current one. Any
  change made in the console drifts silently from this file — this is not GitOps.
- **Destroying the `keycloak-db` cluster destroys every identity.** The `Keycloak` CR holds no
  state; PostgreSQL holds all of it, and this lab takes no backup of it (see
  [`../cloudnative-pg/`](../cloudnative-pg/README.md) for S3 backups + PITR).
- **Stacking this component on control planes that are too tight on RAM** ends up starving etcd:
  Keycloak asks for 768 MiB and peaks higher on first start. `lab.env` (`WK_MEM`) is the knob.

## 📚 References

- [Keycloak Operator — installation](https://www.keycloak.org/operator/installation)
- [Keycloak Operator — advanced configuration (`proxy`, `hostname`, `db`)](https://www.keycloak.org/operator/advanced-configuration)
- [Keycloak Operator — realm import](https://www.keycloak.org/operator/realm-import)
- [Keycloak — reverse proxy configuration](https://www.keycloak.org/server/reverseproxy)
- [`keycloak-k8s-resources` — releases](https://github.com/keycloak/keycloak-k8s-resources/tags)
- [`../cloudnative-pg/README.md`](../cloudnative-pg/README.md) — the operator behind the database
- [`../envoy-gateway/README.md`](../envoy-gateway/README.md) — the Gateway that carries this route
