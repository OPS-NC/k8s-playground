<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# ⚙️ `vault/` — the configuration **on the Vault side**

> The server half of the VSO wiring. These scripts create everything the VSO is going to
> **consume**: the Kubernetes auth method, the secrets engines, the policies (least privilege) and
> the roles that tie a K8s identity to a policy. The cluster-side counterpart is in `../k8s/`.

## 🎯 The identity contract

VSO presents the **JWT token** of the app's `ServiceAccount`. Vault validates it through the
cluster's **TokenReview** API, then checks that it matches a **role**
(`bound_service_account_names` + `_namespaces` + `audience`). If it does, Vault returns a token
carrying the role's **policies** — so precise read rights, and nothing else.

```
SA JWT (audience "vault")     ─►  auth/kubernetes/config (TokenReview)  ─►  role  ─►  policy
                                                                                       │
                                    kvv2/ · database/ · pki/ · transit/  ◄─────────────┘
```

Break a single link (SA name, namespace, audience, policy path, mount name) and you get a `403` on
the VSO side and a `SecretSynced: false` on the CR. That is the overwhelming majority of failures.

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| `vault` CLI on the host | every script calls it | `vault version` |
| `VAULT_ADDR` **exported** | otherwise the CLI hits `https://127.0.0.1:8200` | `echo $VAULT_ADDR` |
| `VAULT_TOKEN` **exported** (root/admin) | enabling engines and writing policies | `vault token lookup` |
| Vault **unsealed** | a sealed Vault refuses everything | `vault status` → `Sealed false` |
| `KUBECONFIG` (only for `pg-dynamic-rotate.sh`) | reads the CNPG superuser password | `kubectl get nodes` |

```bash
export VAULT_ADDR="https://vault.lab.example.io"   # or http://127.0.0.1:8200 via port-forward
export VAULT_TOKEN="<root-token>"                    # see ../../vault-cluster/README.md
vault status                                         # must answer Sealed=false
```

Port-forward if Vault is not exposed:
`kubectl -n vault port-forward svc/vault-active 8200:8200`.

> ⚠️ **`VAULT_ADDR`/`VAULT_TOKEN` set in `lab.env` have NO effect**: no script reads that file. You
> have to **export** them (or `set -a; . ./lab.env; set +a`). Details and precautions in
> `../../vault-cluster/README.md` (Pitfalls section).

## ⚡ Two paths

> 🎓 **Two paths, same result**: the all-in-one script below, or the **"Guided
> walkthrough"** section further down — the same commands, one at a time, for training.

The directory holds **two sets of scripts** that do not serve the same purpose. Do not mix them:
they use different mounts, namespaces and role names.

### Path A — the real lab (tested)

```bash
./vault-secret-operator/vault/lab-kv.sh          # k8s auth + lab-kv/ engine + demo
./vault-secret-operator/vault/pg-dynamic-rotate.sh  # database/ engine + PG rotation
```

This is the path that actually runs: KV-v2 mount **`lab-kv/`** (one subdirectory per app) and
rotation of a PostgreSQL password through a static role. The matching K8s demos are
`../k8s/nginx-test-vault/` and `../k8s/pg-dynamic-rotate/`.

### Path B — the teaching demo (mounts `kvv2/`, `pki/`, `transit/`)

```bash
cd vault-secret-operator/vault
bash 00-secrets-engines.sh                 # engines + a demo secret + PKI CA + transit key
MODE=incluster bash 01-kubernetes-auth.sh   # auth/kubernetes (see the pitfall below!)
bash 02-roles.sh                            # policies + roles vso-static/-dynamic/-pki/-transit
```

It serves as reading material for the numbered CRs in `../k8s/` (`10-`, `20-`, `30-`, `40-`). Two
of its three scripts have flaws documented under ⚠️ **Pitfalls** — read them first.

## 🧬 Talos vs kubeadm

One difference only, and it is **cosmetic by choice**: the name of the demo KV-v2 mount, so both
labs can coexist inside a single Vault.

| | Talos | kubeadm |
|---|---|---|
| KV-v2 mount (`VAULT_KV_MOUNT`) | `talos-lab/` | `kubeadm-lab/` |
| Derived policy | `talos-lab-nginx-test-vault` | `kubeadm-lab-nginx-test-vault` |

Versioned files carry the **NEUTRAL marker `lab-kv`**; it is substituted on the fly, exactly
like the domain (the `render` helper in `lib/common.sh`, and a `sed` in `vault/lab-kv.sh`).
Everything else — VSO, VaultConnection, VaultAuth, the `vso-*` policies, PostgreSQL rotation,
PKI — is identical on both distributions.

## 🎓 Guided walkthrough (step by step)

> The commands below are **exactly** what the all-in-one script does, in order.
> Set up your shell first (once per session):
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig        # or ../Vagrant-KubeADM/kubeconfig
> export LAB_DOMAIN=talos.lab.example.io               # or your own (see the lab's lab.env)
> ```

### 0. The environment (the scripts refuse to run without it)

```bash
export VAULT_ADDR="https://vault.${LAB_DOMAIN}"      # or: kubectl -n vault port-forward svc/vault-active 8200:8200
export VAULT_TOKEN=$(jq -r .root_token ../Vagrant-Talos/_out/vault-init.json)
vault status
```

### 1. The secret engines

```bash
./00-secrets-engines.sh <distro>
# manual equivalent:
vault secrets enable -path=kvv2 -version=2 kv
vault secrets enable database
vault secrets enable pki
vault secrets enable transit
vault secrets list
```

### 2. Kubernetes authentication (in-cluster mode)

Vault runs INSIDE the cluster: it validates SA tokens with its own delegator SA, without
`token_reviewer_jwt` or `kubernetes_ca_cert`.

```bash
./01-kubernetes-auth.sh <distro>
# manual equivalent:
vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc"
vault read auth/kubernetes/config
```

### 3. Policies and roles (least privilege)

```bash
./02-roles.sh <distro>
vault policy list
vault read auth/kubernetes/role/vso-static
```

### 4. The lab mount + the demo secret

The mount name depends on the distribution (`talos-lab/` or `kubeadm-lab/`): versioned files
carry `lab-kv`, which the script substitutes.

```bash
./lab-kv.sh <distro>
vault kv get talos-lab/nginx-test-vault/config          # or kubeadm-lab/…
vault read auth/kubernetes/role/nginx-test-vault
```

### 5. (Optional) PostgreSQL password rotation

```bash
./pg-dynamic-rotate.sh <distro>
vault read database/static-creds/vault-rotate            # the password rotates, the user does not
```

## 🔧 What each script writes into Vault

### `00-secrets-engines.sh` — the secrets engines

| Vault object | Command | Note |
|---|---|---|
| `kvv2/` | `vault secrets enable -path=kvv2 -version=2 kv` | static secrets |
| `kvv2/demo/app` | `vault kv put … username password` | demo secret, **overwritten on every run** |
| `database/` | `vault secrets enable database` | ⚠️ mounted on **`database/`**, not `db/` — see Pitfalls |
| `pki/` | `enable -path=pki pki` + `secrets tune -max-lease-ttl=87600h` | 10 years of max lease |
| PKI root CA | `vault write pki/root/generate/internal common_name=$LAB_DOMAIN ttl=87600h` | `LAB_DOMAIN` (lab.env, default `lab.example.io`); ⚠️ **stacks** one CA per run — see Pitfalls |
| `pki/config/urls` | `issuing_certificates` + `crl_distribution_points` on `$VAULT_ADDR` | depends on `VAULT_ADDR` |
| `pki/roles/demo` | `allowed_domains=$LAB_DOMAIN allow_subdomains=true max_ttl=72h` RSA 2048 | bounds what the `VaultPKISecret` may request — the CN of `30-pki-tls.yaml` must stay inside it |
| `transit/` + key `vso-client-cache` | `enable transit` ; `write -f transit/keys/vso-client-cache` | encryption of the VSO client cache |

The connection and the role of the `database` engine are left **commented out** in the script (they
depend on your database). Path A, on the other hand, writes them for real
(`pg-dynamic-rotate.sh`).

### `01-kubernetes-auth.sh` — the auth method

Two modes, depending on where Vault runs. This is the step that blocks people the most.

**`MODE=incluster`** (our case) — Vault calls TokenReview with the token of **its own pod**: its
`ServiceAccount` must carry the `system:auth-delegator` ClusterRole, which the `hashicorp/vault`
chart does by default (`server.authDelegator.enabled=true`). The config then boils down to
`kubernetes_host`; `token_reviewer_jwt` and `kubernetes_ca_cert` stay empty (Vault uses the CA
mounted in its container). No `issuer=` is set: `disable_iss_validation` stays `true` (the
default since Vault 1.9), so the token's `iss` claim is never compared — which is what you want
here, since kubeadm mints ServiceAccount tokens with the issuer
`https://kubernetes.default.svc.cluster.local` while `kubernetes_host` is
`https://kubernetes.default.svc`.

**`MODE=external`** — Vault sits outside the cluster and can infer nothing. You have to give it:
1. a **delegator** `ServiceAccount` on the K8s side (`system:auth-delegator`);
2. its **long-lived token** (`token_reviewer_jwt`), with which Vault will validate the apps' JWTs;
3. the API **endpoint** (`KUBE_HOST`, by default the lab's VIP `https://192.168.56.5:6443`,
   carried by **keepalived** on kubeadm, by Talos otherwise) **and** the CA of that API (`SA_CA_CRT`).

```bash
MODE=external KUBE_HOST=https://192.168.56.5:6443 SA_JWT=… SA_CA_CRT=… bash 01-kubernetes-auth.sh
```

The `kubectl` commands that produce `SA_JWT` / `SA_CA_CRT` are commented out in the script.
⚠️ Do not pass `--audience` to `kubectl create token` for the reviewer JWT: kubeadm leaves
`--api-audiences` at its default (the issuer, and nothing else), so a token requested on another
audience is rejected at authentication and Vault's TokenReview returns 401.

### `02-roles.sh` — policies + roles

Loads the 4 files from `policies/`, then creates 4 `auth/kubernetes` roles. All with
`token_ttl=15m` and `audience=vault` (which **must** match `VaultAuth.spec.kubernetes.audiences`
on the K8s side).

| Vault role | Bound SA / namespace | Policy |
|---|---|---|
| `vso-static` | `vso-app` / `demo` | `vso-static-kv` |
| `vso-dynamic` | `vso-app` / `demo` | `vso-dynamic-db` |
| `vso-pki` | `vso-app` / `demo` | `vso-pki` |
| `vso-transit` | `vault-secrets-operator-controller-manager` / `vault-secrets-operator` | `vso-transit` |

`vso-transit` is the role of **the operator itself** (encryption of its client cache), not of an
app.

### `lab-kv.sh` — the lab engine

Kubernetes auth (`kubernetes_host=https://kubernetes.default.svc`), KV-v2 engine
**`lab-kv/`**, secret `lab-kv/nginx-test-vault/config` (3 `APP_*` keys), policy
`lab-kv-nginx-test-vault` (read on `lab-kv/data|metadata/nginx-test-vault/*` only) and role
`nginx-test-vault` bound to the SA/ns `nginx-test-vault`.

Adding an app = a `lab-kv/<app>/…` subdirectory, a policy scoped to that subdirectory, a role
dedicated to the app's SA/ns. This script is the template to copy.

### `pg-dynamic-rotate.sh` — PostgreSQL password rotation

Vault takes over a **fixed** PG user (`vault-rotate`) and **rotates its password only** (static
role) — the app's connection string stays stable. Scenario overview and PostgreSQL prerequisites:
`../README.md`.

| Vault object | Command (summary) | Purpose |
|---|---|---|
| `database/` | `vault secrets enable database` | the "database" engine |
| `database/config/pg-demo` | `plugin_name=postgresql-database-plugin allowed_roles=vault-rotate connection_url=…@pg-demo-rw.cnpg-demo…/postgres?sslmode=require username=postgres password=<superuser> password_authentication=scram-sha-256` | **where** Vault connects and **how** (admin `postgres`, TLS). The password is read from the `pg-demo-superuser` Secret by the script. |
| `database/static-roles/vault-rotate` | `db_name=pg-demo username=vault-rotate rotation_period=$ROTATION_PERIOD` | takes over the fixed PG user. `db_name` = the name of the **connection**, not of the database. `ROTATION_PERIOD` defaults to `3h`. |
| Policy `pg-rotate-demo` | `path "database/static-creds/vault-rotate" { capabilities = ["read"] }` | minimal right: read that one static-creds |
| Role `auth/kubernetes/role/pg-rotate-demo` | SA `pg-rotate` / ns `pg-rotate-demo`, `audience=vault` | **who** may log in and **which** rights they get |

```bash
vault read database/static-creds/vault-rotate     # username (fixed) + current password + remaining ttl
vault write -f database/rotate-role/vault-rotate  # force an immediate rotation
```

## 🛡️ The policies

One policy = one use, scoped to the exact path. No mount wildcard.

| File | Allows |
|---|---|
| `policies/vso-static-kv.hcl` | `read` on `kvv2/data/demo/app` + `kvv2/metadata/demo/app` |
| `policies/vso-dynamic-db.hcl` | `read` on `db/creds/demo-app` (⚠️ mount `db/` — see Pitfalls) + `update` on `sys/leases/renew\|revoke` |
| `policies/vso-pki.hcl` | `create`/`update` on `pki/issue/demo` and `pki/revoke` |
| `policies/vso-transit-cache.hcl` | `encrypt`/`decrypt` with the `vso-client-cache` key (operator) |
| `policies/lab-kv-nginx-test-vault.hcl` | `read` on `lab-kv/data\|metadata/nginx-test-vault/*` |

> ℹ️ **KV-v2**: the policy path is `<mount>/data/<path>` for the data and
> `<mount>/metadata/<path>` for the versions — **not** `<mount>/<path>`. Classic mistake.

## ✅ Verify

```bash
vault status                                       # Sealed=false
vault secrets list                                 # kvv2/, database/, pki/, transit/, lab-kv/
vault auth list                                    # kubernetes/ present
vault read auth/kubernetes/config                  # kubernetes_host MUST be a real URL
vault list auth/kubernetes/role                     # vso-*, nginx-test-vault, pg-rotate-demo
vault policy list
vault kv get kvv2/demo/app                          # demo secret (path B)
vault kv get lab-kv/nginx-test-vault/config       # lab secret (path A)
vault list pki/issuers                              # exactly ONE CA expected (see Pitfalls)

# Dry-run login test, without going through VSO — isolates identity problems:
JWT=$(kubectl -n demo create token vso-app --audience=vault)
vault write auth/kubernetes/login role=vso-static jwt="$JWT"   # must return a token + its policy
```

## ⚠️ Pitfalls

- **The "dynamic DB" demo cannot work as it stands — mount mismatch.**
  `00-secrets-engines.sh:19` runs `vault secrets enable database`, **without `-path`**: the engine
  is therefore mounted on **`database/`**. But `../k8s/20-dynamic-db.yaml:11` asks for `mount: db`
  and `policies/vso-dynamic-db.hcl:5` only allows `db/creds/demo-app`. The `VaultDynamicSecret`
  can only return a **403 or a 404**, whatever else you do. To line everything up on `db/`, mount
  the engine in the right place:
  ```bash
  vault secrets enable -path=db database      # instead of: vault secrets enable database
  ```
  (Path A is not affected: `pg-dynamic-rotate.sh` writes and reads `database/` consistently.)
- **`01-kubernetes-auth.sh` in `incluster` mode breaks every login.** Line 26 writes
  `kubernetes_host="https://\$KUBERNETES_PORT_443_TCP_ADDR:443"`: the `\$` is a **literal** `$` in
  bash, and Vault performs no environment substitution on config values. Vault therefore stores
  the string as-is, and any authentication through `auth/kubernetes` fails.
  The sibling script gets it right with `kubernetes_host="https://kubernetes.default.svc"`
  (`lab-kv.sh:22`). Diagnosis:
  ```bash
  vault read auth/kubernetes/config     # if kubernetes_host contains a "$", this is the bug
  vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc"   # fix
  ```
- **The `00-`/`01-`/`02-` scripts are NOT idempotent, contrary to what their header claims.**
  Three distinct reasons:
  - `00-secrets-engines.sh:16` (`vault kv put kvv2/demo/app …`) and `lab-kv.sh:31-34`
    (`APP_SECRET_TOKEN`) **overwrite the value** and create a **new KV version** on every run. If
    you rotated the secret to watch the VSO resync, re-running the script silently puts the
    original value back.
  - `00-secrets-engines.sh:35-36`: since Vault 1.11 (multi-issuers), `pki/root/generate/internal`
    **no longer fails** on an already configured mount — it simply adds a **new issuer**.
    The `|| echo "(CA racine déjà générée)"` guard therefore never fires, and every run **stacks
    one more root CA**. Check with `vault list pki/issuers` and delete the duplicates
    (`vault delete pki/issuer/<id>`).
  - `pg-dynamic-rotate.sh` rewrites `database/config/pg-demo` and the static role on every pass.
    That is the intended mechanism for changing `ROTATION_PERIOD`, but it is not a no-op.
- **No environment guard in `00-`/`01-`/`02-`**, unlike `lab-kv.sh:14-15` and
  `pg-dynamic-rotate.sh:21-22`, which refuse to start without `VAULT_ADDR`/`VAULT_TOKEN`. Without
  `VAULT_ADDR`, the CLI silently hits `https://127.0.0.1:8200`; the script only stops at line 38 of
  `00-` (`${VAULT_ADDR}` under `set -u` → *unbound variable*), so **after** it has already tried to
  write. Export both variables before running anything.
- **`00-secrets-engines.sh:11` hides every Vault error.** The helper
  `enable() { vault secrets enable "$@" 2>/dev/null || echo "  (déjà activé : $*)"; }` swallows
  `stderr`: a `Vault is sealed`, a `permission denied` or a `connection refused` all show up as
  **"(déjà activé)"**. The script will indeed stop at the next command (`set -e`), but with a
  misleading diagnosis. When in doubt, re-run the command by hand without `2>/dev/null`.
- **`permission denied` at login**: the pod's SA/namespace does not match
  `bound_service_account_names`/`_namespaces`, or the JWT's **audience** ≠ the role's `audience`.
  The dry-run login test in the ✅ section isolates the problem without involving VSO.
- **`error validating token: … 403`**: the reviewer lacks `system:auth-delegator` (in-cluster), or
  the `token_reviewer_jwt` is wrong/expired (external).
- **Do not set `disable_iss_validation=false` again**: the default has been `true` since Vault 1.9,
  and the `iss` of projected tokens varies → broken logins.
- **Demo secrets in cleartext in the scripts.** `00-secrets-engines.sh` and `lab-kv.sh` write
  dummy values, versioned in git. That is accepted for a lab; in production, values are injected
  outside git (`vault kv put … @-` from a pipe, or a real provisioning pipeline).

## 📚 References

- [Kubernetes auth method](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Kubernetes auth — HTTP API](https://developer.hashicorp.com/vault/api-docs/auth/kubernetes)
- [Vault policies](https://developer.hashicorp.com/vault/docs/concepts/policies)
- [`database` engine — static roles](https://developer.hashicorp.com/vault/docs/secrets/databases#static-roles)
- [PKI engine — multi-issuers](https://developer.hashicorp.com/vault/docs/secrets/pki/considerations)
