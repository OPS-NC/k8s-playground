<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 📢 `metallb/` — IP LoadBalancer et annonce L2, **quand le CNI n'est pas Cilium**

> **Le cloud provider manquant.** Cilium est le seul CNI de ce lab qui attribue une vraie IP aux
> Services `type: LoadBalancer` et l'annonce en ARP. Avec **Calico**, **flannel** ou
> **`CNI=none`**, personne ne le fait — le Service de l'Envoy Gateway reste en `EXTERNAL-IP
> <pending>` et aucune UI du lab n'est joignable. MetalLB en mode **layer 2** comble exactement
> ce trou, **sur la même plage, la même interface et les mêmes nodes** que Cilium.

## 🎯 À quoi ça sert

### Ce que MetalLB fait ici

- **Attribue** une IP de la plage host-only `192.168.56.200-230` à chaque Service `type:
  LoadBalancer` (le Deployment `controller`).
- **L'annonce** en **ARP** depuis un node worker, pour que l'hôte — et tout ce qui est routé
  vers l'hôte, Tailscale compris — puisse l'atteindre (le DaemonSet `speaker`).
- Rien d'autre. **MetalLB n'est pas un CNI** : il lui faut un réseau pod fonctionnel pour
  tourner.

### Le montage en une phrase

`metallb/metallb-up.sh` lit **les mêmes clés de `lab.env` que Cilium** et pose les deux mêmes
objets, traduits dans l'API de MetalLB — pour que changer de CNI change le CNI, **pas**
l'adresse vers laquelle pointe l'enregistrement DNS wildcard `*.<LAB_DOMAIN>`.

| Clé de `lab.env` | Objet Cilium | Objet MetalLB |
|---|---|---|
| `LB_POOL_START` / `LB_POOL_END` | `CiliumLoadBalancerIPPool` (`start`/`stop`) | `IPAddressPool` (`addresses: ["start-stop"]`) |
| `HOSTONLY_IF` | `CiliumL2AnnouncementPolicy.interfaces` (une **regex**, `^enp0s8$`) | `L2Advertisement.interfaces` (un **nom brut**, `enp0s8`) |
| — (un choix du lab) | `nodeSelector` : control-plane `DoesNotExist` | `nodeSelectors` : la même expression |

La **première IP de la plage** revient à `main-gateway` dans les deux cas : `192.168.56.200`.

### Quand est-il installé ?

`../platform-up.sh` tranche à l'étape **[1/4]**, juste après le CNI :

| `CNI` dans `lab.env` | Annonceur L2 | MetalLB installé ? |
|---|---|---|
| `cilium` (le défaut du lab) | Cilium lui-même | ❌ **jamais** — voir ⚠️ Pièges |
| `calico` | MetalLB | ✅ |
| `flannel` | MetalLB | ✅ |
| `none` | MetalLB | ✅ (une fois ton propre CNI passé, les nodes `Ready`) |
| n'importe lequel ci-dessus + `METALLB=false` | aucun | ❌ — la Gateway reste `<pending>` |

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| **`CNI != cilium`** | Cilium annonce déjà ces IP ; deux annonceurs sur une plage, c'est un conflit ARP | `sed -n 's/^CNI=//p' lab.env` |
| Un **CNI fonctionnel**, nodes `Ready` | MetalLB est une charge de travail ordinaire : sans réseau pod le controller n'obtient jamais d'IP | `kubectl get nodes` → tous `Ready` |
| `kube-proxy` présent | MetalLB ne le remplace pas. Il est là par construction : `KUBE_PROXY_REPLACEMENT=true` impose `CNI=cilium`, ce qui exclut MetalLB | `kubectl -n kube-system get ds kube-proxy` |
| Une interface host-only (`enp0s8`, ou `eth1` sur certaines box kubeadm) | source de l'annonce ARP — **jamais** la carte NAT | `cat _out/cluster.env` (kubeadm) |
| `kubectl` + `helm`, `KUBECONFIG` positionné | le script vérifie les binaires, puis `/readyz` | `helm version` |

## ⚡ Installation

> 🎓 **Deux chemins, même résultat** : le script tout-en-un ci-dessous, ou la section **« Pas à
> pas guidé »** plus bas — les mêmes commandes, une par une, pour la formation.

En pratique **tu ne le lances pas à la main** : `../platform-up.sh` l'appelle à l'étape
**[1/4]** dès que `CNI != cilium`. L'appel direct est là pour une réparation ou pour la
formation :

```bash
./install.sh <distro> metallb      # <distro> = talos | kubeadm
```

```bash
./metallb/metallb-up.sh <distro>
```

Chart `metallb/metallb` **`0.16.1`**, lu depuis `lab.env` (`METALLB_VERSION`) et surchargeable
au coup par coup (`METALLB_VERSION=0.16.0 ./metallb/metallb-up.sh`). Idempotent (`helm upgrade
--install` + `kubectl apply`).

> ℹ️ `metallb` est **volontairement exclu de `./install.sh <distro> all`** : sur le `CNI=cilium`
> par défaut il refuse de s'installer, et un `all` inconditionnel s'arrêterait donc toujours là.
> C'est `platform` qui l'installe quand — et seulement quand — le CNI l'exige.

## 🧬 Talos vs kubeadm

L'**annonce elle-même est identique** : même chart, même pool, même interface, même sélection de
nodes. Une seule chose diverge vraiment, et c'est l'admission.

| Point | Talos | kubeadm | Conséquence |
|---|---|---|---|
| Défaut PodSecurity | `baseline` **imposé sur tout le cluster** | aucun niveau imposé | Le `speaker` tourne en `hostNetwork` et ajoute `NET_RAW` — `baseline` interdit **les deux**. [`namespace.yaml`](namespace.yaml) est donc **obligatoire** sur Talos et **documentaire** sur kubeadm. |
| Interface host-only | toujours `enp0s8` | `eth1` ou `enp0s8` selon la box → **détectée** dans `_out/cluster.env` | `HOSTONLY_IF` couvre les deux ; le script la substitue dans `metallb-l2.yml`. |
| `kube-proxy` | optionnel, mais `KUBE_PROXY_REPLACEMENT=true` force `CNI=cilium` | idem | MetalLB n'est installé que si le CNI n'est **pas** Cilium, donc `KUBE_PROXY_REPLACEMENT` y vaut forcément `false` : MetalLB trouve toujours un kube-proxy devant lui, sur les deux labs. |
| CNI probable à côté | `calico`, ou `flannel` **pré-installé au bootstrap** | `calico`, ou `flannel` installé par `platform-up.sh` | Aucun effet sur MetalLB : il ne voit que des nodes `Ready` et des Services. |

> ℹ️ Aucune variable de profil n'a été ajoutée pour ce composant : rien ici ne lit
> `lib/profiles/<distro>.sh` au-delà de `DEFAULT_HOSTONLY_IF`, qui existait déjà. La divergence
> PodSecurity est portée par un manifeste de namespace appliqué **dans les deux cas** — la règle
> du dépôt : étiqueter le namespace partout, même là où ça ne débloque rien aujourd'hui.

## 🎓 Pas à pas guidé (formation)

La même chose que le script, une commande à la fois. Pose d'abord tes variables :

```bash
export KUBECONFIG="$PWD/kubeconfig"           # depuis la racine du lab
LB_POOL_START=$(sed -n 's/^LB_POOL_START=//p' lab.env | head -1 | tr -d ' "')
LB_POOL_END=$(sed -n 's/^LB_POOL_END=//p'     lab.env | head -1 | tr -d ' "')
HOSTONLY_IF=$(sed -n 's/^HOSTONLY_IF=//p' _out/cluster.env | head -1)   # kubeadm
HOSTONLY_IF=${HOSTONLY_IF:-enp0s8}                                      # Talos
echo "$LB_POOL_START-$LB_POOL_END sur $HOSTONLY_IF"
```

### 1. Vérifier le point de départ

```bash
kubectl get nodes                         # tous Ready — le CNI est déjà là
kubectl get ciliuml2announcementpolicies.cilium.io 2>/dev/null   # DOIT être vide / pas de CRD
kubectl -n envoy-gateway-system get svc   # EXTERNAL-IP <pending>, si la Gateway est debout
```

### 2. Le namespace, avant le chart

```bash
kubectl apply -f metallb/namespace.yaml
kubectl get ns metallb-system --show-labels     # pod-security.kubernetes.io/enforce=privileged
```

### 3. Ajouter le dépôt Helm

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update metallb
```

### 4. Installer MetalLB — L2 uniquement, sans FRR

```bash
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system \
  --version 0.16.1 \
  --set frrk8s.enabled=false \
  --set speaker.frr.enabled=false
```

### 5. Attendre le controller et les speakers

```bash
kubectl -n metallb-system rollout status deploy/metallb-controller --timeout=300s
kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=300s
```

### 6. Appliquer le pool + l'annonce L2

```bash
# Les valeurs versionnées sont les défauts du lab : substitue les tiennes, comme le fait le script
sed -e "s/192\.168\.56\.200/${LB_POOL_START}/g" \
    -e "s/192\.168\.56\.230/${LB_POOL_END}/g" \
    -e "s/enp0s8/${HOSTONLY_IF}/g" \
    metallb/metallb-l2.yml | kubectl apply -f -
```

> ⚠️ Si ça échoue en `connection refused` ou sur une erreur `x509` visant
> `metallb-webhook-service`, tu es simplement **en avance** : le controller injecte son propre
> certificat dans la `ValidatingWebhookConfiguration`, ce qui prend quelques secondes après le
> rollout. Réessaie. C'est exactement ce que fait la boucle du script.

### 7. Vérifier

```bash
kubectl -n metallb-system get ipaddresspool,l2advertisement
kubectl -n envoy-gateway-system get svc          # EXTERNAL-IP = 192.168.56.200
kubectl get servicel2status -A -o wide           # quel node annonce quelle IP
```

## 🔧 Ce que fait le script

| Étape | Quoi | Pourquoi ce n'est pas juste un `helm install` |
|---|---|---|
| garde-fous | refuse si Cilium annonce, ou si `CNI=cilium` ; refuse si aucun node n'est `Ready` | deux annonceurs ARP sur une plage, c'est la panne la plus illisible de ce lab ; et MetalLB sur un cluster sans CNI reste `Pending` 5 min avant de dire quoi que ce soit |
| `[1/3]` | `namespace.yaml` **puis** le chart | `helm --create-namespace` ne pose aucun label PodSecurity — et leur absence échoue **en silence** (voir plus bas) |
| `[2/3]` | `rollout status` sur le controller **et** le DaemonSet | le controller attribue, les speakers annoncent : une IP sans speaker est attribuée et injoignable |
| `[3/3]` | `metallb-l2.yml` rendu, appliqué **avec réessai** | le webhook de validation est servi par le controller et met quelques secondes à présenter un certificat de confiance |

### Fichiers

| Fichier | Rôle |
|---|---|
| [`metallb-up.sh`](metallb-up.sh) | l'installation tout-en-un, idempotente |
| [`namespace.yaml`](namespace.yaml) | `metallb-system` + les trois labels PodSecurity `privileged` |
| [`metallb-l2.yml`](metallb-l2.yml) | `IPAddressPool` + `L2Advertisement` — le miroir strict de [`../cilium/cilium-l2.yml`](../cilium/cilium-l2.yml) |

### Les réglages Helm qui comptent

| `--set` | Valeur | Pourquoi |
|---|---|---|
| `frrk8s.enabled` | `false` | Depuis le chart 0.15 le sous-chart FRR-K8s est **activé par défaut** : un démon de routage FRR complet sur chaque node, pour BGP. Ce lab annonce en L2 uniquement (pas de routeur pair sur un réseau host-only VirtualBox) — du poids mort. |
| `speaker.frr.enabled` | `false` | L'autre manière, dépréciée, de faire entrer FRR dans le pod speaker. Le chart **refuse les deux à la fois** : on les coupe donc explicitement plutôt que de faire confiance à celui qui vaut `false` par défaut dans la version du jour. |

Tout le reste reste au défaut du chart, volontairement — en particulier
`speaker.tolerateMaster=true`, qui fait tourner un speaker sur les control planes aussi. C'est
sans conséquence : ce qui décide qui annonce, c'est le `nodeSelectors` de la `L2Advertisement`,
exactement comme la policy Cilium.

### `metallb-l2.yml` — deux objets

- **`IPAddressPool`** — la plage, écrite en une seule chaîne `start-stop` (Cilium utilise deux
  champs). `autoAssign: true` : la Gateway ne demande aucune adresse en particulier et reçoit la
  première libre.
- **`L2Advertisement`** — qui annonce, et sur quelle carte. `ipAddressPools` nomme le pool (sans
  lui l'annonce couvrirait tous les pools), `interfaces` épingle la carte host-only et
  `nodeSelectors` écarte les control planes.

## ✅ Vérifier

```bash
kubectl -n metallb-system get pods                      # 1 controller + 1 speaker par node
kubectl -n metallb-system get ipaddresspool -o wide     # la plage
kubectl -n metallb-system get l2advertisement -o yaml | grep -A4 interfaces

# La Gateway doit avoir pris la PREMIÈRE IP du pool
kubectl -n envoy-gateway-system get svc

# Qui annonce quoi (l'équivalent MetalLB des leases Cilium)
kubectl get servicel2status -A -o wide
```

Et surtout, **l'IP doit répondre** — ce qu'aucun `kubectl get` ne prouve :

```bash
GWIP=$(kubectl -n envoy-gateway-system get svc \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}')
curl -s -o /dev/null -w '%{http_code}\n' "http://$GWIP/"   # 404 = Envoy répond (pas encore de route)
ip neigh show "$GWIP"                                      # ARP résolu = annonce L2 OK
```

> ⚠️ **Ne teste JAMAIS cette IP au `ping`.** Aucune interface ne porte réellement l'adresse : le
> speaker élu se contente de répondre à l'**ARP** pour attirer le trafic, puis le node
> l'achemine. L'ICMP vers le VIP ne reçoit donc rien, alors qu'un `ping` sur un *node* (`.101`)
> fonctionne — un faux négatif très convaincant. La preuve de l'annonce, c'est l'entrée ARP qui
> se résout vers la MAC d'un worker :
> ```bash
> ip neigh flush "$GWIP"; curl -s -o /dev/null --max-time 5 "http://$GWIP/"
> ip neigh show "$GWIP"     # lladdr = MAC du worker élu
> ```

## 🧪 Scénario — bascule de speaker

La démo qui justifie le composant : l'annonce survit à la perte d'un node.

```bash
kubectl get servicel2status -A -o wide          # note le node annonceur, p. ex. k8s-w2
ip neigh show "$GWIP"                           # note la MAC

# Retire le speaker de ce node
kubectl -n metallb-system delete pod -l app.kubernetes.io/component=speaker \
  --field-selector spec.nodeName=k8s-w2

# Quelques secondes plus tard, un autre worker a repris la main
kubectl get servicel2status -A -o wide
ip neigh flush "$GWIP"; curl -s -o /dev/null -w '%{http_code}\n' "http://$GWIP/"
ip neigh show "$GWIP"                           # une AUTRE MAC — la même IP
```

Les quelques secondes de coupure, c'est le ré-ARP : attendu, pas un incident.

## 🚑 Dépannage

| Symptôme | Cause probable | Quoi faire |
|---|---|---|
| Le script échoue sur « Cilium already announces » | tu es en `CNI=cilium` — le défaut du lab | c'est le garde-fou, pas un bug : Cilium le fait déjà. Voir ⚠️ Pièges |
| Le script échoue sur « no Ready node » | aucun CNI installé | installe d'abord le CNI — MetalLB n'en est pas un |
| `EXTERNAL-IP` reste `<pending>` **avec** un pool valide | le Service porte encore `loadBalancerClass: io.cilium/l2-announcer` | `platform-up.sh` retire cette ligne quand `CNI != cilium` ; vérifie `kubectl -n envoy-gateway-system get svc -o yaml \| grep -i loadbalancerclass` |
| `EXTERNAL-IP` posée mais rien ne répond | **zéro** pod speaker → PodSecurity a refusé le DaemonSet | `kubectl -n metallb-system describe ds/metallb-speaker`, puis applique [`namespace.yaml`](namespace.yaml) et `rollout restart` |
| L'application du pool échoue en `connection refused` / `x509` | le webhook du controller ne sert pas encore | attends 10 s et réessaie — le script boucle 150 s |
| L'ARP se résout vers un **control plane** | les `nodeSelectors` ont sauté ou le label diffère | `kubectl -n metallb-system get l2advertisement -o yaml` |
| L'ARP ne se résout pas du tout | annonce sur la carte NAT, ou `interfaces` écrit comme une regex | `kubectl -n metallb-system get l2advertisement -o yaml` — il doit y avoir `enp0s8`, **pas** `^enp0s8$` |
| `no available IPs` dans les logs du controller | pool épuisé (31 adresses) ou deux Services demandant une IP fixe | `kubectl -n metallb-system logs deploy/metallb-controller` |

## ⚠️ Pièges

- **Jamais MetalLB *et* l'annonce L2 de Cilium.** Deux speakers répondant à l'ARP pour
  `192.168.56.200` font osciller le cache ARP de l'hôte entre deux MAC : le point d'entrée
  marche « une fois sur deux », et aucun log ne le dit. Le script refuse sur deux signaux
  indépendants (les objets `cilium.io` vivants, et `CNI` qui résout vers `cilium`) — ne le
  contourne pas, la bonne réaction est de choisir un CNI.
- **`interfaces:` est une liste de noms bruts, pas de regex.** La policy Cilium prend
  `^enp0s8$` ; MetalLB prend `enp0s8`. Recopier la syntaxe Cilium ne correspond à **aucune**
  interface et l'annonce est abandonnée **en silence** : pool valide, IP attribuée, ARP muet.
- **`loadBalancerClass` l'emporte sur n'importe quel pool.** Tant que
  [`../envoy-gateway/Envoy-Proxy.yml`](../envoy-gateway/Envoy-Proxy.yml) épingle
  `loadBalancerClass: io.cilium/l2-announcer`, MetalLB **ignore** le Service — une
  `loadBalancerClass` signifie « seul ce contrôleur a le droit de le servir ». `platform-up.sh`
  retire la ligne quand `CNI != cilium` ; appliquer ce manifeste à la main, non.
- **Les labels `privileged` ne sont pas cosmétiques, et leur absence te ment.** Le `controller`
  n'est pas privilégié : il démarre, attribue, et écrit une `EXTERNAL-IP` parfaitement normale
  dans le Service. Seul le `speaker` est refusé — tu obtiens donc une adresse qui a l'air posée
  et qui ne répond à rien. Recoupe toujours `get svc` avec `kubectl -n metallb-system get pods`.
- **`WORKERS=0` ne laisse personne pour annoncer.** Les `nodeSelectors` écartent les control
  planes, volontairement. Sur un lab sans worker, retire-les de `metallb-l2.yml` — sinon le pool
  est valide et personne ne l'annonce.
- **Un node par IP, ce n'est pas de la répartition de charge.** Comme
  `CiliumL2AnnouncementPolicy`, le mode L2 élit un seul speaker par adresse : tout le trafic du
  VIP entre par ce node, puis kube-proxy le répartit sur les endpoints. Une bascule prend
  quelques secondes (le temps du ré-ARP).
- **`kube-proxy` en mode IPVS exige `strictARP: true`.** Aucun des deux labs n'utilise IPVS
  (tous deux sont en mode iptables), donc ça ne mord pas ici — mais c'est la première chose à
  vérifier si tu emportes ce composant sur un autre cluster : en IPVS sans `strictARP`, tous les
  nodes répondent à l'ARP du VIP.
- **Changer de CNI n'est pas une bascule à chaud.** Passer de Cilium à Calico impose de
  reconstruire le cluster (`./kubeadm/cluster-reset.sh`, ou `vagrant destroy`), pas un
  `helm uninstall`. MetalLB n'a de sens que sur un cluster bootstrapé avec le bon `CNI` dès le
  départ.

## 🧹 Désinstaller

```bash
kubectl -n metallb-system delete -f metallb/metallb-l2.yml    # arrêter d'annoncer d'abord
helm uninstall metallb -n metallb-system
kubectl delete ns metallb-system
```

> ⚠️ Tous les Services `LoadBalancer` retombent en `EXTERNAL-IP <pending>` et toutes les UI
> deviennent injoignables — la Gateway comprise. Les CRD partent avec le chart, donc tout
> `IPAddressPool` résiduel disparaît avec elles.

## 📚 Références

- [MetalLB — Layer 2 configuration](https://metallb.io/configuration/#layer-2-configuration)
- [MetalLB — Installation by Helm](https://metallb.io/installation/#installation-with-helm)
- [MetalLB — Layer 2 limitations (goulot mono-node, bascule)](https://metallb.io/concepts/layer2/)
- [`../cilium/LISEZ-MOI.md`](../cilium/LISEZ-MOI.md) — le CNI par défaut, qui annonce tout seul
- [`../calico/LISEZ-MOI.md`](../calico/LISEZ-MOI.md) — le CNI alternatif qui rend ce composant nécessaire
- [`../envoy-gateway/LISEZ-MOI.md`](../envoy-gateway/LISEZ-MOI.md) — le consommateur du VIP `.200`
