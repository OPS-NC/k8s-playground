<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 📢 `metallb/` — IP LoadBalancer et annonce L2, **quand le CNI n'est pas Cilium**

> **Le fournisseur cloud manquant.** Cilium est le seul CNI de ce lab qui donne une vraie IP aux
> Services `type: LoadBalancer` et l'annonce en ARP. Avec **Calico**, **flannel** ou **`CNI=none`**,
> personne ne le fait — le Service du Gateway Envoy reste en `EXTERNAL-IP <pending>` et aucune UI du
> lab n'est joignable. MetalLB en mode **layer 2** comble exactement ce trou, sur la même plage, la
> même interface et les mêmes nodes que Cilium l'aurait fait.

## 🎯 À quoi ça sert

MetalLB **attribue** une IP de la plage host-only `192.168.56.200-230` à chaque Service
`type: LoadBalancer` (le Deployment `controller`) et l'**annonce** en **ARP** depuis un worker, pour
que l'hôte — et tout ce qui est routé vers lui, Tailscale compris — puisse l'atteindre (le DaemonSet
`speaker`). Rien d'autre : **MetalLB n'est pas un CNI**, il a besoin d'un réseau de pods qui marche
pour tourner.

`metallb-up.sh` lit les **mêmes clés `lab.env` que Cilium** et pose les mêmes deux objets, traduits
dans l'API de MetalLB — donc changer de CNI change le CNI, **pas** l'adresse vers laquelle pointe le
wildcard `*.<LAB_DOMAIN>`.

| Clé `lab.env` | Objet Cilium | Objet MetalLB |
|---|---|---|
| `LB_POOL_START` / `LB_POOL_END` | `CiliumLoadBalancerIPPool` (`start`/`stop`) | `IPAddressPool` (`addresses: ["start-stop"]`) |
| `HOSTONLY_IF` | `CiliumL2AnnouncementPolicy.interfaces` (une **regex**, `^enp0s8$`) | `L2Advertisement.interfaces` (un **nom simple**, `enp0s8`) |
| — (un choix du lab) | `nodeSelector` : control-plane `DoesNotExist` | `nodeSelectors` : la même expression |

La **première IP de la plage** va à `main-gateway` dans les deux cas : `192.168.56.200`.

`../platform-up.sh` décide à l'étape **[1/4]**, juste après le CNI :

| `CNI` dans `lab.env` | Annonceur L2 | MetalLB installé ? |
|---|---|---|
| `cilium` (le défaut du lab) | Cilium lui-même | ❌ **jamais** — voir ⚠️ Pièges |
| `calico` · `flannel` · `none` | MetalLB | ✅ (pour `none`, une fois que ton propre CNI a rendu les nodes `Ready`) |
| l'un des ci-dessus + `METALLB=false` | aucun | ❌ — le Gateway reste `<pending>` |

## 📋 Prérequis

| Prérequis | Pourquoi | Contrôle |
|---|---|---|
| **`CNI != cilium`** | Cilium annonce déjà ces IP ; deux annonceurs sur une plage, c'est un conflit ARP | `sed -n 's/^CNI=//p' lab.env` |
| Un **CNI qui marche**, nodes `Ready` | MetalLB est une charge de travail ordinaire : sans réseau de pods, le controller n'obtient jamais d'IP | `kubectl get nodes` |
| Une interface host-only (`enp0s8`, ou `eth1` sur certaines box kubeadm) | source de l'annonce ARP — **jamais** la carte NAT | `cat _out/cluster.env` (kubeadm) |
| `kubectl` + `helm`, `KUBECONFIG` posé | le script vérifie les binaires, puis `/readyz` | `helm version` |

`kube-proxy` est présent par construction : `KUBE_PROXY_REPLACEMENT=true` implique `CNI=cilium`, ce
qui exclut MetalLB — donc MetalLB trouve toujours un kube-proxy devant lui, sur les deux labs.

## ⚡ Installation

En pratique **tu ne lances pas ça à la main** : `../platform-up.sh` l'appelle à l'étape **[1/4]** dès
que `CNI != cilium`. L'appel direct est là pour une réparation, ou pour le pas à pas ci-dessous :

```bash
./install.sh <distro> metallb      # <distro> = talos | kubeadm
./metallb/metallb-up.sh <distro>   # la même chose, directement
```

Chart `metallb/metallb` **`0.16.1`**, surchargeable par exécution
(`METALLB_VERSION=0.16.0 ./metallb/metallb-up.sh`). Idempotent (`helm upgrade --install` +
`kubectl apply`).

> ℹ️ `metallb` est **volontairement exclu de `./install.sh <distro> all`** : sur le défaut
> `CNI=cilium` il refuse de s'installer, et un `all` inconditionnel s'arrêterait toujours là.
> `platform` l'installe quand — et seulement quand — le CNI l'exige.

## 🧬 Talos vs kubeadm

L'annonce elle-même est identique : même chart, même pool, même interface, même sélection de nodes.
Deux choses diffèrent, et seule la première compte.

| Point | Talos | kubeadm | Conséquence |
|---|---|---|---|
| Défaut PodSecurity | `baseline` **imposé sur tout le cluster** | aucun niveau imposé | Le `speaker` tourne en `hostNetwork` et ajoute `NET_RAW` — `baseline` interdit **les deux**. [`namespace.yaml`](namespace.yaml) est donc **obligatoire** sur Talos et **documentaire** sur kubeadm. |
| Interface host-only | toujours `enp0s8` | `eth1` ou `enp0s8` selon la box → **détectée** dans `_out/cluster.env` | `HOSTONLY_IF` couvre les deux ; le script la substitue dans `metallb-l2.yml`. |

## 🎓 Pas à pas guidé (formation)

La même chose que le script, une commande à la fois.

```bash
export KUBECONFIG="$PWD/kubeconfig"           # depuis la racine du lab
LB_POOL_START=$(sed -n 's/^LB_POOL_START=//p' lab.env | head -1 | tr -d ' "')
LB_POOL_END=$(sed -n 's/^LB_POOL_END=//p'     lab.env | head -1 | tr -d ' "')
HOSTONLY_IF=$(sed -n 's/^HOSTONLY_IF=//p' _out/cluster.env | head -1)   # kubeadm
HOSTONLY_IF=${HOSTONLY_IF:-enp0s8}                                      # Talos
echo "$LB_POOL_START-$LB_POOL_END sur $HOSTONLY_IF"
```

```bash
# 1. Point de départ : nodes Ready (le CNI est là), et rien d'autre qui annonce
kubectl get nodes
kubectl get ciliuml2announcementpolicies.cilium.io 2>/dev/null   # DOIT être vide / pas de CRD
kubectl -n envoy-gateway-system get svc                          # EXTERNAL-IP <pending>

# 2. Le namespace, AVANT le chart (voir ⚠️ Pièges)
kubectl apply -f metallb/namespace.yaml
kubectl get ns metallb-system --show-labels     # pod-security.kubernetes.io/enforce=privileged

# 3. Le chart — L2 uniquement, sans FRR
helm repo add metallb https://metallb.github.io/metallb && helm repo update metallb
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system --version 0.16.1 \
  --set frrk8s.enabled=false --set speaker.frr.enabled=false

# 4. Le controller ET les speakers — le controller attribue, les speakers annoncent
kubectl -n metallb-system rollout status deploy/metallb-controller --timeout=300s
kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=300s

# 5. Le pool + l'annonce L2, avec tes valeurs substituées
sed -e "s/192\.168\.56\.200/${LB_POOL_START}/g" \
    -e "s/192\.168\.56\.230/${LB_POOL_END}/g" \
    -e "s/enp0s8/${HOSTONLY_IF}/g" \
    metallb/metallb-l2.yml | kubectl apply -f -

# 6. Vérifier
kubectl -n metallb-system get ipaddresspool,l2advertisement
kubectl -n envoy-gateway-system get svc          # EXTERNAL-IP = 192.168.56.200
kubectl get servicel2status -A -o wide           # quel node annonce quelle IP
```

> ⚠️ Si l'étape 5 échoue sur `connection refused` ou une erreur `x509` sur
> `metallb-webhook-service`, tu es simplement **en avance** : le controller injecte son propre
> certificat dans la `ValidatingWebhookConfiguration`, ce qui prend quelques secondes après le
> rollout. Réessaie — c'est ce que fait la boucle du script (150 s).

## 🔧 Comment ça marche

| Fichier | Rôle |
|---|---|
| [`metallb-up.sh`](metallb-up.sh) | l'installation tout-en-un, idempotente |
| [`namespace.yaml`](namespace.yaml) | `metallb-system` + les trois étiquettes PodSecurity `privileged` |
| [`metallb-l2.yml`](metallb-l2.yml) | `IPAddressPool` + `L2Advertisement` — le miroir strict de [`../cilium/cilium-l2.yml`](../cilium/cilium-l2.yml) |

Le script ajoute des garde-fous à ce qui serait sinon un `helm install` : il refuse si Cilium annonce
ou si `CNI=cilium` (deux annonceurs ARP sur une plage est la panne la plus illisible de ce lab), et il
refuse si aucun node n'est `Ready` (MetalLB sur un cluster sans CNI reste `Pending` cinq minutes avant
de dire quoi que ce soit).

Deux `--set` comptent, et tous deux désactivent la même chose de deux façons :

| `--set` | Valeur | Pourquoi |
|---|---|---|
| `frrk8s.enabled` | `false` | Depuis le chart 0.15, le sous-chart FRR-K8s est **activé par défaut** : un démon de routage FRR complet sur chaque node, pour BGP. Ce lab n'annonce qu'en L2 (aucun routeur pair sur un réseau host-only VirtualBox) — poids mort. |
| `speaker.frr.enabled` | `false` | L'autre façon, dépréciée, de mettre FRR dans le pod speaker. Le chart **refuse les deux à la fois**, donc les deux sont posés explicitement plutôt que de faire confiance à celui qui vaut `false` par défaut dans la version du jour. |

Tout le reste reste au défaut du chart, `speaker.tolerateMaster=true` compris — qui fait tourner un
speaker sur les control planes aussi. Sans conséquence : ce qui décide qui annonce, c'est les
`nodeSelectors` de l'`L2Advertisement`, exactement comme la politique Cilium. Dans `metallb-l2.yml`,
`autoAssign: true` sur le pool signifie que le Gateway ne demande aucune adresse particulière et
reçoit la première libre, et `ipAddressPools` nomme le pool explicitement — sans ça, l'annonce
couvrirait tous les pools.

## ✅ Vérifier

```bash
kubectl -n metallb-system get pods                      # 1 controller + 1 speaker par node
kubectl -n metallb-system get ipaddresspool -o wide
kubectl -n metallb-system get l2advertisement -o yaml | grep -A4 interfaces
kubectl -n envoy-gateway-system get svc                 # le Gateway a pris la PREMIÈRE IP du pool
kubectl get servicel2status -A -o wide                  # qui annonce quoi
```

Et surtout, **l'IP doit répondre** — ce qu'aucun `kubectl get` ne prouve :

```bash
GWIP=$(kubectl -n envoy-gateway-system get svc \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}')
curl -s -o /dev/null -w '%{http_code}\n' "http://$GWIP/"   # 404 = Envoy répond (pas encore de route)
ip neigh show "$GWIP"                                      # ARP résolu = annonce L2 OK
```

> ⚠️ **Ne teste jamais cette IP avec `ping`.** Aucune interface ne porte réellement l'adresse : le
> speaker élu se contente de répondre à l'**ARP** pour attirer le trafic, puis le node le transmet.
> L'ICMP vers la VIP n'obtient donc rien, alors que le `ping` d'un *node* (`.101`) fonctionne — un
> faux négatif très convaincant. La preuve de l'annonce, c'est l'entrée ARP qui se résout vers la MAC
> d'un worker :
> ```bash
> ip neigh flush "$GWIP"; curl -s -o /dev/null --max-time 5 "http://$GWIP/"
> ip neigh show "$GWIP"     # lladdr = MAC du worker élu
> ```

## 🧪 Scénario — bascule de speaker

La démo qui justifie le composant : l'annonce survit à la perte d'un node.

```bash
kubectl get servicel2status -A -o wide          # note le node annonceur, p. ex. k8s-w2
ip neigh show "$GWIP"                           # note la MAC

kubectl -n metallb-system delete pod -l app.kubernetes.io/component=speaker \
  --field-selector spec.nodeName=k8s-w2

# Quelques secondes plus tard, un autre worker a repris la main
kubectl get servicel2status -A -o wide
ip neigh flush "$GWIP"; curl -s -o /dev/null -w '%{http_code}\n' "http://$GWIP/"
ip neigh show "$GWIP"                           # une MAC DIFFÉRENTE — même IP
```

Les quelques secondes de coupure sont le ré-ARP : attendu, pas un incident.

## 🚑 Dépannage

| Symptôme | Cause probable | Que faire |
|---|---|---|
| Le script échoue sur « Cilium annonce déjà » | tu es en `CNI=cilium` — le défaut du lab | c'est le garde-fou : Cilium le fait déjà |
| Le script échoue sur « aucun node Ready » | aucun CNI installé | installe le CNI d'abord — MetalLB n'en est pas un |
| `EXTERNAL-IP` reste `<pending>` **avec** un pool valide | le Service porte encore `loadBalancerClass: io.cilium/l2-announcer` | `platform-up.sh` retire cette ligne quand `CNI != cilium` ; vérifie `kubectl -n envoy-gateway-system get svc -o yaml \| grep -i loadbalancerclass` |
| `EXTERNAL-IP` posée mais rien ne répond | **zéro** pod speaker → PodSecurity a refusé le DaemonSet | `kubectl -n metallb-system describe ds/metallb-speaker`, puis applique [`namespace.yaml`](namespace.yaml) et `rollout restart` |
| L'application du pool échoue sur `connection refused` / `x509` | le webhook du controller ne sert pas encore | attends 10 s et réessaie — le script boucle 150 s |
| L'ARP se résout vers un **control plane** | les `nodeSelectors` ont sauté ou l'étiquette diffère | `kubectl -n metallb-system get l2advertisement -o yaml` |
| L'ARP ne se résout pas du tout | annonce sur la carte NAT, ou `interfaces` écrit comme une regex | ça doit dire `enp0s8`, **pas** `^enp0s8$` |
| `no available IPs` dans les logs du controller | pool épuisé (31 adresses) ou deux Services qui demandent une IP fixe | `kubectl -n metallb-system logs deploy/metallb-controller` |

## ⚠️ Pièges

- **Jamais MetalLB *et* l'annonce L2 de Cilium.** Deux speakers qui répondent à l'ARP pour
  `192.168.56.200` font osciller le cache ARP de l'hôte entre deux MAC : le point d'entrée fonctionne
  « une fois sur deux », et rien dans aucun log ne le dit. Le script refuse sur deux signaux
  indépendants (les objets `cilium.io` vivants, et `CNI` résolu à `cilium`) — la bonne réaction est de
  choisir un seul CNI.
- **`interfaces:` est une liste de noms simples, pas de regex.** La politique Cilium prend
  `^enp0s8$` ; MetalLB prend `enp0s8`. Recopier la syntaxe Cilium ne correspond à **aucune** interface
  et l'annonce est abandonnée **en silence** : pool valide, IP attribuée, ARP muet.
- **`loadBalancerClass` bat n'importe quel pool.** Tant que
  [`../envoy-gateway/Envoy-Proxy.yml`](../envoy-gateway/Envoy-Proxy.yml) épingle
  `loadBalancerClass: io.cilium/l2-announcer`, MetalLB **ignore** le Service — un `loadBalancerClass`
  signifie « seul ce contrôleur peut le servir ». `platform-up.sh` retire la ligne quand
  `CNI != cilium` ; appliquer ce manifeste à la main, non.
- **Les étiquettes `privileged` ne sont pas cosmétiques, et leur absence te ment.** Le `controller`
  n'est pas privilégié : il démarre, attribue, et écrit une `EXTERNAL-IP` parfaitement normale dans le
  Service. Seul le `speaker` est refusé — donc tu obtiens une adresse qui a l'air attribuée et ne
  répond à rien. Croise toujours `get svc` avec `get pods`.
- **`WORKERS=0` ne laisse personne pour annoncer.** Les `nodeSelectors` excluent les control planes à
  dessein. Sur un lab sans worker, retire-les de `metallb-l2.yml`.
- **Un node par IP, pas de répartition de charge.** Comme `CiliumL2AnnouncementPolicy`, le mode L2 élit
  un seul speaker par adresse : tout le trafic de la VIP entre par ce node, puis kube-proxy le répartit
  sur les endpoints.
- **`kube-proxy` en mode IPVS exige `strictARP: true`.** Aucun des deux labs n'utilise IPVS, donc ça ne
  mord pas ici — mais c'est la première chose à vérifier si tu emportes ce composant sur un autre
  cluster : en IPVS sans `strictARP`, tous les nodes répondent à l'ARP pour la VIP.
- **Changer de CNI n'est pas une bascule à chaud.** Passer de Cilium à Calico veut dire un cluster
  reconstruit (`./kubeadm/cluster-reset.sh`, ou `vagrant destroy`), pas un `helm uninstall`.

## 🧹 Désinstaller

```bash
kubectl -n metallb-system delete -f metallb/metallb-l2.yml    # arrêter d'annoncer d'abord
helm uninstall metallb -n metallb-system
kubectl delete ns metallb-system
```

> ⚠️ Tous les Services `LoadBalancer` repassent en `EXTERNAL-IP <pending>` et toutes les UI
> deviennent injoignables — le Gateway compris. Les CRD partent avec le chart, donc tout
> `IPAddressPool` résiduel disparaît avec elles.

## 📚 Références

- [MetalLB — Layer 2 configuration](https://metallb.io/configuration/#layer-2-configuration)
- [MetalLB — Installation by Helm](https://metallb.io/installation/#installation-with-helm)
- [MetalLB — Layer 2 limitations (goulot mono-node, bascule)](https://metallb.io/concepts/layer2/)
- [`../cilium/LISEZ-MOI.md`](../cilium/LISEZ-MOI.md) — le CNI par défaut, qui annonce tout seul
- [`../calico/LISEZ-MOI.md`](../calico/LISEZ-MOI.md) — le CNI alternatif qui rend ce composant nécessaire
- [`../envoy-gateway/LISEZ-MOI.md`](../envoy-gateway/LISEZ-MOI.md) — le consommateur de la VIP `.200`
