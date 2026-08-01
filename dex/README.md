<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🪪 `dex/` — Dex in front of Keycloak: `kubectl` login without a single certificate

> **The lab's `kubeconfig` stops being a credential.** Dex publishes itself at
> `dex.lab.example.io` as the one OIDC issuer the Kubernetes apiserver trusts, and goes
> looking for the actual identity in the Keycloak `lab` realm. `kubectl` then logs in through
> a browser (`kubectl oidc-login`), and your rights come from a **Keycloak group**, not from a
> client certificate copied around.

> 🌐 **`lab.example.io` is the repo's NEUTRAL domain (public)**: `dex-up.sh` swaps it for
> `LAB_DOMAIN` (`lab.env`) in the Dex values, the Keycloak client and the `HTTPRoute`. See
> [`../README.md`](../README.md#-lab_domain--the-ui-domain).

## 🎯 Purpose

- Show the **only authentication mechanism Kubernetes offers that scales**: OIDC. No user
  database in the cluster, no certificate to revoke, no `kubeconfig` to hand out.
- Demonstrate that authorisation follows a **group**: put a user in `k8s-admins` in Keycloak,
  and `cluster-admin` follows — remove them and it is gone at the next token.
- Explain, on a live cluster, why the API server is the **hardest** part of this chain to
  change, and how that plays out very differently on Talos and on kubeadm.

> ℹ️ **Standalone add-on**, and it needs [`../keycloak/`](../keycloak/README.md) first: it uses
> the `lab` realm, its `groups` client scope and its `demo` user.

### Why Dex when Keycloak already speaks OIDC

Because the apiserver only knows **one** issuer, frozen on its command line, and changing that
value restarts the control plane. Dex is the indirection: the apiserver only ever knows
`https://dex.lab.example.io`, and everything that moves — adding a second directory, switching
realm, rotating a client secret — happens in Dex's config, never on the control plane. That is
exactly what a managed cluster does behind its SSO.

### The setup in one sentence

**Three URLs must match, character for character**: `config.issuer` in `values.yaml`, the
`hostnames:` of the `HTTPRoute`, and `--oidc-issuer-url` on the apiserver. That string is signed
into every token; a trailing slash is enough to have every token rejected with
`oidc: id token issued by a different provider`.

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| [`../keycloak/`](../keycloak/README.md) installed, realm `lab` | the upstream directory, its groups and its `groups` scope | `kubectl -n keycloak get keycloak,keycloakrealmimport` |
| `main-gateway` with the **`https:443`** listener ([`../envoy-gateway/`](../envoy-gateway/README.md)) | publishes the issuer over HTTPS | `kubectl get gateway -n envoy-gateway-system` |
| Wildcard cert `wildcard-lab-example-io-tls` **`READY=True`** | the apiserver **refuses** an issuer it cannot verify | `kubectl -n envoy-gateway-system get certificate` |
| DNS `dex.lab.example.io → 192.168.56.200` in **DNS-only** | resolved by the apiserver **and** by your browser | `kubectl get gateway -n envoy-gateway-system` |
| **kubelogin** (`kubectl oidc-login`) on the host | drives the browser flow and caches the token | `kubectl oidc-login --version` |
| Access to the control planes | wiring the apiserver is **not** done from the API | `talosctl version` / `vagrant status` |
| Nothing on the node side for Dex itself | no `hostPath`, no privilege | `kubectl -n dex get pods` |

Installing kubelogin:

```bash
kubectl krew install oidc-login          # or: brew install int128/kubelogin/kubelogin
kubectl oidc-login --version             # pinned reference for this lab: v1.36.3
```

## ⚡ Install

> 🎓 **Two paths, same result**: the all-in-one script below, or the **"Guided walkthrough"**
> section further down — the same commands, one at a time, for training.

Through the repository entry point:
```bash
./install.sh <distro> keycloak dex      # <distro> = talos | kubeadm
```

```bash
./dex/dex-up.sh <distro>
```

Chart `dex/dex` **`0.24.1`** (app **v2.44.0**), pinned in the script via `DEX_VERSION` (can be
overridden). Idempotent — with one deliberate exception: the client secrets are generated
**only if missing**, because regenerating them would silently invalidate the client the Keycloak
operator has already created.

> ⚠️ **The script does not touch the API server.** Wiring it to Dex restarts the control plane,
> and an unreachable issuer stops it from restarting at all. An add-on has no business doing
> that quietly. The script prints the exact commands for your distribution instead — see
> [Wiring the API server](#-wiring-the-api-server).

<details>
<summary>Manual equivalent</summary>

```bash
kubectl create namespace dex
S=$(openssl rand -hex 32)
kubectl -n keycloak create secret generic dex-keycloak-client --from-literal=client-secret="$S"
kubectl -n dex      create secret generic dex-keycloak-client --from-literal=client-secret="$S"
kubectl -n dex create secret generic dex-kubernetes-client \
  --from-literal=client-secret="$(openssl rand -hex 32)"
kubectl apply -f dex/01-keycloak-client.yaml           # after substituting the domain
helm repo add dex https://charts.dexidp.io && helm repo update dex
helm upgrade --install dex dex/dex -n dex --version 0.24.1 --values dex/values.yaml
kubectl apply -f dex/httproute.yaml
kubectl apply -f dex/rbac.yaml
```
</details>

## 🧬 Talos vs kubeadm

**This is the component where the two labs diverge the most** — and the divergence is not in
Dex, which is identical on both. It is in the **one thing this repository does not own**: the
Kubernetes API server.

| | Talos | Debian 13 + kubeadm |
|---|---|---|
| What the apiserver *is* | a static pod whose manifest Talos **generates** from the machine configuration | a static pod whose manifest lives on disk, generated by `kubeadm` |
| How you change its flags | `talosctl patch mc` — **the configuration is an API** | edit the `kubeadm-config` ConfigMap, then re-run `kubeadm init phase` **on each node** |
| Access needed | none beyond `talosctl`: no SSH exists on Talos | a shell on every control plane (`vagrant ssh k8s-cpN`) |
| Shape of `extraArgs` | a **map** (`key: value`), Talos `v1alpha1` | a **list** of `{name, value}`, kubeadm `v1beta4` (Kubernetes ≥ 1.31) |
| Restart | Talos rewrites the manifest and restarts the apiserver itself | `kubeadm` rewrites the manifest, the kubelet notices and restarts the pod |
| Where the OIDC CA goes (`SELF_SIGNED=true`) | a `machine.files` entry **plus** a `cluster.apiServer.extraVolumes` mount: `/` is read-only and the static pod sees nothing you have not mounted | a plain `cp` into `/etc/kubernetes/pki/`, **already mounted** into the pod — nothing else to declare |
| Profile variables | `APISERVER_OIDC_PATCH`, `APISERVER_OIDC_MECHANISM`, `apiserver_oidc_commands()` | same three, other values |
| Patch shipped here | [`apiserver-oidc.talos.yaml`](apiserver-oidc.talos.yaml) | [`apiserver-oidc.kubeadm.yaml`](apiserver-oidc.kubeadm.yaml) |

Everything else — the Dex chart, the Keycloak client CR, the `HTTPRoute`, the RBAC bindings — is
byte-for-byte identical on both labs.

## 🎓 Guided walkthrough (step by step)

> The commands below are **exactly** what the all-in-one script does, in order.
> Set up your shell first (once per session):
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig        # or ../Vagrant-KubeADM/kubeconfig
> export LAB_DOMAIN=talos.lab.example.io               # or your own (see the lab's lab.env)
> ```

### 1. The namespace and the two client secrets

The `dex` client secret has to exist in **two** namespaces: Keycloak reads it in `keycloak` (the
`KeycloakOIDCClient` CR lives there), Dex reads it in `dex`. Secrets do not cross namespaces.

```bash
kubectl create namespace dex
S=$(openssl rand -hex 32)
kubectl -n keycloak create secret generic dex-keycloak-client --from-literal=client-secret="$S"
kubectl -n dex      create secret generic dex-keycloak-client --from-literal=client-secret="$S"
kubectl -n dex create secret generic dex-kubernetes-client \
  --from-literal=client-secret="$(openssl rand -hex 32)"
```

### 2. The Keycloak client, declared

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" dex/01-keycloak-client.yaml | kubectl apply -f -
kubectl -n keycloak get keycloakoidcclient dex -o jsonpath='{.status.conditions}' | jq
```

There is no `clientId` field in that CRD: `metadata.name` **is** the client id, and it has to
match `clientID: dex` in the Dex connector.

### 3. Dex itself

```bash
helm repo add dex https://charts.dexidp.io && helm repo update dex
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" dex/values.yaml > /tmp/dex-values.yaml
helm upgrade --install dex dex/dex -n dex --version 0.24.1 --values /tmp/dex-values.yaml
kubectl -n dex rollout status deploy/dex --timeout=300s
kubectl -n dex logs deploy/dex | head -20        # "config using connector: keycloak"
```

### 4. The route and the RBAC bindings

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" dex/httproute.yaml | kubectl apply -f -
kubectl apply -f dex/rbac.yaml
curl -sk "https://dex.${LAB_DOMAIN}/.well-known/openid-configuration" | jq '.issuer, .jwks_uri'
```

The `issuer` must read exactly `https://dex.<LAB_DOMAIN>` — no trailing slash.

### 5. Wiring the API server

See the dedicated section below: this is the step the script refuses to run for you.

### 6. The `kubectl` context

```bash
CTX=$(kubectl config current-context)
CLUSTER=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CTX\")].context.cluster}")
kubectl config set-credentials oidc \
  --exec-api-version=client.authentication.k8s.io/v1beta1 \
  --exec-command=kubectl \
  --exec-arg=oidc-login --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://dex.${LAB_DOMAIN} \
  --exec-arg=--oidc-client-id=kubernetes \
  --exec-arg=--oidc-client-secret=$(kubectl -n dex get secret dex-kubernetes-client \
      -o jsonpath='{.data.client-secret}' | base64 -d) \
  --exec-arg=--oidc-extra-scope=groups --exec-arg=--oidc-extra-scope=email
kubectl config set-context oidc --cluster="$CLUSTER" --user=oidc
kubectl --context=oidc get nodes
```

That last command opens a browser: Dex offers the `Keycloak` connector, Keycloak asks for
`demo` and its password, and `kubectl` comes back with a token. Nothing was copied, nothing was
signed by hand.

> 💡 With `SELF_SIGNED=true`, add `--exec-arg=--certificate-authority=<path to the lab CA>`
> so kubelogin trusts `dex.<LAB_DOMAIN>` too. `--insecure-skip-tls-verify` works, and teaches
> the wrong reflex.

## 🔐 Wiring the API server

This is the only step of the repository that **changes the control plane**, so it is the only
one left in your hands. Read this before running anything:

- It **adds** an authenticator, it removes none. The lab's `kubeconfig` and every component's
  client certificate keep working — which is what makes the operation reversible.
- A wrong `--oidc-issuer-url` (unreachable, or with an untrusted certificate) **stops the
  apiserver from starting**. Do one control plane at a time and check
  `kubectl get --raw=/readyz` in between; as long as one control plane is healthy the cluster
  stays administrable.
- To roll back: remove the flags the same way you added them.

### Talos

```bash
for ip in $(kubectl get nodes -l node-role.kubernetes.io/control-plane \
              -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}'); do
  talosctl -n "$ip" patch mc --patch @dex/apiserver-oidc.talos.yaml
  kubectl get --raw=/readyz && echo
done
```

<details>
<summary><code>SELF_SIGNED=true</code>: also hand the apiserver the lab CA</summary>

`/` is read-only on Talos and the static pod sees only what you mount. Two additions therefore:
the file, and the volume that exposes it.

```bash
CA=$(sed 's/^/          /' ../Vagrant-Talos/_out/self-signed/ca.crt)   # indent the PEM
cat > /tmp/oidc-ca.talos.yaml <<EOF
machine:
  files:
    - path: /var/lib/oidc/ca.crt
      permissions: 0o644
      op: create
      content: |
$CA
cluster:
  apiServer:
    extraArgs:
      oidc-ca-file: /etc/kubernetes/oidc/ca.crt
    extraVolumes:
      - hostPath: /var/lib/oidc
        mountPath: /etc/kubernetes/oidc
        readonly: true
EOF
talosctl -n <control-plane IP> patch mc --patch @/tmp/oidc-ca.talos.yaml
```

`op: create` refuses to overwrite: on a second run, use `overwrite`.
</details>

### kubeadm

The apiserver manifest is a file on each control plane, regenerated by `kubeadm` from the
`kubeadm-config` ConfigMap. Editing the manifest directly works — until the next
`kubeadm upgrade` silently overwrites it. So the ConfigMap is the source of truth:

```bash
# 1. merge the apiServer block of dex/apiserver-oidc.kubeadm.yaml into ClusterConfiguration
kubectl -n kube-system edit configmap kubeadm-config

# 2. on EACH control plane, regenerate the static pod manifest from that ConfigMap
vagrant ssh k8s-cp1 -c '
  kubectl -n kube-system get cm kubeadm-config -o jsonpath="{.data.ClusterConfiguration}" \
    | sudo tee /tmp/kubeadm.yaml >/dev/null
  sudo kubeadm init phase control-plane apiserver --config /tmp/kubeadm.yaml'
kubectl get --raw=/readyz && echo
```

<details>
<summary><code>SELF_SIGNED=true</code>: also hand the apiserver the lab CA</summary>

`/etc/kubernetes/pki` is **already** mounted into the static pod, so the file is all it takes:

```bash
vagrant ssh k8s-cp1 -c 'sudo tee /etc/kubernetes/pki/oidc-ca.crt >/dev/null' \
  < ../Vagrant-KubeADM/_out/self-signed/ca.crt
# then add to the ConfigMap, alongside the other flags:
#   - name: oidc-ca-file
#     value: /etc/kubernetes/pki/oidc-ca.crt
```
</details>

> 💡 The simplest path is to have no CA problem at all: with `SELF_SIGNED=false` the wildcard is
> issued by Let's Encrypt, publicly trusted, and neither the apiserver nor kubelogin needs
> anything. See [`../cert-manager/README.md`](../cert-manager/README.md).

## 🔧 What the script does

1. creates the `dex` namespace and the two client secrets — generating them **only if missing**;
2. applies the `KeycloakOIDCClient` CR with the domain substituted, and waits for `Ready`;
3. installs the Dex chart with the rendered values, and waits for the rollout;
4. applies the `HTTPRoute` and the two `ClusterRoleBinding`s;
5. prints the API-server wiring commands for the detected distribution, then the `kubectl`
   context — it runs neither.

### Files

| File | Purpose |
|---|---|
| `01-keycloak-client.yaml` | `KeycloakOIDCClient`: the `dex` client in the `lab` realm, `STANDARD` flow only, one exact redirect URI |
| `values.yaml` | Dex: public issuer, Kubernetes storage, `oidc` connector to the realm, `kubernetes` static client; both secrets come from environment variables |
| `httproute.yaml` | HTTPS `HTTPRoute` `dex.lab.example.io` → `dex:5556`, `sectionName: https` |
| `rbac.yaml` | `oidc:k8s-admins` → `cluster-admin`, `oidc:k8s-viewers` → `view` |
| `apiserver-oidc.talos.yaml` | Talos machine-config patch (`talosctl patch mc`) |
| `apiserver-oidc.kubeadm.yaml` | `ClusterConfiguration` fragment to merge into `kubeadm-config` |
| `dex-up.sh` | the all-in-one install (idempotent), minus the control-plane change |

## ✅ Verify

```bash
kubectl -n dex get pods,httproute                       # dex Running, route Accepted
kubectl -n keycloak get keycloakoidcclient dex          # Ready=True
curl -sk https://dex.lab.example.io/.well-known/openid-configuration | jq .issuer

# the apiserver really sees the flags (Talos and kubeadm alike):
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep oidc

# the whole chain, in one command:
kubectl --context=oidc auth whoami                      # oidc:demo@lab.example.io, oidc:k8s-admins
kubectl --context=oidc auth can-i '*' '*' --all-namespaces   # yes
```

## 🧪 Scenario — authorisation lives in Keycloak, not in the cluster

```bash
# 1. demo is in k8s-admins: full rights
kubectl --context=oidc auth can-i delete nodes                  # yes

# 2. In the Keycloak console (https://keycloak.<LAB_DOMAIN>/admin/), realm `lab`:
#    Users -> demo -> Groups -> leave k8s-admins, join k8s-viewers

# 3. Force a new token — the old one is cached and still valid until it expires
rm -rf ~/.kube/cache/oidc-login
kubectl --context=oidc auth whoami                              # oidc:k8s-viewers
kubectl --context=oidc auth can-i delete nodes                  # no
kubectl --context=oidc get pods -A                              # still works: `view`
```

Not one `kubectl` command was needed to change those rights, and nothing was revoked in the
cluster. That is the whole point — and the cache is also the whole caveat: **a token already
issued keeps its groups until it expires.** OIDC de-provisioning is never instant.

## 🚑 Troubleshooting

- **`oidc: id token issued by a different provider`** → the three URLs disagree. Compare
  `config.issuer` (`kubectl -n dex get secret dex -o jsonpath='{.data.config\.yaml}' | base64 -d`),
  the `HTTPRoute` hostname, and `--oidc-issuer-url` on the apiserver. A trailing `/` is enough.
- **The apiserver will not restart after the patch** → almost always the issuer: unreachable, or
  a certificate it does not trust. On Talos, `talosctl -n <ip> logs kubelet`; on kubeadm,
  `sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1)`. Undo the flags.
- **Login works but every command is `Forbidden`** → the groups are missing from the token.
  Check in order: the `groups` scope requested by Dex (`values.yaml`), `insecureEnableGroups:
  true` on the connector, the `groups` client scope in the realm
  ([`../keycloak/`](../keycloak/README.md)), and the `oidc:` prefix in `rbac.yaml`.
- **`kubectl auth whoami` shows the right user but no group** → same causes, and check that the
  Keycloak client really was assigned the `groups` scope: the realm assigns it to **new**
  clients (`defaultDefaultClientScopes`); a client created before that setting does not have it.
- **The browser never comes back / `redirect_uri_mismatch`** → kubelogin listens on `:8000`.
  The URI must appear in both `staticClients[].redirectURIs` (Dex) and the Keycloak client's
  `redirectUris` — the latter only lists `https://dex.<LAB_DOMAIN>/callback`, which is Dex's own
  callback, not kubectl's.
- **`x509: certificate signed by unknown authority`** → `SELF_SIGNED=true` and someone in the
  chain lacks the lab CA: the apiserver (`oidc-ca-file`), kubelogin
  (`--certificate-authority`), or Dex when it calls Keycloak.
- **The Dex pod restarts in a loop** → `kubectl -n dex logs deploy/dex`. A missing secret, or an
  unexpanded `$KEYCLOAK_CLIENT_SECRET`, shows up as a connector failing to start.

## ⚠️ Pitfalls

- **`cluster-admin` is granted to a group, so anyone Keycloak puts in it is cluster admin.** The
  IdP is now part of the cluster's trust boundary; whoever administers the realm administers
  Kubernetes.
- **Revocation is not immediate.** A token already handed out stays valid until it expires,
  whatever you change in Keycloak. Kubernetes does not check anything on the IdP side per
  request.
- **The `oidc:` prefix is load-bearing.** Drop it and a directory that declares a
  `system:masters` group takes over the cluster. If you change it, change `rbac.yaml` too.
- **Never remove the certificate authenticators.** OIDC adds itself to them; a cluster whose
  only door is an IdP is a cluster you cannot get back into when the IdP is down — and here the
  IdP runs *inside* that cluster.
- **`insecureEnableGroups` is badly named but required**: without it, Dex's generic OIDC
  connector drops upstream groups on the floor and nothing says so.
- **The client secrets are generated once.** Re-running the script does not rotate them, on
  purpose: regenerating the `dex` secret on one side only would break the client with no error
  in sight. Rotate deliberately — both namespaces, then restart Dex.
- **Editing `/etc/kubernetes/manifests/kube-apiserver.yaml` by hand on kubeadm** survives until
  the next `kubeadm upgrade`, which regenerates it from `kubeadm-config`.

## 📚 References

- [Kubernetes — OpenID Connect tokens](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#openid-connect-tokens)
- [Dex — OIDC connector](https://dexidp.io/docs/connectors/oidc/)
- [Dex — Kubernetes storage backend](https://dexidp.io/docs/storage/#kubernetes-custom-resource-definitions-crds)
- [kubelogin (`kubectl oidc-login`)](https://github.com/int128/kubelogin)
- [Talos — `cluster.apiServer.extraArgs` / `extraVolumes`](https://docs.siderolabs.com/talos/v1.11/reference/configuration/v1alpha1/config)
- [kubeadm — `ClusterConfiguration` v1beta4](https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/)
- [`../keycloak/README.md`](../keycloak/README.md) — the realm, the groups and the `groups` scope
- [`../envoy-gateway/README.md`](../envoy-gateway/README.md) — the Gateway that carries this route
