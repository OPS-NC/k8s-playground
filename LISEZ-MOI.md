<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# ☸️ k8s-playground — les ressources Kubernetes des labs Talos **et** kubeadm

> **Un seul dépôt de manifestes et de charts pour deux labs Vagrant.** La couche
> applicative (CNI, Gateway API, stockage, secrets, observabilité, sécurité) était
> **dupliquée**, dans `Vagrant-Talos/_k8s/` puis encore dans `Vagrant-KubeADM/_k8s/`. Elle vit
> maintenant ici, **une seule fois** — et les deux labs montent *ce* dépôt à ce même
> emplacement `_k8s/`, en **sous-module git**. Monté ainsi, le lab **et** sa distribution sont
> trouvés tout seuls — pas d'argument, pas de variable d'environnement, pas de `lab.env` ici :
>
> ```bash
> ./_k8s/platform-up.sh                # depuis la racine de l'un ou l'autre lab (sous-module)
> ./_k8s/install.sh platform           # la même chose, par le point d'entrée
> ./install.sh kubeadm platform        # depuis la racine de ce dépôt    (dépôts voisins)
> ```

📖 **Documentation navigable** : <https://ops-nc.github.io/k8s-playground/> — une page
unique et autonome, bilingue (EN/FR) avec thème sombre/clair, régénérée depuis ces mêmes
`README.md` / `LISEZ-MOI.md` à chaque push sur `main` (`make docs` pour la construire en local).

Les deux labs restent responsables du **bootstrap du cluster** (VM, OS, `kubeadm init` /
`talosctl bootstrap`). Ce dépôt ne s'occupe que de ce qui vient **après**, avec `kubectl` et
`helm` depuis l'hôte — **y compris le CNI**, car aucun des deux bootstraps ne laisse un réseau
pod utilisable.

## ⚡ Démarrage rapide

On ne démarre jamais ici : on démarre **dans un lab**, là où vivent le cluster et son état. Ce
dépôt y est monté en sous-module, sur `_k8s/`.

```bash
# 1. Le lab — sous-module compris (jumeau Talos : OPS-NC/Vagrant-Talos)
git clone --recurse-submodules https://github.com/OPS-NC/Vagrant-kubeadm.git
cd Vagrant-kubeadm
cp lab.env.example lab.env               # le modèle du LAB : topologie, domaine, TLS, CNI
vagrant up && ./kubeadm/cluster-up.sh    # les nodes sont NotReady : pas encore de CNI

# 2. Poser la plateforme de base — rien à déclarer
./_k8s/platform-up.sh                # CNI → Envoy Gateway → metrics-server → wildcard TLS

# 3. Les addons, à la carte
./_k8s/install.sh longhorn vault argocd
./_k8s/install.sh list               # le catalogue complet
./_k8s/install.sh all                # plateforme + tous les addons, dans le bon ordre
```

> 💡 **Rien à déclarer, et c'est tout l'intérêt.** Depuis la racine du lab, ce dépôt est
> `<lab>/_k8s` : le lab est son **parent**, reconnu à son `Vagrantfile`, et la distribution se
> lit sur la structure de ce lab — `kubeadm/cluster-up.sh` ici, `talos/cluster-up.sh` chez le
> jumeau Talos. `LAB_DIR` n'est plus nécessaire, l'argument `talos`/`kubeadm` non plus.
> `KUBECONFIG` est dérivé de la même façon (`<lab>/kubeconfig`) ; ne l'exporte que pour **tes
> propres** appels `kubectl`, pas pour les scripts.

Passer la distribution explicitement reste possible, et reste prioritaire — utile pour être sûr
de ce qu'on lance, ou en disposition voisine ci-dessous :

```bash
./_k8s/install.sh kubeadm platform
```

<details>
<summary>Variante — les deux dépôts côte à côte (la disposition d'avant, toujours supportée)</summary>

```bash
cd ../Vagrant-Talos    && ./talos/cluster-up.sh        # ou
cd ../Vagrant-KubeADM  && ./kubeadm/cluster-up.sh

cd ../k8s-playground                 # ce dépôt, voisin du lab
./install.sh talos platform          # ici la distribution vaut la peine d'être passée (cf. plus bas)
```

Ici le dépôt du lab est **à côté** de celui-ci — pas au-dessus — donc la règle du
parent-`Vagrantfile` ne se déclenche pas et le lab n'est trouvé que par `LAB_REPO_NAME`
(`../Vagrant-Talos`, `../Vagrant-KubeADM`), que pose le **profil de distribution**. La
distribution doit donc venir d'ailleurs que du lab : passe-la en argument. C'est la **seule**
différence entre les deux dispositions.
</details>

Chaque composant reste **lançable seul**, nu en disposition sous-module :

```bash
./_k8s/longhorn/longhorn-up.sh               # depuis la racine du lab  (sous-module)
./observability/observability-up.sh talos    # depuis la racine d'ici   (dépôts voisins)
```

> 🎓 **Mode formation.** Chaque dossier a un `README.md` (EN) / `LISEZ-MOI.md` (FR) avec la
> section **« Pas à pas guidé »** : la même installation, mais **commande par commande**, avec
> ce qu'il faut observer à chaque étape et les variantes propres à chaque distribution. Le
> script « tout-en-un » et le pas-à-pas font strictement la même chose.

## 🧩 Deux dispositions : sous-module ou dépôts voisins

Les deux labs montent ce dépôt en **sous-module git**, sur `_k8s/`, à leur racine. C'est la
disposition **normale**, celle que supposent toutes les commandes des labs. Garder les deux
dépôts **côte à côte** — ce qui existait avant — fonctionne toujours et reste documenté ici
comme la variante.

| | **Sous-module** (recommandée) | **Dépôts voisins** (variante) |
|---|---|---|
| Sur le disque | `Vagrant-KubeADM/_k8s/` **est** ce dépôt | `Vagrant-KubeADM/` et `k8s-playground/` dans le même dossier parent |
| Où l'on lance les scripts | depuis la racine du **lab** : `./_k8s/install.sh …` | depuis la racine de **ce** dépôt : `./install.sh <distro> …` |
| `LAB_DIR` | **inutile** : le parent porte un `Vagrantfile` ⇒ règle 2 ci-dessous | **inutile** aussi : la règle 3 ci-dessous trouve `../<dépôt du lab>` toute seule |
| Argument de distribution | **inutile** : lu sur la structure du lab | **à passer** : aucun lab n'est localisé avant le chargement du profil, il ne reste que le signal de dernier recours |
| Version de la couche applicative | **épinglée** par le lab sur un commit ⇒ le lab est reproductible | celle qui traîne à côté, quelle qu'elle soit |
| Comment l'obtenir | `git clone --recurse-submodules …`, ou `git submodule update --init --recursive` | un `git clone` par dépôt |
| Comment la mettre à jour | `git submodule update --remote _k8s`, puis committer le pointeur déplacé | `git pull` ici |
| Contrainte de nommage | aucune : `_k8s/` est imposé par les labs, et les deux l'utilisent | le dossier du lab **doit** s'appeler exactement `Vagrant-Talos` / `Vagrant-KubeADM` (`LAB_REPO_NAME`), sinon `LAB_DIR` de nouveau |

Installer et mettre à jour le sous-module, depuis le lab :

```bash
git clone --recurse-submodules https://github.com/OPS-NC/Vagrant-kubeadm.git
git submodule update --init --recursive   # remplit _k8s/ sur un clone déjà fait
git submodule update --remote _k8s        # amène _k8s/ sur le dernier commit de ce dépôt
```

> ⚠️ **Un `git pull` dans le lab ne met PAS le sous-module à jour.** Il ne déplace que le dépôt
> du lab ; `_k8s/` reste sur le commit épinglé avant, et l'on jouerait alors les commandes
> documentées contre une couche applicative **plus ancienne**. Enchaîne chaque pull avec
> `git submodule update --init --recursive`. Et un `_k8s/` vide — `./_k8s/install.sh: No such
> file or directory` — ne veut jamais dire qu'une chose : le sous-module n'a jamais été
> initialisé.

> 💡 **Modifier cette couche, c'est modifier *ici*.** Vu depuis un lab, `_k8s/` est une copie
> de travail de ce dépôt sur un **HEAD détaché** : les fichiers qu'on y édite appartiennent à
> ce dépôt, pas au lab, et un `git commit` lancé dans `_k8s/` committe **ici**. Le chemin est
> donc : PR sur ce dépôt → merge → dans le lab, `git submodule update --remote _k8s`, puis
> commit du pointeur bumpé (`git status` affiche `modified: _k8s (new commits)`). Ce commit
> **est** la montée de version de la couche applicative, et c'est lui qui garde le lab
> reproductible.

## 📍 Où sont trouvés `lab.env` et `_out/`

Les scripts ne stockent **rien**. `lab.env` (l'intention : domaine, mode TLS, CNI, taille des
VM) et `_out/` (les faits : `talosconfig`, `cluster.env`, l'AC locale dans `_out/self-signed/`,
`_out/vault-init.json`…) vivent dans le dépôt du **lab**, avec le `kubeconfig` juste à côté, à
sa racine. Il n'y a qu'**une** source de vérité pour la topologie, celle du lab — c'est
pourquoi ce dépôt ne porte ni `lab.env`, ni modèle de `lab.env`. `_resoudre_lab_dir()`, dans
`lib/common.sh`, cherche ce dossier dans cet ordre :

| # | Candidat | S'applique quand |
|---|---|---|
| 1 | `$LAB_DIR`, à défaut le dossier qui porte `$LAB_ENV` | l'une des deux est exportée — surcharge explicite, **gagne toujours** |
| 2 | le dossier **parent** de ce dépôt, s'il porte un `Vagrantfile` | **disposition sous-module** : ce dépôt *est* `<lab>/_k8s`, le lab est donc juste au-dessus |
| 3 | `<racine de ce dépôt>/../$LAB_REPO_NAME` — `Vagrant-Talos` ou `Vagrant-KubeADM`, posé par le profil de distribution | ce dossier existe ⇒ **dépôts voisins** (seulement une fois le profil chargé) |
| 4 | la racine de **ce** dépôt | un fichier `lab.env` ou un dossier `_out/` s'y trouve (un lien symbolique compte) — usage autonome |
| 5 | repli : la racine de ce dépôt | rien de ce qui précède n'a matché |

`KUBECONFIG` suit le même dossier : s'il n'est pas déjà exporté, il devient
`<dossier du lab>/kubeconfig`.

> ℹ️ **Pourquoi le test porte sur `Vagrantfile`, et pourquoi il passe avant la règle 4.** Un
> `Vagrantfile` est la marque non ambiguë d'un lab : il est là **dès le clone**, avant tout
> `vagrant up`, et il n'apparaît jamais au-dessus de ce dépôt en disposition voisine — où le
> parent n'est qu'un dossier de travail quelconque. L'ordonner **avant** la règle « racine de
> ce dépôt » est délibéré : un `_out/` résiduel (ou un `lab.env` déposé ici pour un test
> ponctuel) ne doit jamais masquer le vrai lab qui se trouve juste au-dessus. `LAB_DIR` /
> `LAB_ENV` restent au-dessus de tout : une surcharge qu'on peut mettre en minorité n'est pas
> une surcharge.

> ⚠️ **C'est exactement la panne que la règle du parent supprime.** Avant elle, la disposition
> sous-module résolvait `<racine>/../Vagrant-KubeADM` en `Vagrant-KubeADM/Vagrant-KubeADM` — un
> chemin qui n'existe pas — et retombait sur *ce dépôt lui-même*, qui ne porte ni `lab.env` ni
> `_out/`. Rien ne cassait bruyamment : les scripts tournaient avec les **défauts du profil** —
> `<distro>.lab.example.io` au lieu de ton `LAB_DOMAIN` (donc un Secret TLS wildcard sous un
> nom qu'aucun addon n'irait chercher), `CNI=cilium` au lieu du CNI choisi, `POD_CIDR` /
> `HOSTONLY_IF` / `KUBE_PROXY_REPLACEMENT` DEVINÉS au lieu de ceux détectés par
> `cluster-up.sh`, et un `KUBECONFIG` pointant sur un fichier inexistant. Si tu revois cette
> forme de symptôme, c'est un problème de **résolution** : lis d'abord la ligne de résumé.

> 💡 **Un signal se déclenche quand même, sur kubeadm seulement.** `platform-up.sh` avertit
> quand `_out/cluster.env` est absent — *« `./kubeadm/cluster-up.sh` n'a pas (ou pas jusqu'au
> bout) été lancé »*. Deux lectures : soit le bootstrap n'est effectivement pas allé au bout,
> soit ce n'est pas le bon lab qui a été résolu. L'avertissement est **non bloquant**, et sur
> Talos il n'a pas d'équivalent (ce lab n'a pas de `cluster.env`).

Chaque script affiche sa résolution avant de toucher à quoi que ce soit — une ligne, à lire :

```
    profil kubeadm (Debian 13 + kubeadm) · domaine *.kubeadm.lab.example.io · lab.env absent (défauts)
```

`lab.env absent (défauts)` sur un lab qui *a* pourtant un `lab.env`, ou un `domaine` qui n'est
pas celui que tu as posé : la résolution a manqué le lab — force-la avec `LAB_DIR`.

Tout surcharger à la main reste possible — utile pour un lab rangé ailleurs, ou pour exercer ce
dépôt isolément :

```bash
LAB_DIR=~/labs/mon-lab   ./install.sh talos platform      # lab.env + _out/ + kubeconfig, tout est là
LAB_ENV=~/labs/mon-lab/lab.env  ./install.sh talos platform   # son dossier devient le dossier du lab
LAB_ENV=~/labs/mon-lab/lab.env  KUBECONFIG=~/labs/mon-lab/kubeconfig  ./install.sh talos platform
```

> ⚠️ **Ne crée pas de `lab.env` à la racine de ce dépôt.** La règle 4 en accepte un, et il est
> là pour exercer ce dépôt sans aucun lab — mais un second `lab.env` est une seconde vérité,
> qui diverge de celle du lab dès que l'une des deux bouge. C'est précisément pour ça qu'il n'y
> a **pas de `lab.env.example` ici** : le modèle à copier vit dans le lab.

## 🎯 Comment la distribution est choisie

Par ordre de priorité :

| # | Source | Exemple |
|---|---|---|
| 1 | 1er argument positionnel | `./install.sh talos longhorn` · `./longhorn/longhorn-up.sh talos` |
| 2 | `--distro=` | `./platform-up.sh --distro=kubeadm` |
| 3 | variable d'environnement | `K8S_DISTRO=talos ./install.sh longhorn` |
| 4 | `DISTRO=` dans le `lab.env` du lab | `DISTRO=kubeadm` |
| 5 | la **structure** du lab | `talos/cluster-up.sh` → `talos` · `kubeadm/cluster-up.sh` → `kubeadm` |
| 6 | les **artefacts de bootstrap** du lab | `_out/talosconfig` → `talos` · `_out/cluster.env` → `kubeadm` |
| 7 | **sondage** du cluster | `osImage` du 1er node : `Talos …` → `talos`, sinon `kubeadm` |

Les sources 5 à 7 sont `_detecter_distro()`, trois familles de signaux classées par la
précocité avec laquelle elles deviennent disponibles :

| Signal | Disponible dès | Coût |
|---|---|---|
| **structure** — le script de bootstrap de la distribution que le lab implémente | le `git clone`, **avant tout `vagrant up`** | nul : un test de fichier |
| **artefacts** — ce que le bootstrap a écrit dans `_out/` | après `cluster-up.sh` | nul : un test de fichier. Couvre un lab dont les dossiers ont été renommés |
| **sondage** — `kubectl get nodes -o jsonpath=…osImage` | un cluster debout **et** un `KUBECONFIG` qui pointe déjà dessus | dernier recours seulement |

> ℹ️ **Pourquoi le sondage est en dernier.** Il exige un `KUBECONFIG` déjà correct — or
> `KUBECONFIG` est dérivé du dossier du lab, qui vient du *profil*, qui n'est chargé qu'une
> fois la distribution connue. Par construction, le sondage est donc le signal le moins
> disponible à l'instant précis où on en a besoin : il ne répond jamais que pour un contexte
> `kubectl` ambiant. Les sources 5 et 6 lisent le lab directement et n'ont pas cette
> dépendance.

Sans aucune de ces sources, les scripts **refusent de démarrer** : appliquer un manifeste
pensé pour Talos sur Debian (ou l'inverse) ne produit pas une erreur franche mais une panne
silencieuse — un `Deployment` créé dont aucun pod ne démarre, par exemple.

> ℹ️ **Les sources 4 à 6 exigent que le lab soit localisé d'abord — et c'est là que la
> disposition compte.** En **sous-module**, la règle du parent-`Vagrantfile` s'applique avant
> tout chargement de profil : les trois fonctionnent donc nues, et c'est ce qui rend
> `./_k8s/platform-up.sh` autosuffisant. En **dépôts voisins**, le lab n'est joignable que par
> `LAB_REPO_NAME`, que pose le profil — celui-là même qu'on cherche à choisir. La résolution
> poursuit alors jusqu'au sondage (source 7). Depuis la racine de ce dépôt : passe la
> distribution, ou exporte `LAB_DIR`. Un argument explicite court-circuite toute la question et
> reste le moyen le plus sûr de savoir ce qu'on a lancé.

## 🧬 Ce qui diffère vraiment entre les deux labs

Tout est concentré dans **`lib/profiles/talos.sh`** et **`lib/profiles/kubeadm.sh`** : les
scripts d'installation ne testent jamais la distribution à coups de `if` dispersés, ils lisent
des variables.

| Sujet | Talos Linux | Debian 13 + kubeadm | Variable du profil |
|---|---|---|---|
| **Domaine par défaut des UI** | `talos.lab.example.io` | `kubeadm.lab.example.io` | `DEFAULT_LAB_DOMAIN` |
| **PodSecurity (niveau cluster)** | `baseline` **appliqué** → un pod privilégié exige un namespace étiqueté `privileged`, sinon échec **silencieux** | aucun niveau appliqué → les mêmes labels ne débloquent rien, ils documentent l'intention | `PODSECURITY_DEFAUT` |
| **Système de fichiers** | immuable : `/` et `/usr` en lecture seule, seul `/var` est inscriptible | ordinaire, tout est inscriptible | — |
| **local-path-provisioner** | `/var/local-path-provisioner` | `/opt/local-path-provisioner` (chemin amont) | `LOCAL_PATH_DIR` |
| **Prérequis iSCSI (Longhorn)** | **extension** `iscsi-tools` cuite dans l'image d'install (irrécupérable à chaud) + montage kubelet `rshared` via `talosctl patch mc` | **paquet** `open-iscsi` posé par `provision.sh` ; `/var/lib/longhorn` est un dossier ordinaire | `LONGHORN_PREP_REQUISE` |
| **kube-proxy** | toujours posé par le bootstrap, non remplaçable ici | **optionnel** : remplaçable par Cilium en eBPF (`KUBE_PROXY_REPLACEMENT=true`, défaut du lab) | `KUBE_PROXY_REPLACEABLE` |
| **Cilium — IPAM** | `ipam.mode=kubernetes` (podCIDR posés par le kube-controller-manager) | `ipam.mode=cluster-pool` (l'opérateur Cilium découpe le CIDR pod) | `CILIUM_IPAM_MODE` |
| **Cilium — valeurs OS** | `cgroup.autoMount=false` + `cgroup.hostRoot` + capabilities explicites (**exigés**) | aucune : les défauts du chart sont les bons, les forcer serait **nuisible** | `cilium_sets_specifiques()` |
| **Calico** | `flexVolumePath: None` et CSI `None` **obligatoires** (`/usr` en lecture seule) | mêmes réglages, mais comme simple allègement | (manifeste commun) |
| **flannel (`CNI=flannel`)** | déjà posé par le bootstrap Talos → rien à installer | installé ici par le chart `flannel/flannel` | `FLANNEL_PRE_INSTALLED` |
| **Trivy — scanners « node »** | **désactivés** : le `node-collector` bind-monte `/etc/systemd` → `read-only file system` | activés : les chemins existent et sont lisibles | `TRIVY_NODE_COLLECTOR` |
| **Prometheus — control plane** | moniteurs etcd/scheduler/controller-manager **coupés** (non scrutables sans TLS dédié) | **activés** : `bind-address: 0.0.0.0` et `listen-metrics-urls` posés au bootstrap | `KPS_SCRAPE_CONTROL_PLANE` |
| **Interface host-only** | `enp0s8` | `eth1` ou `enp0s8` selon la box → **détectée** dans `_out/cluster.env` | `DEFAULT_HOSTONLY_IF` |
| **Faits du cluster** | `_out/controlplane.yaml` (`podSubnets`) | `_out/cluster.env` (CIDR, interface, kube-proxy) | — |
| **Moteur KV Vault de démo** | `talos-lab/` | `kubeadm-lab/` | `VAULT_KV_MOUNT` |
| **AC auto-signée** | `O=Vagrant-Talos lab` | `O=Vagrant-KubeADM lab` | `CA_ORG`, `CA_FILE_NAME` |

Tout le reste — Argo CD, Kyverno, MinIO, CloudNativePG, Vault, Envoy Gateway, cert-manager,
chaoskube, node-problem-detector, WordPress — est **strictement identique** sur les deux
distributions.

## 🗂️ Organisation du dépôt

```
install.sh                  point d'entrée : ./install.sh [talos|kubeadm] <composant...>
platform-up.sh              la plateforme de base (CNI → Gateway → metrics → TLS)
metric-server.yaml          metrics-server (appliqué par platform-up.sh)
lib/
  common.sh                 socle commun : résolution de la distro, lecture lab.env, helpers
  profiles/talos.sh         TOUT ce qui est propre à Talos
  profiles/kubeadm.sh       TOUT ce qui est propre à kubeadm/Debian
<composant>/
  <composant>-up.sh         l'installation « tout-en-un »
  values.yaml / *.yaml      manifestes et values (valeurs NEUTRES, substituées à la volée)
  README.md / LISEZ-MOI.md  doc EN/FR + pas-à-pas guidé
docs/build.py               construit la page unique depuis tous les README (make docs)
Makefile                    docs, docs-check, validate — tout ce qui tourne sans cluster
```

En sous-module, tout cet arbre est sous le `_k8s/` du lab — `./_k8s/install.sh`,
`./_k8s/longhorn/longhorn-up.sh`, etc. Rien d'autre ne bouge : les chemins *internes* à ce
dépôt sont les mêmes dans les deux dispositions, et c'est pour ça que chaque pas-à-pas est
écrit depuis la racine de ce dépôt.

Il n'y a **ni `Vagrantfile`, ni `_out/`, ni `lab.env` ici**, et c'est voulu : ce dépôt porte
les manifestes, le lab porte le cluster et son état. Cette absence est structurante — c'est
elle qui fait de « le parent porte un `Vagrantfile` » un repère non ambigu, et qui empêche un
second `lab.env` de venir concurrencer le vrai. Cf.
[Où sont trouvés `lab.env` et `_out/`](#-où-sont-trouvés-labenv-et-_out).

## 🔗 Chaîne de dépendances

Chaque maillon suppose le précédent : pas d'IP LoadBalancer sans annonceur L2, pas de HTTPS
sans Gateway, pas d'UI sans certificat sur l'écouteur `:443`.

```
cluster bootstrapé  (lab Talos ou lab kubeadm — nodes NotReady, pas encore de CNI)
   │
   ├─ 1. CNI              cilium/ (défaut, + pool L2 → IP LoadBalancer .200)
   │                      ou calico/ (CNI seul) ou flannel (CNI seul) ou rien
   ├─ 2. envoy-gateway/   contrôleur Envoy + main-gateway (écouteurs :80 et :443)
   ├─ 3. metric-server    API metrics.k8s.io  (kubectl top, HPA)
   └─ 4. wildcard TLS     *.<LAB_DOMAIN> — deux modes selon SELF_SIGNED
              │             true (défaut) → self-signed/   openssl, AC locale
              │             false         → cert-manager/  Let's Encrypt DNS-01 Cloudflare
              │
              └─ addons : stockage → bases → secrets → observabilité → sécurité
```

C'est exactement l'ordre de `platform-up.sh` (`[1/4]` → `[4/4]`). Les deux modes TLS
remplissent le **même** Secret (`wildcard-<LAB_DOMAIN en tirets>-tls`) : aucun addon n'a jamais
à savoir lequel a été choisi.

## 🌐 `LAB_DOMAIN` — le domaine des UI

À ses côtés, deux autres marqueurs **neutres**. Le dépôt est **public** : aucun manifeste ne porte de vraie valeur. Trois marqueurs neutres
sont substitués **à la volée** (fonction `rendre` de `lib/common.sh`), sans jamais réécrire un
fichier versionné — `git status` reste propre :

| Marqueur versionné | Remplacé par | Vient de |
|---|---|---|
| `lab.example.io` | `$LAB_DOMAIN` (défaut `<distro>.lab.example.io`) | env, puis `lab.env` |
| `lab-example-io` | `$LAB_DOMAIN_DASH` — nom du Secret TLS wildcard | dérivé de `LAB_DOMAIN` |
| `lab-kv` | `$VAULT_KV_MOUNT` (`talos-lab` / `kubeadm-lab`) | profil de distribution |

`LAB_DOMAIN` se pose dans le `lab.env` du **lab**, jamais ici — donc depuis la racine du lab,
quelle que soit la disposition :

```bash
echo 'LAB_DOMAIN=k8s.mon-domaine.tld' >> lab.env    # dans Vagrant-Talos/ ou Vagrant-KubeADM/
```

> ⚠️ Un domaine resté à `<distro>.lab.example.io` alors que `lab.env` dit autre chose est le
> **premier** symptôme d'un `lab.env` jamais trouvé : vérifie `LAB_DIR` avant de soupçonner la
> substitution.

> ⚠️ **Les manifestes appliqués à la main** (sans passer par un `*-up.sh`) ne bénéficient pas
> de la substitution : `wordpress-example/wordpress-mariadb.yaml`,
> `vault-secret-operator/k8s/*.yaml`, `cert-manager/04-gateway-https-example.yaml`. Passe-les
> dans le même `sed` :
> ```bash
> sed 's/lab\.example\.io/k8s.mon-domaine.tld/g' <fichier> | kubectl apply -f -
> ```

## 📦 Versions épinglées

Audit du **1er août 2026** : tout est à la dernière version stable publiée à cette date
(`helm search repo <chart> --versions`). Chaque version est surchargeable par variable
d'environnement.

| Composant | Chart / image | Version | Où | Variable |
|---|---|---|---|---|
| Cilium | `cilium/cilium` | `1.20.0` | `cilium/cilium-up.sh` | `CILIUM_VERSION` |
| Calico | `projectcalico/tigera-operator` | `v3.32.1` | `calico/calico-up.sh` | `CALICO_VERSION` |
| Envoy Gateway | `oci://docker.io/envoyproxy/gateway-helm` | `1.8.3` | `platform-up.sh` | `ENVOY_GW_VERSION` |
| cert-manager | `jetstack/cert-manager` | `v1.21.1` | `platform-up.sh` | `CERT_MANAGER_VERSION` |
| metrics-server | image `registry.k8s.io/…` | `v0.9.0` | `metric-server.yaml` | — |
| Longhorn | `longhorn/longhorn` | `1.12.0` | `longhorn/longhorn-up.sh` | `LONGHORN_VERSION` |
| local-path-provisioner | image `rancher/…` | `v0.0.36` | `local-path-storage/local-path-storage.yaml` | — |
| CloudNativePG | `cnpg/cloudnative-pg` | `0.29.0` (app 1.30.0) | `cloudnative-pg/cloudnative-pg-up.sh` | `CNPG_VERSION` |
| Vault | `hashicorp/vault` | `0.34.0` | `vault-cluster/vault-up.sh` | `VAULT_CHART_VERSION` |
| Vault Secrets Operator | `hashicorp/vault-secrets-operator` | `1.5.0` | `vault-secret-operator/` (doc) | — |
| kube-prometheus-stack | `prometheus-community/…` | `88.0.1` (op. v0.93.0) | `observability/observability-up.sh` | `KPS_VERSION` |
| Loki | `grafana/loki` | `7.2.0` (app 3.6.11) | idem | `LOKI_VERSION` |
| Alloy | `grafana/alloy` | `1.11.0` (app v1.18.0) | idem | `ALLOY_VERSION` |
| node-problem-detector | `deliveryhero/…` | `2.3.14` (app v0.8.19) | `node-problem-detector/…-up.sh` | `NPD_VERSION` |
| Kyverno | `kyverno/kyverno` | `3.8.2` (app v1.18.2) | `kyverno/kyverno-up.sh` | `KYVERNO_VERSION` |
| Policy Reporter | `policy-reporter/policy-reporter` | `3.9.1` | `kyverno/`, `trivy-operator/` | `POLICY_REPORTER_VERSION` |
| Trivy Operator | `aqua/trivy-operator` | `0.34.0` (app 0.32.0) | `trivy-operator/…-up.sh` | `TRIVY_OPERATOR_VERSION` |
| Argo CD | `argo/argo-cd` | `10.2.2` (app v3.4.6) | `argocd/argocd-up.sh` | `ARGOCD_VERSION` |
| chaoskube | `chaoskube/chaoskube` | `0.6.0` (app 0.39.0) | `chaos-kube/chaoskube-up.sh` | `CHAOSKUBE_VERSION` |
| flannel | `flannel/flannel` | non épinglé (dernière : `v0.28.8`) | `platform-up.sh` | `FLANNEL_VERSION` |

> ℹ️ Les images des **démos** (WordPress, MariaDB, nginx, alpine, busybox, PostgreSQL, MinIO)
> sont épinglées volontairement et ne font pas partie de cet audit : les mettre à jour n'a
> d'intérêt que si la démo casse.

## 🗺️ Le catalogue

`./install.sh list` affiche la même liste, à jour.

> ℹ️ Les commandes ci-dessous explicitent `<distro>` parce qu'elles sont écrites depuis la
> racine de **ce** dépôt, où il vaut mieux le passer. Depuis la racine d'un lab, laisse-le
> tomber : `./_k8s/install.sh longhorn`.

### 🌐 Réseau & TLS

| Dossier | Rôle | Commande |
|---|---|---|
| [`cilium/`](cilium/LISEZ-MOI.md) | **CNI par défaut** + pool d'IP LoadBalancer + annonce L2 (ARP) | `./install.sh <distro> cilium` |
| [`calico/`](calico/LISEZ-MOI.md) | **CNI alternatif** (opérateur Tigera) — CNI **seul**, pas d'annonce L2 | `./install.sh <distro> calico` |
| [`envoy-gateway/`](envoy-gateway/LISEZ-MOI.md) | contrôleur Envoy + `main-gateway` (`:80`/`:443`) + apps de démo | via `platform` |
| [`self-signed/`](self-signed/LISEZ-MOI.md) | **mode TLS par défaut** — wildcard signé par une AC locale | via `platform` |
| [`cert-manager/`](cert-manager/LISEZ-MOI.md) | wildcard TLS automatique (ACME DNS-01 Cloudflare) | via `platform` si `SELF_SIGNED=false` |

### 💾 Stockage

| Dossier | Rôle | Commande | StorageClass |
|---|---|---|---|
| [`longhorn/`](longhorn/LISEZ-MOI.md) | stockage bloc répliqué (prérequis iSCSI **différent selon la distro**) | `./install.sh <distro> longhorn` | `longhorn`, `longhorn-r1` |
| [`local-path-storage/`](local-path-storage/LISEZ-MOI.md) | stockage local dynamique (hostPath ; **chemin selon la distro**) | `./install.sh <distro> local-path` | `local-path` |
| [`minio-s3/`](minio-s3/LISEZ-MOI.md) | stockage objet S3 + console, **1 nœud** | `./install.sh <distro> minio` | — |
| [`minio-s3/cluster/`](minio-s3/cluster/LISEZ-MOI.md) | MinIO **distribué** 4 nœuds (EC:2) — cible des sauvegardes | `./install.sh <distro> minio-cluster` | — |

### 🐘 Bases de données

| Dossier | Rôle | Commande | Prérequis |
|---|---|---|---|
| [`cloudnative-pg/`](cloudnative-pg/LISEZ-MOI.md) | opérateur PostgreSQL HA + cluster 3 nœuds, bascule auto, **sauvegardes S3 + PITR** | `./install.sh <distro> cnpg` | SC `longhorn-r1` |

### 🔐 Secrets

| Dossier | Rôle | Commande | Prérequis |
|---|---|---|---|
| [`vault-cluster/`](vault-cluster/LISEZ-MOI.md) | Vault HA (Raft) 3 nœuds, UI/API HTTPS | `./install.sh <distro> vault` | SC `longhorn` |
| [`vault-secret-operator/`](vault-secret-operator/LISEZ-MOI.md) | secrets Vault → `Secret` K8s (KV statique, DB dynamique, PKI) | Helm + `vault/*.sh` | Vault descellé |

### 📈 Observabilité

| Dossier | Rôle | Commande | Prérequis |
|---|---|---|---|
| [`observability/`](observability/LISEZ-MOI.md) | Prometheus + Grafana + Alertmanager + Loki + Alloy | `./install.sh <distro> observability` | SC `longhorn-r1`, CP ≥ 4 Go |
| [`node-problem-detector/`](node-problem-detector/LISEZ-MOI.md) | santé des nodes (kernel) | `./install.sh <distro> npd` | — |
| [`chaos-kube/`](chaos-kube/LISEZ-MOI.md) | chaos : supprime **1 pod au hasard par heure** | `./install.sh <distro> chaos` | — |

### 🛡️ Sécurité

| Dossier | Rôle | Commande | Prérequis |
|---|---|---|---|
| [`kyverno/`](kyverno/LISEZ-MOI.md) | moteur de policies + Policy Reporter (UI), policies en Audit | `./install.sh <distro> kyverno` | `main-gateway` |
| [`trivy-operator/`](trivy-operator/LISEZ-MOI.md) | scanner continu (CVE, config, secrets, RBAC) | `./install.sh <distro> trivy` | `kyverno` (UI partagée) |

### 🧪 Démos

| Dossier | Rôle | Commande |
|---|---|---|
| [`argocd/`](argocd/LISEZ-MOI.md) | Argo CD (GitOps), UI sous `argo.<LAB_DOMAIN>` | `./install.sh <distro> argocd` |
| [`wordpress-example/`](wordpress-example/LISEZ-MOI.md) | WordPress + MariaDB sur Longhorn, exposés par Envoy | `kubectl apply` (cf. LISEZ-MOI) |

## 🌍 Accès distant (Tailscale + Cloudflare)

La VIP `.200` est une IP **host-only** annoncée en ARP : joignable depuis l'hôte, pas routable
telle quelle.

1. **L3** — l'hôte annonce la route :
   ```bash
   sudo tailscale up --advertise-routes=192.168.56.200/32
   ```
   Puis l'approuver dans la console Tailscale.
   > ⚠️ Rester sur le `/32` (ou l'encadrer par une ACL) : un `/24` exposerait aussi l'API
   > Kubernetes (`:6443`) et le SSH de chaque node.

2. **Nom + TLS** — wildcard Cloudflare public `*.<LAB_DOMAIN> → 192.168.56.200`, en
   **DNS-only (nuage GRIS)** : le proxy Cloudflare ne peut pas joindre une IP privée
   `192.168.56.x`. Le TLS est donc terminé par **Envoy**, pas par Cloudflare → la Gateway doit
   porter un certificat **publiquement trusté** (Let's Encrypt, cf.
   [`cert-manager/`](cert-manager/LISEZ-MOI.md)). Un certificat *Cloudflare Origin CA* serait
   refusé par les navigateurs.

> 💡 Avec le défaut `SELF_SIGNED=true`, rien de tout ça n'est nécessaire : une ligne
> `/etc/hosts` pointant sur `192.168.56.200` suffit, et le domaine n'a jamais besoin de
> résoudre publiquement.

## ⚠️ Pièges

- **`LAB_DIR` oublié en disposition sous-module.** Le plus coûteux, parce qu'il ne coûte rien
  de visible : pas d'erreur, pas de fichier manquant, juste une installation menée avec les
  défauts du profil et sans kubeconfig. Depuis la racine du lab, toujours
  `export KUBECONFIG="$PWD/kubeconfig" LAB_DIR="$PWD"` avant `./_k8s/…`, et lire le marqueur
  `lab.env …` sur la ligne de résumé.
- **Un `git pull` dans un lab ne déplace pas `_k8s/`.** Le sous-module reste épinglé sur son
  commit précédent : `git submodule update --init --recursive` après chaque pull.
- **Deux StorageClass par défaut.** `longhorn/values.yaml` pose
  `persistence.defaultClass: true` et `local-path-storage.yaml` l'annotation
  `is-default-class: "true"`. Les deux addons installés ⇒ un PVC sans `storageClassName`
  explicite atterrit sur la SC créée en dernier, de façon non déterministe. **Nomme toujours
  ta SC.**
- **`CNI=cilium` est le seul choix « tout allumé ».** Cette couche a besoin d'un Service
  `LoadBalancer` qui obtienne réellement une IP : seule l'annonce L2 (ARP) de Cilium le fait
  ici. Avec `calico`, `flannel` ou `none`, le Gateway reste en `EXTERNAL-IP <pending>` et
  **aucune UI n'est joignable**.
- **Changer de CNI à chaud n'est pas supporté** : remets le cluster à plat depuis le lab
  (`./kubeadm/cluster-reset.sh`, ou `vagrant destroy`), puis rebootstrape.
- **Les policies Kyverno du dépôt sont violées par le dépôt lui-même**
  (`require-requests-limits` exige un `limits.cpu` que les manifestes maison ne posent pas,
  volontairement). Le rapport est bruyant par construction — cf.
  [`kyverno/`](kyverno/LISEZ-MOI.md).
- **Les émetteurs de métriques sont coupés par défaut** (`serviceMonitor`/`podMonitor` à
  `false` dans trivy-operator, CloudNativePG, node-problem-detector) : Prometheus ne scrute
  rien tant que tu ne les rallumes pas après avoir installé `observability`.
- **Ne descends jamais `CP_MEM` sous `3072`** dans le `lab.env` du lab : empiler ces addons
  sur des control planes à 2 Go affame etcd. `observability` demande `4096`.

## 📚 Références

- [OPS-NC/Vagrant-Talos](https://github.com/OPS-NC/Vagrant-Talos) — le lab Talos (de
  `vagrant up` au cluster prêt) · [doc navigable](https://ops-nc.github.io/Vagrant-Talos/)
- [OPS-NC/Vagrant-kubeadm](https://github.com/OPS-NC/Vagrant-kubeadm) — le lab Debian 13 +
  kubeadm · [doc navigable](https://ops-nc.github.io/Vagrant-kubeadm/)
- [Gateway API](https://gateway-api.sigs.k8s.io/) ·
  [Cilium](https://docs.cilium.io/) ·
  [Envoy Gateway](https://gateway.envoyproxy.io/) ·
  [cert-manager](https://cert-manager.io/docs/) ·
  [Talos Linux](https://www.talos.dev/latest/) ·
  [kubeadm](https://kubernetes.io/docs/reference/setup-tools/kubeadm/)

Les deux labs montent ce dépôt en sous-module `_k8s/` ; chacun documente son propre bootstrap,
son `lab.env` et son cycle de vie. Les chemins relatifs qui pointaient vers
`../Vagrant-Talos/` et `../Vagrant-KubeADM/` ont disparu : ils ne menaient nulle part sur le
site publié, et vers deux endroits différents selon la disposition.
