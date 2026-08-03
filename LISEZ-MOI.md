<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# ☸️ k8s-playground — les ressources Kubernetes des labs Talos **et** kubeadm

> **Un seul dépôt de manifestes et de charts pour deux labs Vagrant.** La couche applicative — CNI,
> Gateway API, stockage, secrets, observabilité, sécurité — était dupliquée dans
> `Vagrant-Talos/_k8s/` et encore dans `Vagrant-KubeADM/_k8s/`. Elle vit maintenant ici une seule
> fois, et les deux labs montent *ce* dépôt à ce même chemin `_k8s/`, en **sous-module git**. Monté
> comme ça, le lab **et** sa distribution sont trouvés tout seuls — aucun argument, aucune variable
> d'environnement :
>
> ```bash
> ./_k8s/platform-up.sh                # depuis la racine de l'un ou l'autre lab
> ./_k8s/install.sh longhorn vault      # addons, opt-in
> ```

📖 **Documentation navigable** : <https://ops-nc.github.io/k8s-playground/> — une page autonome,
bilingue (EN/FR), thème clair/sombre, reconstruite depuis ces fichiers `README.md` /
`LISEZ-MOI.md` à chaque push sur `main` (`make docs` la construit en local).

Les deux labs restent responsables du **bootstrap du cluster** (VM, OS, `kubeadm init` /
`talosctl bootstrap`). Ce dépôt couvre ce qui vient **après**, avec `kubectl` et `helm` depuis
l'hôte — **le CNI compris**, parce qu'aucun des deux bootstraps ne laisse un réseau de pods
utilisable.

## ⚡ Démarrage rapide

On ne commence jamais ici : on commence **dans un lab**, là où vivent le cluster et son état.

```bash
# 1. Le lab — sous-module compris (jumeau Talos : OPS-NC/Vagrant-Talos)
git clone --recurse-submodules https://github.com/OPS-NC/Vagrant-kubeadm.git
cd Vagrant-kubeadm
cp lab.env.example lab.env               # le modèle du LAB : topologie, domaine, mode TLS, CNI
vagrant up && ./kubeadm/cluster-up.sh    # les nodes sont NotReady : pas encore de CNI

# 2. Poser la plateforme de base — rien à déclarer
./_k8s/platform-up.sh                # CNI → Envoy Gateway → metrics-server → TLS wildcard

# 3. Les addons, opt-in
./_k8s/install.sh longhorn vault argocd
./_k8s/install.sh list               # le catalogue complet
./_k8s/install.sh all                # plateforme + tous les addons, dans l'ordre des dépendances
```

Depuis la racine du lab, ce dépôt est `<lab>/_k8s` : le lab est son **parent**, reconnu à son
`Vagrantfile`, et la distribution se lit sur la structure de ce lab — `kubeadm/cluster-up.sh` ici,
`talos/cluster-up.sh` chez le jumeau Talos. `KUBECONFIG` est déduit de la même façon
(`<lab>/kubeconfig`) ; ne l'exporte que pour **tes propres** appels `kubectl`. Passer la distribution
explicitement fonctionne toujours et gagne toujours, ce qui reste le moyen le plus sûr de savoir ce
qu'on a lancé : `./_k8s/install.sh kubeadm platform`.

Chaque composant s'exécute aussi tout seul :

```bash
./_k8s/longhorn/longhorn-up.sh
```

> 🎓 **Mode apprentissage.** Chaque dossier livre un `README.md` (EN) / `LISEZ-MOI.md` (FR) avec une
> section **« Pas à pas guidé »** : la même installation, commande par commande, avec ce qu'il faut
> observer à chaque étape et les variantes par distribution. Le script tout-en-un et le pas à pas
> font exactement la même chose.

<details>
<summary>Variante — les deux dépôts côte à côte (la disposition d'avant le sous-module, toujours supportée)</summary>

```bash
cd ../Vagrant-Talos && ./talos/cluster-up.sh    # ou ../Vagrant-KubeADM && ./kubeadm/cluster-up.sh

cd ../k8s-playground                 # ce dépôt, voisin du lab
./install.sh talos platform          # un seul lab à côté ⇒ l'argument est optionnel ici aussi
```

Ici le lab est **à côté** de ce dépôt, pas au-dessus : la règle du `Vagrantfile` parent ne se
déclenche pas. Le dossier du lab est trouvé via `LAB_REPO_NAME` (`../Vagrant-Talos`,
`../Vagrant-KubeADM`), fourni par le **profil de distribution**, et la distribution elle-même se lit
sur ces deux mêmes dossiers candidats, testés par leur nom. Avec les **deux** labs clonés côte à côte
le choix est ambigu : les scripts refusent de deviner et tu passes `talos`/`kubeadm`. C'est la seule
différence entre les deux dispositions — et la raison pour laquelle celle en sous-module est
recommandée : elle épingle la couche applicative à un commit par lab, ce qui rend un lab
reproductible.

Installer et mettre à jour le sous-module, depuis le lab :

```bash
git clone --recurse-submodules https://github.com/OPS-NC/Vagrant-kubeadm.git
git submodule update --init --recursive   # remplit _k8s/ sur un clone déjà fait
git submodule update --remote _k8s        # déplace _k8s/ sur le dernier commit de ce dépôt
```
</details>

> ⚠️ **Un `git pull` dans le lab ne met PAS le sous-module à jour.** Il ne déplace que le dépôt du
> lab ; `_k8s/` reste sur le commit épinglé avant, et tu exécuterais les commandes documentées contre
> une couche applicative **plus ancienne**. Fais suivre chaque pull de
> `git submodule update --init --recursive`. Et un `_k8s/` vide — `./_k8s/install.sh: No such file or
> directory` — signifie toujours une seule chose : le sous-module n'a jamais été initialisé.

> 💡 **Modifier cette couche est une modification faite *ici*.** Vu depuis un lab, `_k8s/` est un
> checkout de ce dépôt sur un HEAD détaché : les fichiers qu'on y édite appartiennent à ce dépôt, et
> un `git commit` lancé dans `_k8s/` commite **ici**. Le chemin est donc : PR sur ce dépôt → merge →
> dans le lab, `git submodule update --remote _k8s`, puis commit du pointeur déplacé. Ce commit
> **est** la montée de version de la couche applicative.

## 📍 Où sont trouvés `lab.env` et `_out/`

Les scripts ne stockent **rien**. `lab.env` (l'intention : domaine, mode TLS, CNI, taille des VM) et
`_out/` (les faits : `talosconfig`, `cluster.env`, l'AC locale, `vault-init.json`…) vivent dans le
dépôt du **lab**, avec le `kubeconfig` à côté. Il y a exactement une source de vérité pour la
topologie, et c'est celle du lab — d'où l'absence de `lab.env` et de modèle de `lab.env` ici.
`_resolve_lab_dir()`, dans `lib/common.sh`, cherche ce dossier dans cet ordre :

| # | Candidat | S'applique quand |
|---|---|---|
| 1 | `$LAB_DIR`, à défaut le dossier contenant `$LAB_ENV` | l'un des deux est exporté — surcharge explicite, **gagne toujours** |
| 2 | le dossier **parent** de ce dépôt, s'il contient un `Vagrantfile` | **disposition sous-module** : ce dépôt *est* `<lab>/_k8s` |
| 3 | `<racine de ce dépôt>/../$LAB_REPO_NAME` — `Vagrant-Talos` ou `Vagrant-KubeADM`, posé par le profil | ce dossier existe ⇒ **disposition voisine** |
| 4 | la racine de **ce** dépôt | un `lab.env` ou un `_out/` s'y trouve — usage autonome |
| 5 | repli : la racine de ce dépôt | rien de ce qui précède n'a correspondu |

`KUBECONFIG` suit le même dossier : sauf s'il est déjà exporté, il devient
`<dossier lab>/kubeconfig`.

Un `Vagrantfile` est la marque non ambiguë d'un lab : il est là **dès le clone**, avant tout
`vagrant up`, et il n'apparaît jamais au-dessus de ce dépôt dans la disposition voisine. La règle 2
passe volontairement **avant** la règle 4, pour qu'un `_out/` résiduel (ou un `lab.env` déposé ici
pour un test) ne puisse jamais masquer le vrai lab situé juste au-dessus.

Chaque script affiche sa résolution avant de toucher à quoi que ce soit — une ligne, à lire :

```
    profil kubeadm (Debian 13 + kubeadm) · domaine *.kubeadm.lab.example.io · lab.env absent (défauts)
```

`lab.env absent (défauts)` sur un lab qui *a* un `lab.env`, ou un `domaine` qui n'est pas celui que tu
as posé, signifie que la résolution a raté le lab. Force-la :

```bash
LAB_DIR=~/labs/mon-lab          ./install.sh talos platform   # lab.env + _out/ + kubeconfig, tout est là
LAB_ENV=~/labs/mon-lab/lab.env  ./install.sh talos platform   # son dossier devient le dossier du lab
```

> 💡 Un signal de plus se déclenche, sur kubeadm seulement : `platform-up.sh` avertit quand
> `_out/cluster.env` manque — *« `./kubeadm/cluster-up.sh` n'a pas été lancé (ou pas jusqu'au
> bout) »*. Soit le bootstrap n'est vraiment pas allé au bout, soit le lab résolu n'était pas le bon.
> L'avertissement est non bloquant, et Talos n'a pas d'équivalent (ce lab n'a pas de `cluster.env`).

> ⚠️ **Ne crée pas de `lab.env` à la racine de ce dépôt.** La règle 4 en accepte un, pour exercer ce
> dépôt sans lab, mais un second `lab.env` est une seconde vérité qui dérive de celle du lab dès que
> l'une des deux change. C'est pour ça qu'il n'y a **pas de `lab.env.example` ici** : le modèle à
> copier vit dans le lab.

## 🎯 Comment la distribution est choisie

Par ordre de priorité :

| # | Source | Exemple |
|---|---|---|
| 1 | premier argument positionnel | `./install.sh talos longhorn` |
| 2 | `--distro=` | `./platform-up.sh --distro=kubeadm` |
| 3 | variable d'environnement | `K8S_DISTRO=talos ./install.sh longhorn` |
| 4 | `DISTRO=` dans le `lab.env` du lab | `DISTRO=kubeadm` |
| 5 | la **structure** du lab | `talos/cluster-up.sh` → `talos` · `kubeadm/cluster-up.sh` → `kubeadm` |
| 6 | les **artefacts de bootstrap** du lab | `_out/talosconfig` → `talos` · `_out/cluster.env` → `kubeadm` |
| 7 | le dépôt de lab **voisin** | `../Vagrant-Talos/talos/cluster-up.sh` → `talos` |
| 8 | **sondage** du cluster | `osImage` du 1er node : `Talos …` → `talos`, sinon → `kubeadm` |

Les sources 5 à 8 sont `_detect_distro()`, ordonnées par la précocité du signal : la **structure**
fonctionne dès le `git clone`, avant tout `vagrant up` ; les **artefacts** couvrent un lab dont les
dossiers ont été renommés ; les **voisins** rejouent le même test sur `../Vagrant-Talos` et
`../Vagrant-KubeADM`, et **refusent de décider quand les deux sont là** — deviner serait une chance
sur deux de déployer sur le mauvais cluster ; le **sondage** vient en dernier parce qu'il a besoin
d'un `KUBECONFIG` déjà correct, lequel est déduit du dossier du lab, lequel vient du profil, qui est
justement ce qu'on cherche à choisir.

Sans aucune de ces sources, les scripts **refusent de tourner** : appliquer un manifeste taillé pour
Talos sur Debian (ou l'inverse) ne produit pas une erreur propre mais une panne silencieuse — un
`Deployment` créé alors qu'aucun pod ne démarre jamais.

> ℹ️ Les sources 4 à 6 ont besoin que le lab soit localisé d'abord, et c'est là que la disposition
> compte. En **sous-module**, la règle du `Vagrantfile` parent se déclenche avant tout chargement de
> profil, donc les trois fonctionnent nues — c'est ce qui rend `./_k8s/platform-up.sh` autonome. En
> disposition **voisine**, aucun lab n'est localisé à ce moment-là (`LAB_REPO_NAME` vient du profil) :
> la source 7 prend le relais, et `./install.sh platform` fonctionne nu depuis ici aussi tant qu'un
> **seul** lab est à côté.

## 🧬 Ce qui diffère vraiment entre les deux labs

Tout est concentré dans **`lib/profiles/talos.sh`** et **`lib/profiles/kubeadm.sh`** : les scripts
d'installation ne testent jamais la distribution par des `if` éparpillés, ils lisent des variables.

| Sujet | Talos Linux | Debian 13 + kubeadm | Variable de profil |
|---|---|---|---|
| **Domaine des UI par défaut** | `talos.lab.example.io` | `kubeadm.lab.example.io` | `DEFAULT_LAB_DOMAIN` |
| **PodSecurity (niveau cluster)** | `baseline` **imposé** → un pod privilégié exige un namespace étiqueté `privileged`, sinon il échoue **en silence** | aucun niveau imposé → les mêmes étiquettes ne débloquent rien, elles documentent l'intention | `PODSECURITY_DEFAULT` |
| **Système de fichiers** | immuable : `/` et `/usr` en lecture seule, seul `/var` est inscriptible | ordinaire, tout est inscriptible | — |
| **local-path-provisioner** | `/var/local-path-provisioner` | `/opt/local-path-provisioner` (chemin amont) | `LOCAL_PATH_DIR` |
| **Prérequis iSCSI (Longhorn)** | une **extension** (`iscsi-tools`) intégrée à l'image d'installation (impossible à corriger à chaud) + montage kubelet `rshared` via `talosctl patch mc` | un **paquet** (`open-iscsi`) installé par `provision.sh` ; `/var/lib/longhorn` est un dossier ordinaire | `LONGHORN_PREP_REQUIRED` |
| **kube-proxy** | **optionnel** — `cluster.proxy.disabled: true` dans la config machine | **optionnel** — `kubeadm init --skip-phases=addon/kube-proxy` | `KUBE_PROXY_REPLACEABLE` |
| **Cilium — IPAM** | `ipam.mode=kubernetes` (les podCIDR viennent du kube-controller-manager) | `ipam.mode=cluster-pool` (l'opérateur Cilium découpe le CIDR des pods) | `CILIUM_IPAM_MODE` |
| **Cilium — valeurs OS** | `cgroup.autoMount=false` + `cgroup.hostRoot` + capacités explicites (**obligatoire**) | rien : les défauts du chart sont les bons, les forcer serait **nuisible** | `cilium_specific_sets()` |
| **Calico** | `flexVolumePath: None` et CSI `None` **obligatoires** (`/usr` en lecture seule) | mêmes réglages, mais purement pour alléger | (manifeste partagé) |
| **flannel (`CNI=flannel`)** | déjà installé par le bootstrap Talos → rien à faire | installé ici via le chart `flannel/flannel` | `FLANNEL_PRE_INSTALLED` |
| **Trivy — scanners « node »** | **désactivés** : le `node-collector` monte `/etc/systemd` → `read-only file system` | activés : ces chemins existent et sont lisibles | `TRIVY_NODE_COLLECTOR` |
| **Prometheus — control plane** | monitors etcd/scheduler/controller-manager **off** (non scrapables sans TLS dédié) | **on** : `bind-address: 0.0.0.0` et `listen-metrics-urls` posés au bootstrap | `KPS_SCRAPE_CONTROL_PLANE` |
| **Interface host-only** | `enp0s8` | `eth1` ou `enp0s8` selon la box → **détectée** dans `_out/cluster.env` | `DEFAULT_HOSTONLY_IF` |
| **Faits du cluster** | rien de détecté : `lab.env` est la source, seul `podSubnets` est relu depuis `_out/controlplane.yaml` | `_out/cluster.env` — valeurs **détectées** sur le cluster (CIDR, interface, kube-proxy) | — |
| **Montage KV Vault de démo** | `talos-lab/` | `kubeadm-lab/` | `VAULT_KV_MOUNT` |
| **AC auto-signée** | `O=Vagrant-Talos lab` | `O=Vagrant-KubeADM lab` | `CA_ORG`, `CA_FILE_NAME` |
| **Options OIDC de l'apiserver (`dex/`)** | `talosctl patch mc` — **la configuration machine est une API** ; `extraArgs` est un dictionnaire | ConfigMap `kubeadm-config` + `kubeadm init phase` **sur chaque control plane** ; `extraArgs` est une liste de `{name, value}` (v1beta4) | `APISERVER_OIDC_PATCH`, `apiserver_oidc_commands()` |

> ℹ️ **kube-proxy : même résultat, deux mécanismes.** Les deux labs ont `KUBE_PROXY_REPLACEMENT=true`
> par défaut, donc sur les deux le cluster de référence tourne **sans aucun kube-proxy** et Cilium
> sert les Services en eBPF. Seule la façon dont le bootstrap s'en débarrasse diffère. La valeur se
> décide **au bootstrap** — ce n'est pas un interrupteur à chaud — et elle exige `CNI=cilium` des deux
> côtés, puisque rien d'autre ici ne remplace kube-proxy.

Tout le reste — Argo CD, Kyverno, MinIO, CloudNativePG, Vault, Envoy Gateway, cert-manager,
chaoskube, node-problem-detector, WordPress — est **strictement identique** sur les deux
distributions.

## 🗂️ Organisation du dépôt

```
install.sh                  point d'entrée : ./install.sh [talos|kubeadm] <composant...>
platform-up.sh              la plateforme de base (CNI → Gateway → metrics → TLS)
metric-server.yaml          metrics-server (appliqué par platform-up.sh)
lib/
  common.sh                 socle partagé : résolution de distro, lecture de lab.env, helpers
  profiles/talos.sh         TOUT ce qui est propre à Talos
  profiles/kubeadm.sh       TOUT ce qui est propre à kubeadm/Debian
<composant>/
  <composant>-up.sh         l'installation tout-en-un
  values.yaml / *.yaml      manifestes et values (valeurs NEUTRES, substituées à la volée)
  README.md / LISEZ-MOI.md  doc EN/FR + pas à pas guidé
docs/build.py               construit le site en une page depuis tous les README (make docs)
Makefile                    docs, docs-check, validate — tout ce qui tourne sans cluster
```

En disposition sous-module, toute cette arborescence pend sous le `_k8s/` du lab. Les chemins
*internes* à ce dépôt sont les mêmes dans les deux cas, ce qui explique que chaque pas à pas soit
écrit depuis la racine de ce dépôt.

Il n'y a **ni `Vagrantfile`, ni `_out/`, ni `lab.env` ici**, par construction : ce dépôt possède les
manifestes, le lab possède le cluster et son état. Cette absence porte quelque chose — c'est elle qui
fait de « le parent contient un `Vagrantfile` » un moyen non ambigu de repérer le lab.

## 🔗 Chaîne de dépendances

Chaque maillon suppose le précédent : pas d'IP de LoadBalancer sans annonceur L2, pas de HTTPS sans le
Gateway, pas d'UI sans certificat sur le listener `:443`.

```
cluster bootstrapé  (lab Talos ou lab kubeadm — nodes NotReady, pas de CNI)
   │
   ├─ 1. CNI              cilium/ (défaut, + pool L2 → IP LoadBalancer .200)
   │                      ou calico/ (CNI seul) ou flannel (CNI seul) ou rien
   │     + annonceur L2   metallb/ — SEULEMENT si le CNI n'est pas cilium, sur la MÊME plage
   │                      (ignoré avec METALLB=false : aucune IP de LoadBalancer)
   ├─ 2. envoy-gateway/   contrôleur Envoy + main-gateway (listeners :80 et :443)
   ├─ 3. metric-server    API metrics.k8s.io  (kubectl top, HPA)
   └─ 4. TLS wildcard     *.<LAB_DOMAIN> — deux modes, selon SELF_SIGNED
              │             true (défaut) → self-signed/   openssl, AC locale
              │             false         → cert-manager/  Let's Encrypt DNS-01 Cloudflare
              │
              └─ addons : stockage → sauvegarde → bases → identité → secrets → observabilité
                          → sécurité
```

C'est exactement l'ordre de `platform-up.sh` (`[1/4]` → `[4/4]`). Les deux modes TLS remplissent le
**même** Secret (`wildcard-<LAB_DOMAIN avec tirets>-tls`), donc aucun addon n'a à savoir lequel tu as
choisi.

## 🌐 `LAB_DOMAIN` — le domaine des UI

Le dépôt est **public** : aucun manifeste ne porte de vraie valeur. Trois marqueurs neutres sont
substitués **à la volée** (le helper `render` de `lib/common.sh`), sans jamais réécrire un fichier
versionné — `git status` reste propre :

| Marqueur versionné | Remplacé par | Vient de |
|---|---|---|
| `lab.example.io` | `$LAB_DOMAIN` (défaut `<distro>.lab.example.io`) | l'environnement, puis `lab.env` |
| `lab-example-io` | `$LAB_DOMAIN_DASH` — le nom du Secret TLS wildcard | déduit de `LAB_DOMAIN` |
| `lab-kv` | `$VAULT_KV_MOUNT` (`talos-lab` / `kubeadm-lab`) | profil de distribution |

`LAB_DOMAIN` se pose dans le `lab.env` du **lab**, jamais ici :

```bash
echo 'LAB_DOMAIN=k8s.mon-domaine.tld' >> lab.env      # dans Vagrant-Talos/ ou Vagrant-KubeADM/
```

> ⚠️ Un domaine qui reste à `<distro>.lab.example.io` alors que `lab.env` dit autre chose est le
> **premier** symptôme d'un `lab.env` jamais trouvé : vérifie quel lab a été résolu (la ligne de
> résumé) avant de soupçonner la substitution.

> ⚠️ **Les manifestes appliqués à la main** (sans `*-up.sh`) ne reçoivent aucune substitution :
> `wordpress-example/wordpress-mariadb.yaml`, `vault-secret-operator/k8s/*.yaml`,
> `cert-manager/04-gateway-https-example.yaml`. Passe-les par le même `sed` :
> ```bash
> sed 's/lab\.example\.io/k8s.mon-domaine.tld/g' <fichier> | kubectl apply -f -
> ```

## 📦 Versions épinglées

Auditées le **1er août 2026** : tout est sur la dernière version stable publiée à cette date
(`helm search repo <chart> --versions`). Chaque version est surchargeable par variable
d'environnement.

| Composant | Chart / image | Version | Où | Variable |
|---|---|---|---|---|
| Cilium | `cilium/cilium` | `1.20.0` | `cilium/cilium-up.sh` | `CILIUM_VERSION` |
| Calico | `projectcalico/tigera-operator` | `v3.32.1` | `calico/calico-up.sh` | `CALICO_VERSION` |
| MetalLB | `metallb/metallb` | `0.16.1` | `metallb/metallb-up.sh` | `METALLB_VERSION` |
| Envoy Gateway | `oci://docker.io/envoyproxy/gateway-helm` | `1.8.3` | `platform-up.sh` | `ENVOY_GW_VERSION` |
| cert-manager | `jetstack/cert-manager` | `v1.21.1` | `platform-up.sh` | `CERT_MANAGER_VERSION` |
| metrics-server | image `registry.k8s.io/…` | `v0.9.0` | `metric-server.yaml` | — |
| Longhorn | `longhorn/longhorn` | `1.12.0` | `longhorn/longhorn-up.sh` | `LONGHORN_VERSION` |
| Velero | `vmware-tanzu/velero` | `12.1.0` (app v1.18.1) | `velero/velero-up.sh` | `VELERO_VERSION` |
| velero-plugin-for-aws | image `velero/velero-plugin-for-aws` | `v1.14.2` | `velero/velero-up.sh` | `VELERO_AWS_PLUGIN_VERSION` |
| Velero UI | `otwld/velero-ui` | `0.15.0` (app 0.10.2) | `velero/velero-up.sh` | `VELERO_UI_VERSION` |
| local-path-provisioner | image `rancher/…` | `v0.0.36` | `local-path-storage/local-path-storage.yaml` | — |
| CloudNativePG | `cnpg/cloudnative-pg` | `0.29.0` (app 1.30.0) | `cloudnative-pg/cloudnative-pg-up.sh` | `CNPG_VERSION` |
| Keycloak | `keycloak-k8s-resources` (opérateur **et** serveur) | `26.7.0` | `keycloak/keycloak-up.sh` | `KEYCLOAK_VERSION` |
| Dex | `dex/dex` | `0.24.1` (app v2.44.0) | `dex/dex-up.sh` | `DEX_VERSION` |
| kubelogin | binaire hôte `kubectl oidc-login` | `v1.36.3` (référence) | `dex/LISEZ-MOI.md` | — |
| Vault | `hashicorp/vault` | `0.34.0` | `vault-cluster/vault-up.sh` | `VAULT_CHART_VERSION` |
| Vault Secrets Operator | `hashicorp/vault-secrets-operator` | `1.5.0` | `vault-secret-operator/vso-up.sh` | `VSO_VERSION` |
| kube-prometheus-stack | `prometheus-community/…` | `88.0.1` (op. v0.93.0) | `observability/observability-up.sh` | `KPS_VERSION` |
| Loki | `grafana/loki` | `7.2.0` (app 3.6.11) | idem | `LOKI_VERSION` |
| Alloy | `grafana/alloy` | `1.11.0` (app v1.18.0) | idem | `ALLOY_VERSION` |
| node-problem-detector | `deliveryhero/…` | `2.3.14` (app v0.8.19) | `node-problem-detector/…-up.sh` | `NPD_VERSION` |
| Kyverno | `kyverno/kyverno` | `3.8.2` (app v1.18.2) | `kyverno/kyverno-up.sh` | `KYVERNO_VERSION` |
| Policy Reporter | `policy-reporter/policy-reporter` | `3.9.1` | `kyverno/`, `trivy-operator/` | `POLICY_REPORTER_VERSION` |
| Trivy Operator | `aqua/trivy-operator` | `0.34.0` (app 0.32.0) | `trivy-operator/…-up.sh` | `TRIVY_OPERATOR_VERSION` |
| Argo CD | `argo/argo-cd` | `10.2.2` (app v3.4.6) | `argocd/argocd-up.sh` | `ARGOCD_VERSION` |
| chaoskube | `chaoskube/chaoskube` | `0.6.0` (app 0.39.0) | `chaos-kube/chaoskube-up.sh` | `CHAOSKUBE_VERSION` |
| flannel | `flannel/flannel` | non épinglée (dernière : `v0.28.8`) | `platform-up.sh` | `FLANNEL_VERSION` |

> ℹ️ Les images de **démo** (WordPress, MariaDB, nginx, alpine, busybox, PostgreSQL, MinIO) sont
> épinglées à dessein et ne font pas partie de cet audit : les monter n'a d'intérêt que quand une démo
> casse.

## 🗺️ Le catalogue

`./install.sh list` affiche la même liste, toujours à jour. `<distro>` est écrit ci-dessous pour
lever toute ambiguïté, mais il est optionnel dans les deux dispositions.

### 🌐 Réseau & TLS

| Dossier | Rôle | Commande |
|---|---|---|
| [`cilium/`](cilium/LISEZ-MOI.md) | **CNI par défaut** + pool d'IP LoadBalancer + annonce L2 (ARP) | `./install.sh <distro> cilium` |
| [`calico/`](calico/LISEZ-MOI.md) | **CNI alternatif** (opérateur Tigera) — CNI **seulement**, pas d'annonce L2 | `./install.sh <distro> calico` |
| [`metallb/`](metallb/LISEZ-MOI.md) | annonceur L2 (ARP) — les IP de LoadBalancer **quand le CNI n'est pas Cilium** | via `platform` si `CNI != cilium` |
| [`envoy-gateway/`](envoy-gateway/LISEZ-MOI.md) | contrôleur Envoy + `main-gateway` (`:80`/`:443`) + applis de démo | via `platform` |
| [`self-signed/`](self-signed/LISEZ-MOI.md) | **mode TLS par défaut** — wildcard signé par une AC locale | via `platform` |
| [`cert-manager/`](cert-manager/LISEZ-MOI.md) | TLS wildcard automatique (ACME DNS-01 Cloudflare) | via `platform` si `SELF_SIGNED=false` |

### 💾 Stockage

| Dossier | Rôle | Commande | StorageClass |
|---|---|---|---|
| [`longhorn/`](longhorn/LISEZ-MOI.md) | stockage bloc répliqué (le prérequis iSCSI **diffère par distro**) | `./install.sh <distro> longhorn` | `longhorn`, `longhorn-r1` |
| [`local-path-storage/`](local-path-storage/LISEZ-MOI.md) | stockage local dynamique (hostPath ; **chemin différent par distro**) | `./install.sh <distro> local-path` | `local-path` |
| [`minio-s3/`](minio-s3/LISEZ-MOI.md) | stockage objet S3 + console, **1 node** | `./install.sh <distro> minio` | — |
| [`minio-s3/cluster/`](minio-s3/cluster/LISEZ-MOI.md) | MinIO **distribué**, 4 nodes (EC:2) — la cible des sauvegardes | `./install.sh <distro> minio-cluster` | — |

### 🗃️ Sauvegarde

| Dossier | Rôle | Commande | Prérequis |
|---|---|---|---|
| [`velero/`](velero/LISEZ-MOI.md) | sauvegarde/restauration des **objets** *et* des **données de PV** (Longhorn compris, via FSB/kopia) vers MinIO, **UI sur `velero.<LAB_DOMAIN>`** | `./install.sh <distro> velero` | un MinIO (`minio-cluster` ou `minio`) |

### 🐘 Bases de données

| Dossier | Rôle | Commande | Prérequis |
|---|---|---|---|
| [`cloudnative-pg/`](cloudnative-pg/LISEZ-MOI.md) | opérateur PostgreSQL HA + cluster à 3 nodes, bascule automatique, **sauvegardes S3 + PITR** | `./install.sh <distro> cnpg` | SC `longhorn-r1` |

### 🪪 Identité

| Dossier | Rôle | Commande | Prérequis |
|---|---|---|---|
| [`keycloak/`](keycloak/LISEZ-MOI.md) | Keycloak par son **opérateur**, realm `lab` déclaré, émetteur OIDC sur `keycloak.<LAB_DOMAIN>` | `./install.sh <distro> keycloak` | `cnpg`, SC `longhorn-r1` |
| [`dex/`](dex/LISEZ-MOI.md) | Dex devant Keycloak — connexion `kubectl` en OIDC (`oidc-login`), droits pilotés par un groupe | `./install.sh <distro> dex` | `keycloak` |

### 🔐 Secrets

| Dossier | Rôle | Commande | Prérequis |
|---|---|---|---|
| [`vault-cluster/`](vault-cluster/LISEZ-MOI.md) | Vault HA (Raft), 3 nodes, UI/API en HTTPS | `./install.sh <distro> vault` | SC `longhorn` |
| [`vault-secret-operator/`](vault-secret-operator/LISEZ-MOI.md) | secrets Vault → `Secret`s K8s natifs (KV statique, BDD dynamique, PKI) | `./install.sh <distro> vso` (opérateur **seul**) + `vault/*.sh` | Vault descellé |

### 📈 Observabilité

| Dossier | Rôle | Commande | Prérequis |
|---|---|---|---|
| [`observability/`](observability/LISEZ-MOI.md) | Prometheus + Grafana + Alertmanager + Loki + Alloy | `./install.sh <distro> observability` | SC `longhorn-r1`, CP ≥ 4 Go |
| [`node-problem-detector/`](node-problem-detector/LISEZ-MOI.md) | santé des nodes (noyau) | `./install.sh <distro> npd` | — |
| [`chaos-kube/`](chaos-kube/LISEZ-MOI.md) | chaos : supprime **1 pod au hasard par heure** | `./install.sh <distro> chaos` | — |

### 🛡️ Sécurité

| Dossier | Rôle | Commande | Prérequis |
|---|---|---|---|
| [`kyverno/`](kyverno/LISEZ-MOI.md) | moteur de politiques + Policy Reporter (UI), politiques pédagogiques en Audit | `./install.sh <distro> kyverno` | `main-gateway` |
| [`trivy-operator/`](trivy-operator/LISEZ-MOI.md) | scanner continu (CVE, config, secrets, RBAC) | `./install.sh <distro> trivy` | `kyverno` (UI partagée) |

### 🧪 Démos

| Dossier | Rôle | Commande |
|---|---|---|
| [`argocd/`](argocd/LISEZ-MOI.md) | Argo CD (GitOps), UI sur `argo.<LAB_DOMAIN>` | `./install.sh <distro> argocd` |
| [`wordpress-example/`](wordpress-example/LISEZ-MOI.md) | WordPress + MariaDB sur Longhorn, exposés par Envoy | `kubectl apply` (voir le LISEZ-MOI) |

## 🌍 Accès distant (Tailscale + Cloudflare)

La VIP `.200` est une IP **host-only** annoncée en ARP : joignable depuis l'hôte, non routable telle
quelle.

1. **L3** — l'hôte annonce la route :
   ```bash
   sudo tailscale up --advertise-routes=192.168.56.200/32
   ```
   Puis approuve-la dans la console Tailscale.
   > ⚠️ Reste sur le `/32` (ou barrière par ACL) : un `/24` exposerait aussi l'API Kubernetes
   > (`:6443`) et SSH sur tous les nodes.

2. **Nom + TLS** — un wildcard Cloudflare public `*.<LAB_DOMAIN> → 192.168.56.200`, en **DNS-only
   (nuage gris)** : le proxy Cloudflare ne peut pas joindre une IP privée `192.168.56.x`. TLS est donc
   terminé par **Envoy**, pas par Cloudflare, donc le Gateway doit porter un certificat **reconnu
   publiquement** (Let's Encrypt, voir [`cert-manager/`](cert-manager/LISEZ-MOI.md)). Un certificat
   *Cloudflare Origin CA* serait rejeté par les navigateurs.

> 💡 Avec le défaut `SELF_SIGNED=true`, rien de tout ça n'est nécessaire : une ligne `/etc/hosts`
> pointant `192.168.56.200` suffit, et le domaine n'a jamais à résoudre publiquement.

## ⚠️ Pièges

- **Lis la ligne de résumé, à chaque fois.** Une ligne par script, affichée avant de toucher à quoi
  que ce soit : profil, domaine, et si un `lab.env` a été trouvé. C'est le moyen le moins cher
  d'attraper une résolution partie ailleurs.
- **Les deux labs clonés côte à côte, sans argument de distribution.** Le signal du voisin pointe dans
  deux directions à la fois : les scripts s'arrêtent et demandent plutôt que de choisir. Dis lequel,
  ou lance depuis le lab visé, en disposition sous-module.
- **Le dossier du lab renommé, en disposition voisine.** La recherche du lab (`LAB_REPO_NAME`) et la
  détection du voisin correspondent à ces deux noms **littéralement** : un `Vagrant-KubeADM-v2/` à
  côté n'est trouvé par aucun des deux, et la résolution retombe sur ce dépôt — en silence. `LAB_DIR`
  est le remède. En sous-module, le nom du dossier n'a aucune importance.
- **Un `git pull` dans un lab ne déplace pas `_k8s/`** : `git submodule update --init --recursive`
  après chaque pull.
- **Deux StorageClass par défaut.** `longhorn/values.yaml` pose `persistence.defaultClass: true` et
  `local-path-storage.yaml` pose l'annotation `is-default-class: "true"`. Les deux addons installés,
  un PVC sans `storageClassName` explicite atterrit sur la SC créée le plus récemment, de façon non
  déterministe. **Nomme toujours ta SC.**
- **Cette couche a besoin d'un Service `LoadBalancer` qui obtienne vraiment une IP**, et Cilium est le
  seul CNI ici à en fournir une tout seul (L2/ARP). Avec `calico`, `flannel` ou `none`,
  `platform-up.sh` installe [`metallb/`](metallb/LISEZ-MOI.md) juste après le CNI, sur la même plage,
  pour que tous les CNI finissent avec un `.200` joignable. Deux choses laissent encore le Gateway en
  `EXTERNAL-IP <pending>` : `METALLB=false` dans `lab.env`, et appliquer
  `envoy-gateway/Envoy-Proxy.yml` **à la main** avec son `loadBalancerClass` Cilium dedans.
- **Jamais MetalLB *et* Cilium.** Deux annonceurs sur une plage, c'est deux nodes qui répondent à
  l'ARP pour `.200` : le point d'entrée fonctionne alors « une fois sur deux », sans rien dans aucun
  log. `metallb-up.sh` refuse de s'installer sur un cluster Cilium, et `platform` ne le choisit jamais
  là.
- **Changer de CNI sur un cluster vivant n'est pas supporté** : rase le cluster depuis le lab
  (`./kubeadm/cluster-reset.sh`, ou `vagrant destroy`), puis re-bootstrape.
- **Les politiques Kyverno du dépôt sont violées par le dépôt** (`require-requests-limits` exige un
  `limits.cpu` que les manifestes maison ne posent volontairement jamais). Le rapport est bruyant par
  construction — voir [`kyverno/`](kyverno/LISEZ-MOI.md).
- **Les émetteurs de métriques sont désactivés par défaut** (`serviceMonitor`/`podMonitor` à `false`
  dans trivy-operator, CloudNativePG et node-problem-detector) : Prometheus ne scrape rien chez eux
  avant que tu ne les actives, après l'installation d'`observability`.
- **Ne descends jamais `CP_MEM` sous `3072`** dans le `lab.env` du lab : empiler ces addons sur des
  control planes de 2 Go affame etcd. `observability` demande `4096`.

## 📚 Références

- [OPS-NC/Vagrant-Talos](https://github.com/OPS-NC/Vagrant-Talos) — le lab Talos, du `vagrant up` au
  cluster prêt · [doc navigable](https://ops-nc.github.io/Vagrant-Talos/)
- [OPS-NC/Vagrant-kubeadm](https://github.com/OPS-NC/Vagrant-kubeadm) — le lab Debian 13 + kubeadm ·
  [doc navigable](https://ops-nc.github.io/Vagrant-kubeadm/)
- [Gateway API](https://gateway-api.sigs.k8s.io/) · [Cilium](https://docs.cilium.io/) ·
  [Envoy Gateway](https://gateway.envoyproxy.io/) · [cert-manager](https://cert-manager.io/docs/) ·
  [Talos Linux](https://www.talos.dev/latest/) ·
  [kubeadm](https://kubernetes.io/docs/reference/setup-tools/kubeadm/)
