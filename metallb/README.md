<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 📢 `metallb/` — LoadBalancer IPs and L2 announcement, **when the CNI is not Cilium**

> **The missing cloud provider.** Cilium is the only CNI of this lab that hands `type:
> LoadBalancer` Services a real IP and announces it over ARP. With **Calico**, **flannel** or
> **`CNI=none`**, nothing does — the Envoy Gateway Service stays at `EXTERNAL-IP <pending>` and
> no lab UI is reachable. MetalLB in **layer 2** mode fills exactly that hole, **on the same
> range, the same interface and the same nodes** as Cilium would.

## 🎯 Purpose

### What MetalLB does here

- **Allocates** an IP from the host-only range `192.168.56.200-230` to every `type:
  LoadBalancer` Service (the `controller` Deployment).
- **Announces** it over **ARP** from a worker node, so the host — and anything routed to the
  host, Tailscale included — can reach it (the `speaker` DaemonSet).
- Nothing else. **MetalLB is not a CNI**: it needs a working pod network to run.

### The setup in one sentence

`metallb/metallb-up.sh` reads the **same `lab.env` keys as Cilium** and lays down the same two
objects, translated into MetalLB's API — so switching CNI changes the CNI, **not** the address
the `*.<LAB_DOMAIN>` wildcard DNS record points at.

| `lab.env` key | Cilium object | MetalLB object |
|---|---|---|
| `LB_POOL_START` / `LB_POOL_END` | `CiliumLoadBalancerIPPool` (`start`/`stop`) | `IPAddressPool` (`addresses: ["start-stop"]`) |
| `HOSTONLY_IF` | `CiliumL2AnnouncementPolicy.interfaces` (a **regex**, `^enp0s8$`) | `L2Advertisement.interfaces` (a **plain name**, `enp0s8`) |
| — (a lab choice) | `nodeSelector`: control-plane `DoesNotExist` | `nodeSelectors`: the same expression |

The **first IP of the range** goes to `main-gateway` in both cases: `192.168.56.200`.

### When is it installed?

`../platform-up.sh` decides at step **[1/4]**, right after the CNI:

| `CNI` in `lab.env` | L2 announcer | MetalLB installed? |
|---|---|---|
| `cilium` (the lab default) | Cilium itself | ❌ **never** — see ⚠️ Pitfalls |
| `calico` | MetalLB | ✅ |
| `flannel` | MetalLB | ✅ |
| `none` | MetalLB | ✅ (once your own CNI has made the nodes `Ready`) |
| any of the above + `METALLB=false` | none | ❌ — the Gateway stays `<pending>` |

## 📋 Prerequisites

| Prerequisite | Why | Check |
|---|---|---|
| **`CNI != cilium`** | Cilium already announces these IPs; two announcers on one range is an ARP conflict | `sed -n 's/^CNI=//p' lab.env` |
| A **working CNI**, nodes `Ready` | MetalLB is an ordinary workload: with no pod network the controller never gets an IP | `kubectl get nodes` → all `Ready` |
| `kube-proxy` present | MetalLB does not replace it (and `KUBE_PROXY_REPLACEMENT=true` implies `CNI=cilium` anyway) | `kubectl -n kube-system get ds kube-proxy` |
| A host-only interface (`enp0s8`, or `eth1` on some kubeadm boxes) | source of the ARP announcement — **never** the NAT card | `cat _out/cluster.env` (kubeadm) |
| `kubectl` + `helm`, `KUBECONFIG` set | the script checks the binaries, then `/readyz` | `helm version` |

## ⚡ Install

> 🎓 **Two paths, same result**: the all-in-one script below, or the **"Guided walkthrough"**
> section further down — the same commands, one at a time, for training.

In practice **you do not run this by hand**: `../platform-up.sh` calls it at step **[1/4]** as
soon as `CNI != cilium`. The direct call is there for a repair or for training:

```bash
./install.sh <distro> metallb      # <distro> = talos | kubeadm
```

```bash
./metallb/metallb-up.sh <distro>
```

Chart `metallb/metallb` **`0.16.1`**, read from `lab.env` (`METALLB_VERSION`) and overridable
per run (`METALLB_VERSION=0.16.0 ./metallb/metallb-up.sh`). Idempotent (`helm upgrade
--install` + `kubectl apply`).

> ℹ️ `metallb` is **deliberately excluded from `./install.sh <distro> all`**: on the default
> `CNI=cilium` it refuses to install, and an unconditional `all` would always stop right there.
> `platform` installs it when — and only when — the CNI calls for it.

## 🧬 Talos vs kubeadm

The **announcement itself is identical**: same chart, same pool, same interface, same node
selection. One thing genuinely differs, and it is admission.

| Point | Talos | kubeadm | Consequence |
|---|---|---|---|
| PodSecurity default | `baseline` **enforced cluster-wide** | no level enforced | The `speaker` runs on `hostNetwork` and adds `NET_RAW` — `baseline` forbids **both**. [`namespace.yaml`](namespace.yaml) is therefore **mandatory** on Talos and **documentation** on kubeadm. |
| Host-only interface | always `enp0s8` | `eth1` or `enp0s8` depending on the box → **detected** into `_out/cluster.env` | `HOSTONLY_IF` covers both; the script substitutes it into `metallb-l2.yml`. |
| `kube-proxy` | always installed by Talos | optional, but `KUBE_PROXY_REPLACEMENT=true` forces `CNI=cilium` | So MetalLB always finds a kube-proxy in front of it, on both labs. |
| Likely CNI next to it | `calico`, or `flannel` **pre-installed at bootstrap** | `calico`, or `flannel` installed by `platform-up.sh` | No effect on MetalLB: it only ever sees `Ready` nodes and Services. |

> ℹ️ No profile variable was added for this component: nothing here reads
> `lib/profiles/<distro>.sh` beyond `DEFAULT_HOSTONLY_IF`, which already existed. The PodSecurity
> divergence is carried by a namespace manifest applied **in both cases** — the repository rule:
> label the namespace everywhere, even where it unlocks nothing today.

## 🎓 Guided walkthrough (step by step)

The same thing as the script, one command at a time. Set your variables first:

```bash
export KUBECONFIG="$PWD/kubeconfig"           # from the lab root
LB_POOL_START=$(sed -n 's/^LB_POOL_START=//p' lab.env | head -1 | tr -d ' "')
LB_POOL_END=$(sed -n 's/^LB_POOL_END=//p'     lab.env | head -1 | tr -d ' "')
HOSTONLY_IF=$(sed -n 's/^HOSTONLY_IF=//p' _out/cluster.env | head -1)   # kubeadm
HOSTONLY_IF=${HOSTONLY_IF:-enp0s8}                                      # Talos
echo "$LB_POOL_START-$LB_POOL_END on $HOSTONLY_IF"
```

### 1. Check the starting point

```bash
kubectl get nodes                         # all Ready — the CNI is already there
kubectl get ciliuml2announcementpolicies.cilium.io 2>/dev/null   # MUST be empty / no CRD
kubectl -n envoy-gateway-system get svc   # EXTERNAL-IP <pending>, if the Gateway is up
```

### 2. The namespace, before the chart

```bash
kubectl apply -f metallb/namespace.yaml
kubectl get ns metallb-system --show-labels     # pod-security.kubernetes.io/enforce=privileged
```

### 3. Add the Helm repository

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update metallb
```

### 4. Install MetalLB — L2 only, no FRR

```bash
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system \
  --version 0.16.1 \
  --set frrk8s.enabled=false \
  --set speaker.frr.enabled=false
```

### 5. Wait for the controller and the speakers

```bash
kubectl -n metallb-system rollout status deploy/metallb-controller --timeout=300s
kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=300s
```

### 6. Apply the pool + the L2 announcement

```bash
# The versioned values are the lab defaults: substitute yours, exactly as the script does
sed -e "s/192\.168\.56\.200/${LB_POOL_START}/g" \
    -e "s/192\.168\.56\.230/${LB_POOL_END}/g" \
    -e "s/enp0s8/${HOSTONLY_IF}/g" \
    metallb/metallb-l2.yml | kubectl apply -f -
```

> ⚠️ If this fails with `connection refused` or an `x509` error on
> `metallb-webhook-service`, you are simply **early**: the controller injects its own certificate
> into the `ValidatingWebhookConfiguration`, which takes a few seconds after the rollout. Retry.
> That is exactly what the script's loop does.

### 7. Verify

```bash
kubectl -n metallb-system get ipaddresspool,l2advertisement
kubectl -n envoy-gateway-system get svc          # EXTERNAL-IP = 192.168.56.200
kubectl get servicel2status -A -o wide           # which node announces which IP
```

## 🔧 What the script does

| Step | What | Why it is not just a `helm install` |
|---|---|---|
| guard rails | refuses if Cilium announces, or if `CNI=cilium`; refuses if no node is `Ready` | two ARP announcers on one range is the hardest failure of this lab to read; and MetalLB on a CNI-less cluster hangs `Pending` for 5 min before saying anything |
| `[1/3]` | `namespace.yaml` **then** the chart | `helm --create-namespace` sets no PodSecurity label — and its absence fails **silently** (see below) |
| `[2/3]` | `rollout status` on the controller **and** the DaemonSet | the controller allocates, the speakers announce: an IP with no speaker is assigned and unreachable |
| `[3/3]` | `metallb-l2.yml` rendered, applied **with retry** | the validating webhook is served by the controller and takes a few seconds to present a trusted certificate |

### Files

| File | Role |
|---|---|
| [`metallb-up.sh`](metallb-up.sh) | the all-in-one, idempotent install |
| [`namespace.yaml`](namespace.yaml) | `metallb-system` + the three `privileged` PodSecurity labels |
| [`metallb-l2.yml`](metallb-l2.yml) | `IPAddressPool` + `L2Advertisement` — the strict mirror of [`../cilium/cilium-l2.yml`](../cilium/cilium-l2.yml) |

### The Helm settings that matter

| `--set` | Value | Why |
|---|---|---|
| `frrk8s.enabled` | `false` | Since chart 0.15 the FRR-K8s subchart is **enabled by default**: a full FRR routing daemon on every node, for BGP. This lab announces over L2 only (no peer router on a VirtualBox host-only network) — pure dead weight. |
| `speaker.frr.enabled` | `false` | The other, deprecated, way to get FRR into the speaker pod. The chart **refuses both at once**, so both are set explicitly rather than trusting which one defaults to `false` in the version of the day. |

Everything else is left at the chart default on purpose — in particular
`speaker.tolerateMaster=true`, which runs a speaker on the control planes too. That is harmless:
what decides who announces is the `nodeSelectors` of the `L2Advertisement`, exactly like the
Cilium policy.

### `metallb-l2.yml` — two objects

- **`IPAddressPool`** — the range, written as a single `start-stop` string (Cilium uses two
  fields). `autoAssign: true`: the Gateway asks for no particular address and gets the first
  free one.
- **`L2Advertisement`** — who announces, and on which card. `ipAddressPools` names the pool
  (without it the advertisement would cover every pool), `interfaces` pins the host-only card
  and `nodeSelectors` keeps the control planes out.

## ✅ Verify

```bash
kubectl -n metallb-system get pods                      # 1 controller + 1 speaker per node
kubectl -n metallb-system get ipaddresspool -o wide     # the range
kubectl -n metallb-system get l2advertisement -o yaml | grep -A4 interfaces

# The Gateway must have taken the FIRST IP of the pool
kubectl -n envoy-gateway-system get svc

# Who is announcing what (MetalLB's equivalent of Cilium's leases)
kubectl get servicel2status -A -o wide
```

And above all, **the IP must answer** — which no `kubectl get` proves:

```bash
GWIP=$(kubectl -n envoy-gateway-system get svc \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}')
curl -s -o /dev/null -w '%{http_code}\n' "http://$GWIP/"   # 404 = Envoy answers (no route yet)
ip neigh show "$GWIP"                                      # ARP resolved = L2 announcement OK
```

> ⚠️ **Never test that IP with `ping`.** No interface really carries the address: the elected
> speaker only answers **ARP** to attract the traffic, then the node forwards it. ICMP to the VIP
> therefore gets nothing, while `ping` on a *node* (`.101`) works — a very convincing false
> negative. The proof of the announcement is the ARP entry resolving to a worker's MAC:
> ```bash
> ip neigh flush "$GWIP"; curl -s -o /dev/null --max-time 5 "http://$GWIP/"
> ip neigh show "$GWIP"     # lladdr = MAC of the elected worker
> ```

## 🧪 Scenario — speaker failover

The demo that justifies the component: the announcement survives losing a node.

```bash
kubectl get servicel2status -A -o wide          # note the announcing node, e.g. k8s-w2
ip neigh show "$GWIP"                           # note the MAC

# Take that node's speaker away
kubectl -n metallb-system delete pod -l app.kubernetes.io/component=speaker \
  --field-selector spec.nodeName=k8s-w2

# A few seconds later, another worker has taken over
kubectl get servicel2status -A -o wide
ip neigh flush "$GWIP"; curl -s -o /dev/null -w '%{http_code}\n' "http://$GWIP/"
ip neigh show "$GWIP"                           # a DIFFERENT MAC — same IP
```

The few seconds of downtime are the re-ARP: expected, not an incident.

## 🚑 Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| The script fails on "Cilium already announces" | you are on `CNI=cilium` — the lab default | that is the guard rail, not a bug: Cilium already does this. See ⚠️ Pitfalls |
| The script fails on "no Ready node" | no CNI installed yet | install the CNI first — MetalLB is not one |
| `EXTERNAL-IP` stays `<pending>` **with** a valid pool | the Service still carries `loadBalancerClass: io.cilium/l2-announcer` | `platform-up.sh` strips that line when `CNI != cilium`; check `kubectl -n envoy-gateway-system get svc -o yaml \| grep -i loadbalancerclass` |
| `EXTERNAL-IP` set but nothing answers | **zero** speaker pod → PodSecurity refused the DaemonSet | `kubectl -n metallb-system describe ds/metallb-speaker`, then apply [`namespace.yaml`](namespace.yaml) and `rollout restart` |
| Applying the pool fails with `connection refused` / `x509` | the controller's webhook is not serving yet | wait 10 s and retry — the script loops for 150 s |
| ARP resolves to a **control plane** | the `nodeSelectors` were dropped or the label differs | `kubectl -n metallb-system get l2advertisement -o yaml` |
| ARP does not resolve at all | announcement on the NAT card, or `interfaces` written as a regex | `kubectl -n metallb-system get l2advertisement -o yaml` — it must read `enp0s8`, **not** `^enp0s8$` |
| `no available IPs` in the controller logs | pool exhausted (31 addresses) or two Services asking for a fixed IP | `kubectl -n metallb-system logs deploy/metallb-controller` |

## ⚠️ Pitfalls

- **Never MetalLB *and* Cilium's L2 announcement.** Two speakers answering ARP for
  `192.168.56.200` make the host's ARP cache flap between two MACs: the entry point works "one
  time in two", and nothing in any log says so. The script refuses on two independent signals
  (the live `cilium.io` objects, and `CNI` resolving to `cilium`) — do not work around it,
  the right move is to pick one CNI.
- **`interfaces:` is a list of plain names, not regexes.** Cilium's policy takes
  `^enp0s8$`; MetalLB takes `enp0s8`. Copying the Cilium syntax across matches **no** interface
  and the announcement is dropped **in silence**: pool valid, IP assigned, ARP mute.
- **`loadBalancerClass` beats any pool.** As long as
  [`../envoy-gateway/Envoy-Proxy.yml`](../envoy-gateway/Envoy-Proxy.yml) pins
  `loadBalancerClass: io.cilium/l2-announcer`, MetalLB **ignores** the Service — a
  `loadBalancerClass` means "only this controller may serve it". `platform-up.sh` removes the
  line when `CNI != cilium`; applying that manifest by hand does not.
- **The `privileged` labels are not cosmetic, and their absence lies to you.** The `controller`
  is not privileged: it starts, allocates, and writes a perfectly normal `EXTERNAL-IP` into the
  Service. Only the `speaker` is refused — so you get an address that looks assigned and answers
  nothing. Always cross-check `get svc` with `kubectl -n metallb-system get pods`.
- **`WORKERS=0` leaves nobody to announce.** The `nodeSelectors` keep control planes out, on
  purpose. On a lab with no worker, remove them from `metallb-l2.yml` — otherwise the pool is
  valid and no one announces it.
- **One node per IP, not load balancing.** Like `CiliumL2AnnouncementPolicy`, L2 mode elects a
  single speaker per address: all the VIP traffic enters through that node, then kube-proxy
  spreads it across the endpoints. A failover takes a few seconds (the time to re-ARP).
- **`kube-proxy` in IPVS mode needs `strictARP: true`.** Neither lab uses IPVS (both are in
  iptables mode), so this does not bite here — but it is the first thing to check if you take
  this component to another cluster: in IPVS mode without `strictARP`, every node answers ARP
  for the VIP.
- **Changing CNI is not a live switch.** Going from Cilium to Calico means a rebuilt cluster
  (`./kubeadm/cluster-reset.sh`, or `vagrant destroy`), not a `helm uninstall`. MetalLB only
  makes sense on a cluster bootstrapped with the right `CNI` from the start.

## 🧹 Uninstall

```bash
kubectl -n metallb-system delete -f metallb/metallb-l2.yml    # stop announcing first
helm uninstall metallb -n metallb-system
kubectl delete ns metallb-system
```

> ⚠️ Every `LoadBalancer` Service goes back to `EXTERNAL-IP <pending>` and every UI becomes
> unreachable — the Gateway included. The CRDs are removed with the chart, so any leftover
> `IPAddressPool` disappears with them.

## 📚 References

- [MetalLB — Layer 2 configuration](https://metallb.io/configuration/#layer-2-configuration)
- [MetalLB — Installation by Helm](https://metallb.io/installation/#installation-with-helm)
- [MetalLB — Layer 2 limitations (single-node bottleneck, failover)](https://metallb.io/concepts/layer2/)
- [`../cilium/README.md`](../cilium/README.md) — the default CNI, which announces on its own
- [`../calico/README.md`](../calico/README.md) — the alternative CNI that makes this component necessary
- [`../envoy-gateway/README.md`](../envoy-gateway/README.md) — the consumer of the `.200` VIP
