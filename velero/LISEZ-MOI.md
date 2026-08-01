<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# ⛵ `velero/` — sauvegarde et restauration du cluster (objets **et** données des PV Longhorn) vers MinIO

> Velero écrit deux choses dans le même bucket S3 : les **objets Kubernetes** (tous les
> manifestes, namespacés et cluster-scoped) et le **contenu des volumes persistants** — Longhorn
> compris — via le File System Backup. Un namespace supprimé par erreur, PVC et données
> incluses, revient avec un seul `velero restore create`.

> 🌐 Contrairement à la plupart des addons d'ici, **aucun fichier de ce dossier ne porte le
> domaine neutre** : Velero n'expose pas d'UI et joint MinIO par le Service interne au cluster.
> Il n'y a rien à substituer, et un `kubectl apply -f velero/schedule.yaml` à la main fait
> exactement ce que fait le script.

## 🎯 À quoi ça sert

Sauvegarder un cluster Kubernetes, ce sont deux problèmes qu'on confond en permanence :

| Quoi | Où ça vit | Comment Velero le prend |
|---|---|---|
| **Les objets** — Deployments, Secrets, *définitions* de PVC, CRD, ClusterRole… | etcd | listés via l'API server, écrits sous forme d'un tarball par sauvegarde dans le bucket |
| **Les données** — les octets à l'intérieur d'un volume Longhorn (ou `local-path`) | le disque des workers | **File System Backup** : le DaemonSet `node-agent` lit le volume là où le kubelet l'a déjà monté et l'envoie dans le **même** bucket avec kopia |

Ne restaurer que le premier, c'est obtenir un cluster plein de PVC vides. Cet addon fait les
deux, et les fait au même endroit — le bucket `velero` du MinIO du lab.

### Le montage en une phrase

`deployNodeAgent: true` + `defaultVolumesToFsBackup: true` : chaque volume de pod est sauvegardé
**sans aucune annotation par application**, et le magasin d'objets est
`http://minio.minio-cluster.svc.cluster.local:9000`, joint uniquement par le réseau de pods.

### Pourquoi le File System Backup plutôt que les snapshots CSI

| | Snapshot CSI | File System Backup (ce qu'on utilise) |
|---|---|---|
| Où atterrit la copie | **dans Longhorn**, sur les disques des workers qu'on protège | dans **MinIO**, donc en dehors du volume protégé |
| Survit à un `vagrant destroy` | ❌ non | ✅ oui |
| Prérequis supplémentaires | le contrôleur external-snapshotter + une `VolumeSnapshotClass` — **aucun des deux n'est installé par ce lab** | rien de plus que le DaemonSet `node-agent` |
| StorageClass couvertes | celles dont le driver CSI gère les snapshots | **toutes** — `longhorn`, `longhorn-r1`, `local-path` |
| Coût | instantané (copy-on-write) | lit et envoie les octets, dédupliqués par kopia |

Un snapshot est un mécanisme de *retour arrière*, une sauvegarde est un mécanisme de *copie
ailleurs*. Sur un lab dont tout l'intérêt est d'être détruit et reconstruit, seul le second
mérite le nom.

> ℹ️ Longhorn a aussi sa **propre** cible de sauvegarde S3, configurable dans son UI. C'est un
> bon outil, et il ne couvre que les volumes Longhorn — ni les manifestes, ni `local-path`. Les
> deux cohabitent sans conflit ; cet addon couvre délibérément tout le cluster à la place.

### Fichiers

| Fichier | Rôle |
|---|---|
| `velero-up.sh` | **l'install** : bucket MinIO + utilisateur restreint, namespace, Secret de credentials, chart, Schedule |
| `values.yaml` | Valeurs Helm : l'init container du plugin AWS, la `BackupStorageLocation`, les défauts FSB, le `node-agent` |
| `schedule.yaml` | `Schedule daily-full` — tout le cluster, 02:00, TTL 7 jours |

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Un **MinIO** dans le cluster — `../minio-s3/cluster/` de préférence, `../minio-s3/` accepté | le magasin d'objets. `velero-up.sh` prend `minio-cluster` d'abord, se rabat sur `minio-s3`, et `VELERO_MINIO_NS=…` force les deux | `kubectl -n minio-cluster get svc minio` |
| Namespace `velero` en PodSecurity `privileged` | le `node-agent` monte le dossier de pods du kubelet (hostPath), ce que `baseline` interdit — **posé par `velero-up.sh`** | `kubectl get ns velero --show-labels` |
| `helm`, `curl`, `openssl` dans le `PATH` | le chart, le téléchargement de `mc`, la clé d'accès générée | `helm version` |
| `mc` (client MinIO) | crée le bucket et l'utilisateur restreint — **téléchargé automatiquement** s'il manque | `mc --version` |
| CLI `velero` — **optionnelle** | tout ici est en CRD pures, mais une restauration sans la CLI est pénible | `velero version --client-only` |
| Un addon de **stockage**, si vous voulez des données de volume à sauvegarder | sans PVC dans le cluster, Velero ne sauvegarde que les objets — ce n'est pas une panne, juste une moitié vide | `kubectl get pvc -A` |

> ℹ️ **Pas d'IP LoadBalancer, pas de Gateway, pas d'enregistrement DNS.** Velero parle à
> `minio.<ns>.svc.cluster.local:9000`, une ClusterIP : cet addon se comporte à l'identique que
> les IP LoadBalancer du lab viennent de l'annonceur L2 de Cilium ou de
> [`../metallb/`](../metallb/LISEZ-MOI.md), et il continue de fonctionner quand aucun des deux
> n'est installé.

## ⚡ Installation

> 🎓 **Deux chemins, même résultat** : le script tout-en-un ci-dessous, ou la section
> **« Pas à pas guidé »** plus bas — les mêmes commandes, une par une, pour une formation.

Via le point d'entrée du dépôt :
```bash
./install.sh <distro> velero       # <distro> = talos | kubeadm
```

Versions épinglées : chart **Velero 12.1.0** (app **v1.18.1**), plugin
**`velero/velero-plugin-for-aws:v1.14.2`**.

```bash
./velero/velero-up.sh <distro>
```

Idempotent : `helm upgrade --install` + `kubectl apply`, et l'utilisateur MinIO **garde sa clé
d'accès existante** (en régénérer une à chaque passage ferait silencieusement échouer tous les
envois en 403).

| Variable | Défaut | Effet |
|---|---|---|
| `VELERO_VERSION` | `12.1.0` | version du chart |
| `VELERO_AWS_PLUGIN_VERSION` | `v1.14.2` | plugin de magasin d'objets — doit correspondre à la mineure de Velero (v1.14.x ↔ v1.18.x) |
| `VELERO_MINIO_NS` | détecté | quel MinIO viser (`minio-cluster`, puis `minio-s3`) |
| `VELERO_BUCKET` | `velero` | nom du bucket — créé s'il manque |
| `VELERO_S3_USER` | `velero` | utilisateur MinIO, restreint à ce seul bucket |
| `VELERO_NS` | `velero` | namespace de Velero lui-même |

## 🧬 Talos vs kubeadm

**Aucune divergence à l'installation** : les mêmes 4 étapes, le même chart, les mêmes valeurs
sur les deux labs. La seule ligne qui casserait sur Talos si on la laissait implicite est portée
par une variable de profil, `VELERO_POD_VOLUME_PATH`.

| | Talos | kubeadm |
|---|---|---|
| hostPath du `node-agent` | `/var/lib/kubelet/pods` — ça marche **parce que** le dossier racine du kubelet est sous `/var`, le seul système de fichiers inscriptible (`/` et `/usr` sont en lecture seule) | `/var/lib/kubelet/pods` — le chemin upstream sur un système de fichiers ordinaire, rien de particulier |
| Label PodSecurity `privileged` sur `velero` | **obligatoire** : `baseline` est imposé sur tout le cluster et interdit les volumes hostPath. Sans le label, le DaemonSet existe et ne crée **aucun** pod — en silence | documente le besoin ; n'impose rien aujourd'hui |
| Outillage hôte | `kubectl`, `helm`, `curl`, `openssl` (`mc` téléchargé automatiquement) | identique — **pas de `talosctl`**, Velero ne touche jamais à la configuration des nodes |
| Étapes du script | **4** | **4** |
| Ce qui finit dans la sauvegarde | identique : les objets, plus tout volume de pod monté | identique |

Pourquoi une variable pour une valeur identique des deux côtés : ça transforme « le défaut du
chart tombe juste sur Talos » en **fait vérifié**. Une image d'installation qui déplacerait la
racine du kubelet (`--root-dir`) demanderait exactement une ligne de changement, dans
`lib/profiles/talos.sh`, et pas un seul `if` dans cet addon — la règle que ce dépôt applique à
toute divergence (voir [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-ce-qui-diffère-vraiment-entre-les-deux-labs)).

## 🎓 Pas à pas guidé

> Les commandes ci-dessous sont **exactement** ce que fait `velero-up.sh`, dans l'ordre.
> Préparez d'abord votre shell (une fois par session) :
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig      # ou ../Vagrant-KubeADM/kubeconfig
> export MINIO_NS=minio-cluster                      # ou minio-s3
> ```

### 1. Namespace + PodSecurity `privileged`

```bash
kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace velero \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite
```

> ⚠️ Sur Talos, oublier ce label est la panne **silencieuse** classique :
> `kubectl -n velero get ds` affiche `DESIRED 6 / READY 0` et aucun pod. La raison est dans les
> événements du DaemonSet, nulle part ailleurs : `violates PodSecurity "baseline": hostPath volumes`.

### 2. Le bucket et un utilisateur MinIO restreint

On ne donne jamais les credentials root de MinIO à un agent cluster-admin.

```bash
ROOTPW=$(kubectl -n "$MINIO_NS" get secret minio-creds -o jsonpath='{.data.root-password}' | base64 -d)
kubectl -n "$MINIO_NS" port-forward svc/minio 19010:9000 &
mc alias set _lab http://127.0.0.1:19010 admin "$ROOTPW"

mc mb --ignore-existing _lab/velero
cat > /tmp/velero-policy.json <<'JSON'
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::velero","arn:aws:s3:::velero/*"]} ]}
JSON
mc admin policy create _lab velero-rw /tmp/velero-policy.json
SK=$(openssl rand -base64 21 | tr -d '/+=' | head -c 28)
mc admin user add _lab velero "$SK"
mc admin policy attach _lab velero-rw --user velero
kill %1                                  # le port-forward a fait son travail
```

### 3. Le Secret de credentials — une clé `cloud`, un fichier de credentials AWS

```bash
kubectl -n velero create secret generic velero-s3 \
  --from-literal=cloud="$(printf '[default]\naws_access_key_id=velero\naws_secret_access_key=%s\n' "$SK")" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 4. Le chart

```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts && helm repo update vmware-tanzu
# values.yaml vise minio-cluster par défaut ; pointez le vôtre s'il est ailleurs :
sed "s#minio\.minio-cluster\.svc#minio.${MINIO_NS}.svc#" velero/values.yaml > /tmp/velero-values.yaml
helm upgrade --install velero vmware-tanzu/velero \
  --namespace velero \
  --version 12.1.0 \
  --values /tmp/velero-values.yaml \
  --set nodeAgent.podVolumePath=/var/lib/kubelet/pods \
  --wait --timeout 10m
kubectl -n velero rollout status deploy/velero
kubectl -n velero rollout status ds/node-agent
```

### 5. Le verdict de Velero lui-même sur le bucket

Un `helm install` qui réussit ne prouve rien sur les credentials. Ceci, si :

```bash
kubectl -n velero get backupstoragelocation default
# NAME      PHASE       LAST VALIDATED   AGE   DEFAULT
# default   Available   10s              1m    true
```

### 6. La sauvegarde récurrente

```bash
kubectl apply -f velero/schedule.yaml
kubectl -n velero get schedules
```

## 🔧 Ce que fait le script

| Étape | Action |
|---|---|
| `[1/4]` | namespace `velero` + les trois labels PodSecurity `privileged` |
| `[2/4]` | MinIO : bucket `velero`, policy `velero-rw`, utilisateur `velero` restreint, puis le Secret `velero-s3` |
| `[3/4]` | chart Helm avec l'endpoint résolu, puis attente de `BackupStorageLocation: Available` |
| `[4/4]` | `kubectl apply -f schedule.yaml` |

### Les réglages Helm qui comptent

| Réglage | Valeur | Pourquoi |
|---|---|---|
| `initContainers[0]` | `velero-plugin-for-aws:v1.14.2` | l'image Velero n'embarque **aucun** plugin de provider ; sans lui le serveur boucle sur `unable to locate ObjectStore plugin for aws` |
| `config.s3ForcePathStyle` | `"true"` | MinIO sert un bucket comme un **chemin** (`minio:9000/velero`), pas comme un sous-domaine |
| `config.region` | `us-east-1` | MinIO l'ignore, le SDK AWS **refuse de signer** sans |
| `deployNodeAgent` | `true` | pas de DaemonSet, pas de données de volume — les objets seuls |
| `defaultVolumesToFsBackup` | `true` | couvre chaque volume de pod sans annotation par application |
| `uploaderType` | `kopia` | dédupliqué et compressé ; restic est l'ancien monde |
| `snapshotsEnabled` | `false` | pas de `VolumeSnapshotLocation` : il n'y a pas de contrôleur de snapshot dans ce lab, et une VSL en provider AWS ne produirait que des erreurs |
| `defaultBackupTTL` | `168h` | 7 jours — chaque octet atterrit sur le disque partagé des workers |

### Les objets que Velero crée

| Kind | Rôle |
|---|---|
| `BackupStorageLocation` | le bucket et sa santé (`Available` / `Unavailable`) |
| `Schedule` | une fabrique de `Backup` — un objet par tick |
| `Backup` / `Restore` | une exécution chacun ; le tarball vit dans le bucket, l'objet dans etcd |
| `PodVolumeBackup` / `PodVolumeRestore` | **un par volume** : c'est là qu'apparaissent l'avancement et les échecs du FSB |
| `BackupRepository` | le dépôt kopia, un par (namespace, storage location) |

## ✅ Vérifier

```bash
kubectl -n velero get backupstoragelocation default        # PHASE=Available
kubectl -n velero get pods                                 # velero + un node-agent PAR NODE
kubectl -n velero get schedules                            # daily-full

# La vraie preuve : une sauvegarde qui va au bout, avec ses volumes
velero backup create smoke --wait
velero backup describe smoke --details | sed -n '/Phase/p;/Item/p'
kubectl -n velero get podvolumebackups                     # une ligne par volume monté, Completed
```

Sans la CLI, la même chose en `kubectl` seul :

```bash
kubectl -n velero create -f - <<'EOF'
apiVersion: velero.io/v1
kind: Backup
metadata: { name: smoke, namespace: velero }
spec: { defaultVolumesToFsBackup: true, ttl: 168h }
EOF
kubectl -n velero get backup smoke -o jsonpath='{.status.phase}{"\n"}'    # Completed
```

Et les objets ont bien atterri dans MinIO :

```bash
kubectl -n minio-cluster port-forward svc/minio 19010:9000 &
mc ls -r _lab/velero/backups/smoke/
kill %1
```

## 🧪 Scénario — supprimer un namespace avec ses données Longhorn, et le récupérer

La démo qui justifie l'addon. Elle demande une StorageClass
([`../longhorn/`](../longhorn/LISEZ-MOI.md) ; `local-path` marche aussi).

```bash
# 1. Une application avec un volume, et un octet reconnaissable
kubectl create namespace demo-backup
kubectl apply -n demo-backup -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: data }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources: { requests: { storage: 1Gi } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: writer }
spec:
  replicas: 1
  selector: { matchLabels: { app: writer } }
  template:
    metadata: { labels: { app: writer } }
    spec:
      containers:
        - name: sh
          image: busybox:1.37
          command: ["sh", "-c", "sleep infinity"]
          volumeMounts: [{ name: data, mountPath: /data }]
      volumes:
        - { name: data, persistentVolumeClaim: { claimName: data } }
EOF
kubectl -n demo-backup rollout status deploy/writer
kubectl -n demo-backup exec deploy/writer -- sh -c 'echo "precieux" > /data/proof.txt'

# 2. On sauvegarde — la définition du PVC ET les octets
velero backup create demo-backup-1 --include-namespaces demo-backup --wait
kubectl -n velero get podvolumebackups           # une ligne Completed pour le volume `data`

# 3. Le sinistre
kubectl delete namespace demo-backup
kubectl get pvc -n demo-backup                   # disparu, volume compris

# 4. La restauration
velero restore create --from-backup demo-backup-1 --wait
kubectl -n demo-backup rollout status deploy/writer
kubectl -n demo-backup exec deploy/writer -- cat /data/proof.txt      # precieux

# 5. Nettoyage
kubectl delete namespace demo-backup
```

> ℹ️ L'étape 4 est celle où le FSB se montre : Velero recrée le PVC, puis le `node-agent`
> injecte un init container `restore-wait` dans le pod, qui bloque le démarrage tant que les
> données ne sont pas réécrites. Un pod bloqué en `Init:0/1` un moment est normal — surveillez
> `kubectl -n velero get podvolumerestores`.

## 🚑 Dépannage

| Symptôme | Cause | Correction |
|---|---|---|
| `BackupStorageLocation` en `Unavailable` | mauvais credentials, bucket absent, MinIO à terre | `kubectl -n velero logs deploy/velero \| tail -30` ; relancer `velero-up.sh` (il répare le bucket, la policy et le Secret) |
| Le serveur logue `unable to locate ObjectStore plugin for aws` | l'init container n'a jamais tourné (valeurs écrasées, `initContainers` vidé) | `kubectl -n velero get deploy velero -o jsonpath='{.spec.template.spec.initContainers[*].image}'` |
| `node-agent` en `DESIRED n / READY 0`, **aucun pod** | le namespace n'est pas labellisé `privileged` (Talos) | `kubectl label ns velero pod-security.kubernetes.io/enforce=privileged --overwrite` |
| Sauvegarde en `PartiallyFailed`, un `PodVolumeBackup` en `Failed` | un volume que l'agent ne peut pas lire (hostPath, volume non monté) | `kubectl -n velero get podvolumebackups -o wide`, puis les logs du pod concerné |
| Tout tombe en 403 après une réinstallation de MinIO | MinIO a perdu l'utilisateur `velero`, le Secret porte encore l'ancienne clé | supprimer le Secret et relancer : `kubectl -n velero delete secret velero-s3 && ./velero/velero-up.sh <distro>` |
| L'envoi échoue sur une erreur de checksum/signature | certaines implémentations S3 rejettent le checksum par défaut du SDK | ajouter `checksumAlgorithm: ""` au bloc `config:` de `values.yaml` ([README du plugin](https://github.com/vmware-tanzu/velero-plugin-for-aws#compatibility)) |
| `velero: command not found` | la CLI est optionnelle et pas installée | utiliser les formes `kubectl` ci-dessus, ou l'installer (voir Références) |

## ⚠️ Pièges

- **Le FSB ne sauvegarde qu'un volume monté par un pod.** Un PVC lié à rien — ou lié à un pod
  scalé à zéro — voit sa *définition* sauvegardée et son *contenu* ignoré, sans erreur. Remontez
  l'application avant de sauvegarder des données qui comptent, et regardez
  `kubectl -n velero get podvolumebackups` plutôt que de faire confiance au seul
  `Phase: Completed` du Backup.
- **Les volumes `hostPath` ne sont jamais sauvegardés par le FSB** (par conception). Dans ce lab
  ça ne concerne guère que les DaemonSets système, ce qui va bien — mais n'attendez pas que les
  dossiers *node* de `local-path` reviennent autrement que par leur PVC.
- **`defaultVolumesToFsBackup: true` embarque aussi les `emptyDir`.** Le WAL de Prometheus et
  autres volumes de travail seront envoyés. Excluez volume par volume :
  ```bash
  kubectl -n <ns> annotate pod <pod> backup.velero.io/backup-volumes-excludes=cache,tmp
  ```
- **Ne comptez pas sur Velero pour restaurer MinIO lui-même.** La sauvegarde du namespace
  `minio-cluster` vit *dans* `minio-cluster` : si MinIO n'est plus là, la sauvegarde non plus.
  La résilience de MinIO, c'est son erasure coding, pas cet addon.
- **Un Service `LoadBalancer` restauré ne reprend pas forcément la même IP.** L'annonceur
  (Cilium L2 ou MetalLB) réalloue depuis le pool. Si un enregistrement DNS pointe sur `.200`,
  vérifiez où le Gateway est retombé après une restauration complète.
- **Une restauration de tout le cluster inclut le namespace `velero`** sauf si on l'exclut. Dans
  un cluster neuf, utilisez `velero restore create --from-backup <b> --exclude-namespaces velero`,
  sinon la restauration se bat contre le Velero qui l'exécute.
- **Le cron du `Schedule` est lu dans le fuseau du serveur** (UTC dans ce lab), pas celui de
  votre poste. `0 2 * * *`, c'est 13:00 à Nouméa.
- **`velero backup delete` supprime aussi les objets du bucket** ; `kubectl delete backup` ne
  supprime que l'objet Kubernetes et laisse le tarball orphelin dans MinIO.
- **Le TTL est de 7 jours.** Un lab éteint quinze jours revient avec un bucket vide — le GC
  tourne sur l'horloge de Velero, pas sur le besoin qu'on avait de cette sauvegarde.

## 🧹 Désinstallation

```bash
kubectl delete -f velero/schedule.yaml
helm uninstall velero -n velero
kubectl delete namespace velero          # emporte les CR ; les CRD survivent
kubectl get crd | sed -n '/velero.io/p' | awk '{print $1}' | xargs -r kubectl delete crd
# Le bucket n'est PAS supprimé : mc rb --force _lab/velero
```

## 📚 Références

- [Velero — File System Backup](https://velero.io/docs/v1.18/file-system-backup/) — ce que le FSB couvre et ne couvre pas
- [Velero — Backup reference](https://velero.io/docs/v1.18/backup-reference/) · [Restore reference](https://velero.io/docs/v1.18/restore-reference/)
- [Velero — Install the CLI](https://velero.io/docs/v1.18/basic-install/#install-the-cli)
- [velero-plugin-for-aws](https://github.com/vmware-tanzu/velero-plugin-for-aws) — la matrice de versions et les notes sur les providers S3-compatibles
- [`../minio-s3/cluster/LISEZ-MOI.md`](../minio-s3/cluster/LISEZ-MOI.md) — la cible de sauvegarde
- [`../longhorn/LISEZ-MOI.md`](../longhorn/LISEZ-MOI.md) — les volumes dont les données finissent dans le bucket
