# CLAUDE.md — how this repository works, for an agent

> This file is NOT published in the documentation (`docs/build.py` excludes it): it only
> addresses an assistant working on this repository.

## 1. What this repository is

`k8s-playground` is the **Kubernetes application layer shared by two Vagrant labs**:

| Lab | Base | Repository |
|---|---|---|
| Talos | Talos Linux — immutable OS, no systemd, PodSecurity `baseline` cluster-wide, `talosctl` | `OPS-NC/Vagrant-Talos` |
| kubeadm | Debian 13 + `kubeadm` — ordinary OS, no PodSecurity enforced | `OPS-NC/Vagrant-kubeadm` |

Both labs run **without kube-proxy** by default (`KUBE_PROXY_REPLACEMENT=true`, Cilium in eBPF);
only the bootstrap mechanism differs — `kubeadm init --skip-phases=addon/kube-proxy` vs
`cluster.proxy.disabled: true` in the Talos machine config. The value is decided at bootstrap,
requires `CNI=cilium`, and is never a live toggle.

This repository **brings up no cluster**: no `Vagrantfile`, no `lab.env`, no `_out/`. The labs
own the VMs, the OS and the state; this repository owns the manifests and the charts, applied
from the host with `kubectl` / `helm`. That absence is **load-bearing**: it is what makes "the
parent holds a `Vagrantfile`" an unambiguous way to spot the lab.

Normal layout: a **submodule** mounted on `<lab>/_k8s`. Secondary layout: sibling repositories
(`../Vagrant-Talos`, `../Vagrant-KubeADM`).

## 2. THE rule: everything must work on Talos AND on kubeadm

**No resource in this repository is allowed to work on only one of the two distributions.** A
component is finished when it installs and works on both labs, and when its README explains —
even if only to say "nothing changes" — what differs.

Corollaries, to be followed without exception:

1. **Never an `if [ "$K8S_DISTRO" = talos ]` scattered through a component script.** Everything
   that diverges is a **profile variable** (`lib/profiles/talos.sh` / `lib/profiles/kubeadm.sh`).
   The component script reads the variable, it does not test the distribution. When a new need
   for divergence appears: add the variable **to both profiles** (with a comment explaining why
   it holds that value there), then read it.
2. **The profile also documents the "not needed" case.** On kubeadm most of the Talos
   workarounds fall away: we do not delete them, we write `LONGHORN_PREP_REQUIRED=false` with
   the comment that says *why* it falls away. Comparing the two labs is a teaching goal of the
   repository, not a side effect.
3. **Privileged namespaces labelled in both cases.** A privileged pod (hostPath, hostNetwork,
   hostPID) needs `pod-security.kubernetes.io/enforce: privileged` on its namespace: mandatory
   on Talos (a **silent** refusal otherwise — the Deployment exists, the ReplicaSet creates no
   pod), without effect on kubeadm today, but put there anyway because it documents the need
   and protects against future hardening.
4. **Every README has a "🧬 Talos vs kubeadm" section**, including when the answer is "no
   distribution-specific behaviour" — in which case we say explicitly that the distribution
   argument then only drives the default domain and the location of `lab.env` / `kubeconfig`.
5. **Nothing that assumes systemd, a writable `/`, an `/opt`, SSH access or a package manager**
   without going through a profile variable. On Talos, node configuration goes through
   `talosctl` (an API) and "package" prerequisites become **extensions** baked into the
   installer image — they cannot be added at runtime.

## 3. Architecture

```
install.sh                  entry point: ./install.sh [talos|kubeadm] <component...>
platform-up.sh              the base layer: CNI → Envoy Gateway → metrics-server → wildcard TLS
metric-server.yaml          metrics-server (applied by platform-up.sh)
lib/common.sh               shared core: distro/lab resolution, lab.env reading, helpers
lib/profiles/{talos,kubeadm}.sh   EVERYTHING that diverges between the two labs
<component>/
  <component>-up.sh         the all-in-one, idempotent install
  values.yaml / *.yaml      manifests and values, with NEUTRAL values
  README.md / LISEZ-MOI.md  EN docs (canonical) + FR mirror
docs/build.py               builds the single-page site from every README (make docs)
Makefile                    docs, docs-check, validate — everything that runs without a cluster
```

### `lib/common.sh` — the API every component script uses

| Function / variable | Role |
|---|---|
| `k8s_init "$@"` | **Mandatory entry point.** Resolves the distribution, loads its profile, locates the lab, computes `LAB_DOMAIN` / `WILDCARD_TLS`, sets `KUBECONFIG`. Unconsumed arguments go into `K8S_ARGS`. |
| `log` / `warn` / `fail` | Normalised output (`==>`, `/!\`, `ERROR:` + `exit 1`). |
| `need bin...` | Fails if a binary is missing from `PATH`. |
| `require_apiserver` | Fails if the apiserver does not answer, with a reminder of the right distro's `cluster-up.sh`. |
| `require_sc <sc>` | Fails if the StorageClass is missing, with the install command. |
| `read_param NAME DEFAULT` | environment > `_out/cluster.env` > `lab.env` > default. |
| `render FILE...` | Writes the manifest to stdout with the neutral markers substituted. |
| `distro_summary` | The one-line reminder of the active profile, printed at the top of an install. |
| `REPO_ROOT`, `LAB_DIR`, `K8S_DISTRO`, `LAB_DOMAIN`, `WILDCARD_TLS` | Variables exported by `k8s_init`. |

### The repository is public: three neutral markers, substituted on the fly

No versioned manifest carries a real value. `render` replaces them, **without ever rewriting a
versioned file** (`git status` stays clean):

| Versioned marker | Replaced with |
|---|---|
| `lab.example.io` | `$LAB_DOMAIN` (default `<distro>.lab.example.io`) |
| `lab-example-io` | `$LAB_DOMAIN_DASH` — the wildcard TLS Secret name |
| `lab-kv` | `$VAULT_KV_MOUNT` (`talos-lab` / `kubeadm-lab`) |

Any value that depends on the lab **must** go through one of those markers or through
`read_param`. Never commit a real domain, a token or a password: the `docs` CI refuses to
publish if it detects a secret pattern in the generated page.

### Exposing UIs

A single Gateway, `main-gateway` (ns `envoy-gateway-system`), listeners `:80` and `:443`. TLS is
terminated by **Envoy** with the `*.<LAB_DOMAIN>` wildcard. A component exposing a UI therefore
lays down an `HTTPRoute` **in its own namespace**:

```yaml
parentRefs:
  - name: main-gateway
    namespace: envoy-gateway-system
    sectionName: https        # TLS :443 listener
hostnames:
  - <app>.lab.example.io      # matches the wildcard
```

Cross-namespace attachment is possible because `main-gateway` opens its listeners to
`from: All`; since the backend sits in the same namespace as the route, no `ReferenceGrant` is
needed. **Systematic corollary**: the application behind must speak **plain HTTP** and must not
do its own `http→https` redirect, otherwise you get a redirect loop (see Argo CD's
`server.insecure=true`, Keycloak's `proxy.headers: xforwarded`).

## 4. Adding a component — the checklist

1. `mkdir <component>/`; the script is named `<component>-up.sh`, it is **executable** and
   **idempotent** (`helm upgrade --install` + `kubectl apply`, safe to re-run).
2. Script header: a comment that says **what**, **how to run it**, **the prerequisites**, **what
   differs between the two distributions**, and why the setup is the way it is. This
   repository's comments explain the *why*, not the *what* — that is the style contract, YAML
   files included.
3. Skeleton:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   # shellcheck source=../lib/common.sh
   . "${HERE}/../lib/common.sh"
   k8s_init "$@"
   FOO_VERSION="${FOO_VERSION:-x.y.z}"   # PINNED version, overridable
   need kubectl helm
   require_apiserver
   ```
4. Versions **pinned** in the script through an overridable environment variable, and carried
   over into the "Pinned versions" table of both root READMEs.
5. Numbered steps `log "[1/N] …"`, then a final block printing the URL, the credentials (never
   their value: the **command** that reads them) and a verification command.
6. Secrets: never on stdout, never in a versioned file. The only acceptable location is
   `${LAB_DIR}/_out/` (gitignored), mode `0600`, with `umask 077` set **before** the redirection
   (see `vault-cluster/vault-up.sh`).
7. Documentation: `README.md` (EN, canonical) **and** `LISEZ-MOI.md` (FR, mirror).
8. Reference the component:
   - `install.sh` → the `CATALOGUE` array (`alias|path/script|description`), in the right place
     in the recommended install order (`all`);
   - the root `README.md` and `LISEZ-MOI.md` → the catalogue section + the versions table
     (+ the "dependency chain" if the component introduces one);
   - `docs/build.py` → `GROUPS` (the menu group) and `EMOJIS` (the page icon).
9. `make validate` must pass.

### The template of a component README

Section order, as found in every existing directory:

```
<!-- i18n -->            language banner (EN: **English** · [Français](LISEZ-MOI.md))
# <emoji> `<directory>/` — title
> one- or two-sentence hook
> 🌐 reminder about the neutral domain
## 🎯 Purpose
### The setup in one sentence
## 📋 Prerequisites          (table: prerequisite | why | verify)
## ⚡ Install                (install.sh, then <component>-up.sh, then a <details> manual equivalent)
## 🧬 Talos vs kubeadm       (MANDATORY, even to say "no specific behaviour")
## 🎓 Guided walkthrough     (the same commands, one at a time — for training)
## 🔧 What the script does + a "Files" table
## ✅ Verify
## 🌐 Access                 (if there is a UI)
## 🧪 Scenario               (the demo that justifies the component)
## 🚑 Troubleshooting
## ⚠️ Pitfalls
## 📚 References
```

The FR mirror is **strict**: same sections, same tables, same commands, same relative anchors —
only the language and the links change (`../x/README.md` → `../x/LISEZ-MOI.md`).

## 5. Documentation

- `README.md` = **canonical** English, `LISEZ-MOI.md` = French mirror, in the **same
  directory**. Every page has both versions; a missing one is visible (an "EN" badge).
- `docs/build.py` generates `docs/index.html`, a **single self-contained page**: no CDN, no
  external asset, images embedded as `data:` URIs. Every `*.md` file of the repository is
  discovered automatically (barring exclusions); only the menu group and the emoji are declared.
- Internal links are rewritten into routes of the single page. **`make docs-check` fails if a
  link or an anchor does not resolve** — that is also what CI does (`--strict`). A link to a
  file that does not exist yet therefore breaks the build: do not reference a component that
  lives on another branch.
- Commands: `make docs`, `make docs-open`, `make docs-check`.

## 6. Validate before concluding

```bash
make validate        # = validate-shell + validate-yaml + validate-docs
make validate-shell  # bash -n on every *.sh
make validate-yaml   # kubectl create --dry-run=client on every *.yaml/*.yml (no cluster)
make docs-check      # every link and anchor of the documentation resolves
```

No cluster is required. A task is not finished until `make validate` passes.

## 7. Conventions

- **Language**: code and script comments in **English**; `README.md` in **English**,
  `LISEZ-MOI.md` in **French**. French is confined to the FR mirrors and to the French UI
  strings of `docs/build.py`.
- **Commits**: `<type>(<scope>): <description>` — `fix`, `feat`, `refactor`, `docs`, `chore`,
  `perf`, `test`. **The message is written in English**, subject and body, like every other
  non-documentation artefact of this repository. This rule used to ask for French and for a
  `[Claude]` prefix; neither matched what the history actually contains, and both are dropped.
- **Shell**: `set -euo pipefail` everywhere. Never a `grep` whose failure is normal (under
  `pipefail` + `set -e` it kills the script) — use `sed -n 's///p'` or end with `|| true`.
- **No `sudo`** in the scripts.
- Do not create a file that is not referenced by a README or a script.
