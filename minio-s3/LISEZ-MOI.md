<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🪣 `minio-s3/` — MinIO standalone (S3 + console d'admin)

> Un endpoint **compatible S3** dans le cluster, en **un seul pod**, avec une **console
> d'administration complète** (fork Pigsty). C'est la version simple : un PVC, un replica.
> La version distribuée est dans **[`cluster/`](./cluster/)**.
>
> La StorageClass du PVC est **`MINIO_SC`** (défaut `local-path`). Mets `MINIO_SC=longhorn` pour
> poser le bucket sur du stockage répliqué — cf.
> [Quelle StorageClass ?](#-quelle-storageclass--minio_sc) plus bas.

## 🎯 À quoi ça sert

Avoir un S3 local pour tester des backups, des SDK, `mc`, des politiques de buckets — sans
compte cloud. Deux hostnames exposés en HTTPS via `main-gateway` (wildcard `*.lab.example.io`) :

| Service | URL | Port conteneur |
|---|---|---|
| **API S3** | `https://minio.lab.example.io` | 9000 |
| **Console admin** | `https://minio-console.lab.example.io` | 9001 |

En interne au cluster : `http://minio.minio-s3.svc.cluster.local:9000`.

### Standalone (ici) ou distribué ([`cluster/`](./cluster/)) ?

| | **Standalone (ici)** | **Cluster** (`cluster/`) |
|---|---|---|
| Workload | Deployment, 1 replica | StatefulSet, **4 pods** (`podManagementPolicy: Parallel`) |
| Drives | 1 PVC 10 Gi (`MINIO_SC`) | **4** PVC `local-path` 10 Gi (1/pod, 1/worker) |
| Erasure coding | ❌ aucun | ✅ **EC:2** |
| Résilience | nulle sur `local-path` ; **au niveau du volume** sur `longhorn` | tolère ~2 nœuds/drives down |
| Workers requis | 1 | **4** (anti-affinité stricte) |
| Namespace | `minio-s3` | `minio-cluster` (les deux coexistent) |
| Hostnames | `minio` / `minio-console` | `minio-cluster` / `minio-cluster-console` |

> ℹ️ **Les backups du lab ne visent plus ce standalone.** Depuis le passage au cluster MinIO,
> `../cloudnative-pg/pg-backup-up.sh` et `pg-app-backup-cnpg-up.sh` pointent
> `http://minio.minio-cluster.svc.cluster.local:9000`. Ce dossier reste le bac à sable simple
> (et la brique pédagogique « avant/après erasure coding »).

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Une StorageClass nommée par **`MINIO_SC`** (défaut `local-path`, `../local-path-storage/` ; ou `longhorn`, `../longhorn/`) | le PVC 10 Gi de `/data` ; `minio-up.sh` s'arrête sans elle | `kubectl get storageclass "${MINIO_SC:-local-path}"` |
| `main-gateway` + écouteur `https` (`../envoy-gateway/`) | porte les deux `HTTPRoute` | `kubectl get gateway -n envoy-gateway-system` |
| Cert wildcard `*.lab.example.io` (`../cert-manager/`) | TLS des deux hostnames | `kubectl -n envoy-gateway-system get certificate` |
| DNS `minio` + `minio-console` → `192.168.56.200` | atteindre le VIP Envoy | `getent hosts minio.lab.example.io` |
| `openssl` sur l'hôte | génère le mot de passe root par défaut | `openssl version` |

## ⚡ Installation

> 🎓 **Deux chemins, même résultat** : le script tout-en-un ci-dessous, ou la section
> **« Pas à pas guidé »** plus bas — les mêmes commandes, une par une, pour une formation.

Via le point d'entrée du dépôt :
```bash
./install.sh <distro> minio     # <distro> = talos | kubeadm
```

```bash
./minio-s3/minio-up.sh <distro>
# Identifiants réglables : MINIO_ROOT_USER (défaut « admin ») / MINIO_ROOT_PASSWORD (généré)
MINIO_ROOT_PASSWORD='MonPassLab' ./minio-s3/minio-up.sh <distro>
# Bucket sur stockage répliqué plutôt que node-local (cible de backup Velero) :
MINIO_SC=longhorn ./minio-s3/minio-up.sh <distro>
```

Image épinglée dans `minio-s3.yaml` : **`docker.io/pgsty/minio:RELEASE.2026-06-18T00-00-00Z`**.

### 💾 Quelle StorageClass ? (`MINIO_SC`)

| `MINIO_SC` | Ce que ça donne | À utiliser quand |
|---|---|---|
| `local-path` (défaut) | un dossier hostPath sur un node. Le plus rapide, zéro surcoût, **meurt avec son node** | bac à sable : tester `mc`, des SDK, des politiques de bucket |
| `longhorn` | un volume bloc répliqué ; le pod est replanifié ailleurs et **retrouve ses données** | ce MinIO est une **cible de backup** ([`../velero/`](../velero/LISEZ-MOI.md)) |

> ⚠️ **Un backup qui meurt avec son node n'est pas un backup.** Velero écrit ici à la fois les
> tarballs d'objets et les données des PV : sur `local-path`, la perte de cet unique worker
> emporte le seul point de restauration du cluster. `MINIO_SC=longhorn` est le bon défaut pour
> une cible Velero — en acceptant que Longhorn vive lui aussi sur ces mêmes workers, ce qui fait
> qu'une copie hors cluster reste la vraie réponse.

> ℹ️ **`storageClassName` est immuable.** Changer `MINIO_SC` sur un MinIO déjà installé est
> **refusé** par le script, avec les deux sorties possibles (garder la classe actuelle, ou
> supprimer `deploy/minio` + `pvc/minio-data` et perdre le contenu du bucket) — ce n'est pas
> ignoré en silence.

## 🧬 Talos vs kubeadm

**Aucune spécificité de distribution pour ce composant** : mêmes charts, mêmes manifestes,
mêmes valeurs sur les deux labs. La distribution passée en argument ne sert ici qu'à deux
choses : le **domaine par défaut** (`talos.lab.example.io` / `kubeadm.lab.example.io`) et la
**localisation du `lab.env` / `kubeconfig`** du lab (`../Vagrant-Talos/` ou
`../Vagrant-KubeADM/`).

> ℹ️ Le seul prérequis est la StorageClass nommée par `MINIO_SC` — et si tu la laisses sur
> `local-path`, son **chemin**, lui, dépend de la distribution (cf.
> [`../local-path-storage/`](../local-path-storage/LISEZ-MOI.md)).

## 🎓 Pas à pas guidé (formation)

> Les commandes ci-dessous sont **exactement** ce que fait le script tout-en-un, dans
> l'ordre. Prépare d'abord l'environnement (une fois par session) :
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig        # ou ../Vagrant-KubeADM/kubeconfig
> export LAB_DOMAIN=talos.lab.example.io               # ou ton domaine (cf. lab.env du lab)
> ```

### 1. Vérifier le prérequis stockage

```bash
export MINIO_SC=local-path     # ou longhorn (répliqué — cf. « Quelle StorageClass ? » plus haut)
kubectl get sc "$MINIO_SC"     # sinon : ./install.sh <distro> local-path | longhorn
```

### 2. Namespace + Secret d'identifiants (généré une fois, jamais écrasé)

```bash
kubectl create namespace minio-s3 --dry-run=client -o yaml | kubectl apply -f -
kubectl -n minio-s3 get secret minio-creds >/dev/null 2>&1 || \
kubectl -n minio-s3 create secret generic minio-creds \
  --from-literal=root-user=admin \
  --from-literal=root-password="$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)"
```

### 3. Déploiement + Service + HTTPRoutes (domaine et StorageClass substitués)

```bash
sed -e "s/lab\.example\.io/${LAB_DOMAIN}/g" \
    -e "s#^\( *storageClassName: \).*#\1${MINIO_SC}#" minio-s3/minio-s3.yaml | kubectl apply -f -
kubectl -n minio-s3 rollout status deploy/minio --timeout=180s
kubectl -n minio-s3 get pvc minio-data     # Bound, sur la classe demandée
```

### 4. Récupérer les identifiants

```bash
kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-user}' | base64 -d; echo
kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-password}' | base64 -d; echo
```

### 5. Vérifier l'API S3 et la console

```bash
kubectl -n minio-s3 get httproute
curl --resolve "minio.${LAB_DOMAIN}:443:192.168.56.200" "https://minio.${LAB_DOMAIN}/minio/health/live" -kSI | head -1
# client mc (depuis l'hôte) :
mc alias set lab "https://minio.${LAB_DOMAIN}" <user> <pass> --insecure
mc mb lab/demo --insecure && mc ls lab --insecure
```

## 🔧 Ce que fait le script

1. Vérifie `kubectl`, l'apiserver et la présence de la StorageClass `${MINIO_SC:-local-path}`,
   puis qu'un PVC `minio-data` existant n'est pas sur une **autre** classe (champ immuable).
2. Crée le namespace `minio-s3` et le Secret `minio-creds` (`root-user` / `root-password`) —
   **jamais écrasé** s'il existe : relancer le script ne change pas le mot de passe.
3. Applique `minio-s3.yaml` avec le domaine **et la StorageClass** substitués : PVC 10 Gi,
   Deployment (`strategy: Recreate`, car le volume RWO n'accepte pas deux pods), Service
   ClusterIP, deux `HTTPRoute`.
4. Attend le `rollout` (180 s) puis affiche les URL **et les identifiants root en clair sur
   stdout** (cf. Pièges).

### Pourquoi le fork Pigsty (`pgsty/minio`)

Ni l'image « officielle », ni Bitnami :

- **Bitnami** (`bitnami/minio`) s'appuie depuis **août 2025** sur des images **gelées**
  (`bitnamilegacy/*`, plus mises à jour).
- **Upstream `minio/minio`** a **amputé la console communautaire** vers
  `RELEASE.2025-05-24` (il ne reste qu'un navigateur d'objets : plus de gestion users /
  buckets / policies / lifecycle depuis le web), puis le dépôt a été **archivé
  « no longer maintained »** (fév. 2026).
- **Pigsty** rebuild le serveur MinIO **et restaure la console d'admin complète** → image
  **récente** ET **administrable**. C'est le fork le plus actif (billet « MinIO is Dead, Long
  Live MinIO »).

Alternatives possibles : upstream épinglé `RELEASE.2025-04-22T22-12-26Z` (dernière release avec
la console admin officielle, mais figé), autres forks de console (`huncrys/minio-console`,
`georgmangold/console`), édition payante **AIStor**, ou simplement le CLI **`mc`**.

## ✅ Vérifier

```bash
kubectl -n minio-s3 get pods,pvc,svc,httproute
curl -sk -o /dev/null -w '%{http_code}\n' --resolve minio.lab.example.io:443:192.168.56.200 \
  https://minio.lab.example.io/minio/health/ready      # 200
```

## 🌐 Accès

| Quoi | Comment |
|---|---|
| Console admin | `https://minio-console.lab.example.io` |
| API S3 | `https://minio.lab.example.io` (path-style, `region` quelconque : `us-east-1`) |
| Utilisateur root | `kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-user}' \| base64 -d; echo` |
| Mot de passe root | `kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-password}' \| base64 -d; echo` |

Le cert wildcard est émis par Let's Encrypt **staging** → avertissement TLS à accepter dans le
navigateur, et `--insecure` pour `mc` (cf. `../cert-manager/`).

```bash
mc alias set lab https://minio.lab.example.io <user> <pass> --insecure
mc mb lab/mon-bucket --insecure                       # créer un bucket
mc admin user add lab bob <mot-de-passe> --insecure   # gérer les users
mc ls lab --insecure
```

## ⚠️ Pièges

- **`minio-up.sh` affiche l'utilisateur ET le mot de passe root en clair sur stdout** (fin de
  run). Ça finit dans l'historique du terminal, les logs de CI, une capture d'écran… Préférer
  les relire depuis le Secret (tableau ci-dessus) et penser à nettoyer la sortie si tu la
  partages.
- **Sur `local-path` (le défaut), aucune résilience.** Deployment 1 replica + 1 PVC node-local :
  si le worker qui héberge le PV meurt, les objets sont perdus. Trois sorties, par coût
  croissant : `MINIO_SC=longhorn` (**volume** répliqué, toujours un seul pod MinIO),
  **[`cluster/`](./cluster/)** (4 drives, EC:2 — MinIO se réplique tout seul), ou une copie hors
  cluster.
- **`MINIO_SC=longhorn` protège le volume, pas le domaine de panne.** Les replicas Longhorn
  vivent sur les mêmes workers que le reste : un `vagrant destroy` emporte quand même le bucket
  — y compris le backup Velero qui s'y trouve. À considérer comme une protection contre la mort
  d'*un* node, pas comme une sauvegarde hors site.
- **Les 10 Gi du PVC sont une vraie limite sur `longhorn`, mais pas sur `local-path`.**
  `local-path` provisionne un dossier hostPath : rien n'empêche MinIO de remplir la partition
  `/var` du worker. L'`ephemeral-storage` allocatable mesuré sur ce lab est de **~16,9 Go/node**
  (disque de 20 Go partagé avec l'OS et les images conteneurs) → remplir un bucket déclenche du
  `DiskPressure` et l'**éviction** de pods sur ce node. Surveiller
  `kubectl describe node <worker> | grep -i pressure`. Longhorn, à l'inverse, fait respecter les
  10 Gi : MinIO reçoit `ENOSPC` et renvoie des erreurs S3 au lieu d'abîmer le node. Quand ce
  MinIO est une cible Velero, garde donc un œil sur le bucket face à la rétention configurée
  (`ttl` dans [`../velero/schedule.yaml`](../velero/schedule.yaml)) — et augmente la requête
  `storage:` de `minio-s3.yaml` avant que ça morde (Longhorn autorise l'expansion).
- **Le Secret `minio-creds` n'est pas dans git** (créé par le script). Le perdre = perdre
  l'accès root : `kubectl -n minio-s3 delete secret minio-creds` puis relancer le script
  régénère un mot de passe, mais MinIO garde l'ancien tant que le pod n'est pas recréé.
- **Console derrière un hostname distinct** : `MINIO_BROWSER_REDIRECT_URL` porte
  `https://minio-console.lab.example.io` dans `minio-s3.yaml` — domaine **neutre** du dépôt
  public. `minio-up.sh` la substitue avec les hostnames des `HTTPRoute` depuis `LAB_DOMAIN`
  (`lab.env`). Un `kubectl apply -f minio-s3.yaml` **direct** garde le domaine d'exemple et casse
  les redirections de login. Cf. [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui).

## 📚 Références

- MinIO retire l'admin de la console communautaire :
  <https://blocksandfiles.com/2025/06/19/minio-removes-management-features-from-basic-community-edition-object-storage-code/>
- Discussion officielle : <https://github.com/minio/minio/discussions/21326>
- Images du fork : <https://hub.docker.com/r/pgsty/minio/tags>
- [`cluster/`](./cluster/) — la variante distribuée 4 nœuds (erasure coding).
