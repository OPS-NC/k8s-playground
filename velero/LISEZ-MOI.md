<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# ⛵ `velero/` — sauvegarde et restauration du cluster (objets **et** données des PV Longhorn) vers MinIO

> Velero écrit deux choses dans le même bucket S3 : les **objets Kubernetes** (tous les
> manifestes, namespacés et cluster-scoped) et le **contenu des volumes persistants** — Longhorn
> compris — via le File System Backup. Un namespace supprimé par erreur, PVC et données
> incluses, revient avec un seul `velero restore create` — ou en trois clics dans l'UI installée
> avec, sur `velero.<LAB_DOMAIN>`.

> 🌐 Deux moitiés, deux modes d'exposition. Les **sauvegardes** ne quittent jamais le réseau de
> pods : Velero joint MinIO par le Service interne, donc `schedule.yaml` ne porte aucun domaine
> et un `kubectl apply` à la main fait exactement ce que fait le script. **L'UI**, elle, porte
> bien le domaine neutre (`ui-httproute.yaml`), substitué à la volée comme partout ailleurs.

## 🎯 À quoi ça sert

Sauvegarder un cluster Kubernetes, ce sont deux problèmes qu'on confond en permanence :

| Quoi | Où ça vit | Comment Velero le prend |
|---|---|---|
| **Les objets** — Deployments, Secrets, *définitions* de PVC, CRD, ClusterRole… | etcd | listés via l'API server, écrits sous forme d'un tarball par sauvegarde dans le bucket |
| **Les données** — les octets à l'intérieur d'un volume Longhorn (ou `local-path`) | le disque des workers | **File System Backup** : le DaemonSet `node-agent` lit le volume là où le kubelet l'a déjà monté et l'envoie dans le **même** bucket avec kopia |

Ne restaurer que le premier, c'est obtenir un cluster plein de PVC vides. Cet addon fait les
deux, et les fait au même endroit — le bucket `velero` du MinIO du lab.

### Deux coûts, deux cadences

La distinction ci-dessus n'est pas théorique : c'est pour ça qu'il y a **deux** schedules et non
un seul.

| Schedule | Cron | Ce qu'il écrit | TTL | Coût par tick |
|---|---|---|---|---|
| **`hourly-objects`** | `0 * * * *` | les objets **seulement** | `48h` | un tarball, quelques Mo, des secondes |
| **`daily-full`** | `0 2 * * *` | les objets **+ tous les volumes de pods** | `168h` | le node-agent relit chaque volume |

Donc : un **RPO d'environ 1 heure** sur « quelqu'un a supprimé un Deployment / un Secret / un
namespace entier », et un **RPO d'environ 24 heures** sur « les octets dans un PVC sont faux ».
Sauvegarder les manifestes chaque heure est quasi gratuit ; faire pareil avec les données des
volumes occuperait le `node-agent` en permanence pour un lab qui change quelques fichiers par
jour.

> ⚠️ **Une sauvegarde `hourly-objects` contient les *définitions* de PVC et de PV, pas leur
> contenu.** Restaurer depuis l'une d'elles recrée les PVC **vides** (Longhorn provisionne des
> volumes neufs). C'est le bon choix pour « annuler mon dernier `kubectl apply` », et le mauvais
> pour « récupérer mes données » — pour ça, restaure le dernier `daily-full`.
> `velero backup describe <nom>` dit de quel type il s'agit, et le nombre de
> `PodVolumeBackup` (`kubectl -n velero get podvolumebackups`) vaut zéro pour toutes les
> horaires.

### L'UI — ce qu'elle change

[velero-ui](https://velero-ui.docs.otwld.com/) (otwld) est livrée avec l'addon et atterrit dans
le même namespace, sur `https://velero.<LAB_DOMAIN>`. Ce n'est pas de la décoration : sans elle,
lire une sauvegarde passe par `velero backup describe --details`, et *cette commande ne
fonctionne pas depuis votre poste* dans ce lab (elle fabrique une URL présignée contre un nom DNS
interne au cluster — voir les pièges). L'UI, elle, tourne dans le cluster : le problème ne se
pose pas.

| | CLI | UI |
|---|---|---|
| Parcourir sauvegardes, schedules, `PodVolumeBackup` | oui | oui, avec leur état en direct |
| Lire les erreurs d'une sauvegarde `PartiallyFailed` | ❌ **cassé depuis l'hôte** (URL présignée) | ✅ elle est dans le cluster |
| Créer une sauvegarde / lancer une restauration | oui | oui, par formulaire |
| Scripting, CI | ✅ | ❌ |

> ⚠️ **Son ServiceAccount est `cluster-admin`.** Un outil qui restaure des objets arbitraires
> dans des namespaces arbitraires ne peut pas être moins que ça — le ServiceAccount de Velero
> lui-même a les mêmes droits. Mais ça veut dire que le tableau de bord est un chemin de prise de
> contrôle complet derrière un seul mot de passe. Acceptable sur un lab ; `VELERO_UI=false` si
> vous préférez vous en passer.

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
| `velero-up.sh` | **l'install** : bucket MinIO + utilisateur restreint, namespace, Secret de credentials, chart, Schedules, UI |
| `values.yaml` | Valeurs Helm : l'init container du plugin AWS, la `BackupStorageLocation`, les défauts FSB, le `node-agent` |
| `schedule.yaml` | **deux** `Schedule` — `hourly-objects` (objets, TTL 48h) et `daily-full` (objets + données des PV, 02:00, TTL 7 jours) |
| `ui-values.yaml` | Valeurs Helm de velero-ui : basic auth câblée sur le Secret `velero-ui-auth`, RBAC, Ingress du chart désactivé |
| `ui-httproute.yaml` | la route de l'UI sur `main-gateway` — `velero.<LAB_DOMAIN>`, listener `https`, certificat wildcard |

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Un **MinIO** dans le cluster — `../minio-s3/cluster/` de préférence, `../minio-s3/` accepté | le magasin d'objets. `velero-up.sh` prend `minio-cluster` d'abord, se rabat sur `minio-s3`, et `VELERO_MINIO_NS=…` force les deux | `kubectl -n minio-cluster get svc minio` |
| Namespace `velero` en PodSecurity `privileged` | le `node-agent` monte le dossier de pods du kubelet (hostPath), ce que `baseline` interdit — **posé par `velero-up.sh`** | `kubectl get ns velero --show-labels` |
| `helm`, `curl`, `openssl` dans le `PATH` | le chart, le téléchargement de `mc`, la clé d'accès générée | `helm version` |
| `mc` (client MinIO) | crée le bucket et l'utilisateur restreint — **téléchargé automatiquement** s'il manque | `mc --version` |
| CLI `velero` — **optionnelle** | tout ici est en CRD pures, mais une restauration sans la CLI est pénible | `velero version --client-only` |
| Un addon de **stockage**, si vous voulez des données de volume à sauvegarder | sans PVC dans le cluster, Velero ne sauvegarde que les objets — ce n'est pas une panne, juste une moitié vide | `kubectl get pvc -A` |
| La **plateforme** (`main-gateway` + TLS wildcard) — **pour l'UI seulement** | la HTTPRoute du tableau de bord. S'en passer coûte la route et rien d'autre : le script prévient, la saute et va au bout | `kubectl -n envoy-gateway-system get gateway main-gateway` |

> ℹ️ **Les sauvegardes n'ont besoin ni d'IP LoadBalancer, ni de Gateway, ni d'enregistrement
> DNS.** Velero parle à `minio.<ns>.svc.cluster.local:9000`, une ClusterIP : cette moitié se
> comporte à l'identique que les IP LoadBalancer du lab viennent de l'annonceur L2 de Cilium ou
> de [`../metallb/`](../metallb/LISEZ-MOI.md), et elle continue de fonctionner quand aucun des
> deux n'est installé. Seule l'**UI** a besoin de la Gateway — et elle se rabat sur un
> `port-forward` au lieu de faire échouer l'installation.

## ⚡ Installation

Via le point d'entrée du dépôt :
```bash
./install.sh <distro> velero       # <distro> = talos | kubeadm
```

Versions épinglées : chart **Velero 12.1.0** (app **v1.18.1**), plugin
**`velero/velero-plugin-for-aws:v1.14.2`**, chart d'UI **otwld/velero-ui 0.15.0**
(app **0.10.2**).

```bash
./velero/velero-up.sh <distro>
```

L'UI vient avec, sur `https://velero.<LAB_DOMAIN>`, utilisateur `admin`. Le mot de passe est
généré à la première installation et **conservé d'un passage à l'autre** :

```bash
kubectl -n velero get secret velero-ui-auth -o jsonpath='{.data.password}' | base64 -d ; echo
```

Idempotent : `helm upgrade --install` + `kubectl apply` ; l'utilisateur MinIO **garde sa clé
d'accès existante** (en régénérer une à chaque passage ferait silencieusement échouer tous les
envois en 403) et l'UI garde son mot de passe pour la même raison — un mot de passe régénéré à
chaque exécution est un mot de passe que personne ne peut noter.

| Variable | Défaut | Effet |
|---|---|---|
| `VELERO_VERSION` | `12.1.0` | version du chart |
| `VELERO_AWS_PLUGIN_VERSION` | `v1.14.2` | plugin de magasin d'objets — doit correspondre à la mineure de Velero (v1.14.x ↔ v1.18.x) |
| `VELERO_MINIO_NS` | détecté | quel MinIO viser (`minio-cluster`, puis `minio-s3`) |
| `VELERO_BUCKET` | `velero` | nom du bucket — créé s'il manque |
| `VELERO_S3_USER` | `velero` | utilisateur MinIO, restreint à ce seul bucket |
| `VELERO_NS` | `velero` | namespace de Velero lui-même — l'UI y atterrit aussi |
| `VELERO_UI` | `true` | `false` saute complètement le tableau de bord (ni chart, ni Secret, ni route) |
| `VELERO_UI_VERSION` | `0.15.0` | version du chart `otwld/velero-ui` |
| `VELERO_UI_USER` | `admin` | l'identifiant basic-auth du tableau de bord |
| `MC_ALIAS` | `labminio` | l'alias `mc` temporaire du port-forward. **Doit commencer par une lettre** — sinon `mc` refuse le nom (c'est ce qui cassait l'install avec l'ancien `_lab`), et il évite volontairement `lab` tout court pour ne jamais écraser votre propre alias |

## 🧬 Talos vs kubeadm

**Aucune divergence à l'installation** : les mêmes 5 étapes, les mêmes charts, les mêmes valeurs
sur les deux labs. La seule ligne qui casserait sur Talos si on la laissait implicite est portée
par une variable de profil, `VELERO_POD_VOLUME_PATH`.

| | Talos | kubeadm |
|---|---|---|
| hostPath du `node-agent` | `/var/lib/kubelet/pods` — ça marche **parce que** le dossier racine du kubelet est sous `/var`, le seul système de fichiers inscriptible (`/` et `/usr` sont en lecture seule) | `/var/lib/kubelet/pods` — le chemin upstream sur un système de fichiers ordinaire, rien de particulier |
| Label PodSecurity `privileged` sur `velero` | **obligatoire** : `baseline` est imposé sur tout le cluster et interdit les volumes hostPath. Sans le label, le DaemonSet existe et ne crée **aucun** pod — en silence | documente le besoin ; n'impose rien aujourd'hui |
| Outillage hôte | `kubectl`, `helm`, `curl`, `openssl` (`mc` téléchargé automatiquement) | identique — **pas de `talosctl`**, Velero ne touche jamais à la configuration des nodes |
| Étapes du script | **5** | **5** |
| L'UI | Deployment ordinaire, sans hostPath ni privilège — s'installe à l'identique | identique |
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
mc alias set labminio http://127.0.0.1:19010 admin "$ROOTPW"

mc mb --ignore-existing labminio/velero
cat > /tmp/velero-policy.json <<'JSON'
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::velero","arn:aws:s3:::velero/*"]} ]}
JSON
mc admin policy create labminio velero-rw /tmp/velero-policy.json
SK=$(openssl rand -base64 21 | tr -d '/+=' | head -c 28)
mc admin user add labminio velero "$SK"
mc admin policy attach labminio velero-rw --user velero
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

### 6. Les sauvegardes récurrentes

```bash
kubectl apply -f velero/schedule.yaml
kubectl -n velero get schedules      # hourly-objects + daily-full, avec leurs crons
```

### 7. L'UI et ses credentials

Le mot de passe est frappé ici, une fois. Relancer le script le relit dans le Secret au lieu de
le remplacer.

```bash
kubectl -n velero create secret generic velero-ui-auth \
  --from-literal=username=admin \
  --from-literal=password="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)" \
  --from-literal=pass_phrase="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

helm repo add otwld https://helm.otwld.com/ && helm repo update otwld
helm upgrade --install velero-ui otwld/velero-ui \
  --namespace velero --version 0.15.0 \
  --values velero/ui-values.yaml --wait --timeout 5m

sed 's/lab\.example\.io/'"$LAB_DOMAIN"'/g' velero/ui-httproute.yaml | kubectl apply -f -
```

> ⚠️ **Le chart crée un Secret de passphrase JWT et ne le monte jamais.** En 0.15.0,
> `helm template` ne montre aucun `AUTH_SECRET_PASSPHRASE` dans le Deployment : l'application
> retombe sur son défaut documenté (`this is not a secret passphrase`) et signe des jetons
> prévisibles, pendant qu'un Secret `velero-ui-passphrase` traîne dans le namespace en laissant
> croire le contraire. `ui-values.yaml` coupe ce mécanisme et câble la variable via `env:`.
> À revérifier après une montée de version du chart :
> ```bash
> kubectl -n velero get deploy velero-ui \
>   -o jsonpath='{.spec.template.spec.containers[0].env[*].name}{"\n"}'
> ```

## 🔧 Ce que fait le script

| Étape | Action |
|---|---|
| `[1/5]` | namespace `velero` + les trois labels PodSecurity `privileged` |
| `[2/5]` | MinIO : bucket `velero`, policy `velero-rw`, utilisateur `velero` restreint, puis le Secret `velero-s3` |
| `[3/5]` | chart Helm avec l'endpoint résolu, puis attente de `BackupStorageLocation: Available` |
| `[4/5]` | `kubectl apply -f schedule.yaml` — les **deux** Schedule (`hourly-objects`, `daily-full`) |
| `[5/5]` | Secret `velero-ui-auth` (généré une fois), le chart de l'UI et sa HTTPRoute — sauté avec `VELERO_UI=false`, route seule sautée si la Gateway API est absente |

### Les réglages Helm qui comptent

| Réglage | Valeur | Pourquoi |
|---|---|---|
| `initContainers[0]` | `velero-plugin-for-aws:v1.14.2` | l'image Velero n'embarque **aucun** plugin de provider ; sans lui le serveur boucle sur `unable to locate ObjectStore plugin for aws` |
| `config.s3ForcePathStyle` | `"true"` | MinIO sert un bucket comme un **chemin** (`minio:9000/velero`), pas comme un sous-domaine |
| `config.region` | `us-east-1` | MinIO l'ignore, le SDK AWS **refuse de signer** sans |
| `deployNodeAgent` | `true` | pas de DaemonSet, pas de données de volume — les objets seuls |
| `defaultVolumesToFsBackup` | `true` | couvre chaque volume de pod sans annotation par application — et c'est un défaut **au niveau du serveur**, ce qui est précisément pourquoi `hourly-objects` doit le repasser explicitement à `false` |
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
kubectl -n velero get pods                                 # velero + velero-ui + un node-agent PAR NODE
kubectl -n velero get schedules                            # hourly-objects + daily-full

# La vraie preuve : une sauvegarde qui va au bout, avec ses volumes
velero backup create smoke --wait
velero backup describe smoke --details | sed -n '/Phase/p;/Item/p'
kubectl -n velero get podvolumebackups                     # une ligne par volume monté, Completed
```

Vérifier que les deux cadences diffèrent vraiment — le compte de `PodVolumeBackup` est le
révélateur :

```bash
# objets seuls : on attend ZÉRO PodVolumeBackup pour cette sauvegarde
velero backup create objs-only --snapshot-volumes=false --default-volumes-to-fs-backup=false --wait
kubectl -n velero get podvolumebackups -l velero.io/backup-name=objs-only    # « No resources found »

# objets + données : on attend un PodVolumeBackup par volume monté
velero backup create full-now --default-volumes-to-fs-backup --wait
kubectl -n velero get podvolumebackups -l velero.io/backup-name=full-now     # tous Completed
```

Sans la CLI, la même chose en `kubectl` seul :

```bash
kubectl -n velero create -f - <<'EOF'
apiVersion: velero.io/v1
kind: Backup
metadata: { name: smoke, namespace: velero }
spec: { defaultVolumesToFsBackup: true, ttl: 168h }
EOF
kubectl -n velero get backups.velero.io smoke -o jsonpath='{.status.phase}{"\n"}'    # Completed
```

Et les objets ont bien atterri dans MinIO :

```bash
kubectl -n minio-cluster port-forward svc/minio 19010:9000 &
mc ls -r labminio/velero/backups/smoke/
kill %1
```

L'UI, sans dépendre de la résolution du wildcard par votre DNS :

```bash
GWIP=192.168.56.200
PASS=$(kubectl -n velero get secret velero-ui-auth -o jsonpath='{.data.password}' | base64 -d)

curl -sk -o /dev/null -w '%{http_code}\n' \
  --resolve "velero.$LAB_DOMAIN:443:$GWIP" "https://velero.$LAB_DOMAIN/"        # 200

# La vraie preuve — l'API rend un jeton, et ce jeton lit les objets de Velero :
TOKEN=$(curl -sk --resolve "velero.$LAB_DOMAIN:443:$GWIP" \
  -X POST "https://velero.$LAB_DOMAIN/api/auth/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$PASS\"}" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
curl -sk -o /dev/null -w '%{http_code}\n' --resolve "velero.$LAB_DOMAIN:443:$GWIP" \
  -H "Authorization: Bearer $TOKEN" "https://velero.$LAB_DOMAIN/api/backups"    # 200
```

> ⚠️ **Le `--resolve` n'est pas optionnel.** Le listener `https` est cadré sur
> `*.<LAB_DOMAIN>` : une requête vers l'IP nue n'envoie aucun SNI et Envoy n'a aucun listener à
> qui la donner — `curl -k https://192.168.56.200/` rend `000`, pas un 404. Rien n'est cassé,
> la requête n'a simplement jamais atteint une route.

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
| `velero: command not found` | la CLI est optionnelle et pas installée | utiliser les formes `kubectl` ci-dessus, l'UI, ou l'installer (voir Références) |
| Le login de l'UI rend **500**, pas 401 | le mot de passe est faux. La basic auth l'a rejeté, puis l'application est retombée sur sa stratégie LDAP, non configurée (`LDAP server URL not defined`) | relire le mot de passe : `kubectl -n velero get secret velero-ui-auth -o jsonpath='{.data.password}' \| base64 -d` |
| `https://velero.<LAB_DOMAIN>` expire ou rend `000` | pas de SNI (IP nue), ou le wildcard ne résout pas chez vous | `curl --resolve velero.<LAB_DOMAIN>:443:192.168.56.200 …` ; vérifier `kubectl -n velero get httproute velero-ui` |
| Aucune `httproute` dans `velero` | la Gateway API n'était pas installée au passage du script — il a prévenu et continué | installer la plateforme, puis relancer `./velero/velero-up.sh <distro>` |
| L'UI n'affiche aucune sauvegarde alors que `kubectl` en voit | elle surveille un autre namespace | `kubectl -n velero get deploy velero-ui -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="VELERO_NAMESPACE")]}{.value}{end}'` |

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
  votre poste. `0 2 * * *`, c'est 13:00 à Nouméa, et `hourly-objects` part à l'heure UTC pile.
- **Restaurer la sauvegarde la plus récente n'est pas toujours ce qu'on veut.** Avec deux
  schedules, la dernière sauvegarde est presque toujours une `hourly-objects`, qui ne porte
  **aucune donnée de volume**. Choisissez délibérément :
  `kubectl -n velero get backups.velero.io --sort-by=.metadata.creationTimestamp` puis restaurez depuis la
  dernière `daily-full-*` s'il faut récupérer le contenu des PVC.
- **`kubectl get backups` est AMBIGU dans ce lab et répond en silence à propos de Longhorn.**
  Trois CRD installées revendiquent le kind `Backup` — `longhorn.io`, `velero.io` et
  `postgresql.cnpg.io` — et `kubectl` résout le pluriel nu vers celle de Longhorn. Donc
  `kubectl -n velero get backups` affiche `No resources found in velero namespace.` alors que
  les sauvegardes Velero sont juste là : un faux négatif parfaitement convaincant.
  **Qualifiez toujours** : `kubectl -n velero get backups.velero.io`. `podvolumebackups` et
  `schedules`, eux, ne sont pas ambigus — c'est ce qui rend le piège si facile.
- **`velero backup logs` / `describe --details` échouent depuis votre poste.** Ils demandent à
  l'API server une URL présignée, forgée contre l'endpoint de la BackupStorageLocation —
  `http://minio.<ns>.svc.cluster.local:9000`, un nom DNS interne au cluster que votre hôte ne
  peut pas résoudre (`dial tcp: lookup … no such host`). La sauvegarde elle-même est saine. Pour
  lire les logs ou la liste des erreurs, passez par le bucket :
  ```bash
  kubectl -n <ns-minio> port-forward svc/minio 19010:9000 &
  mc alias set labminio http://127.0.0.1:19010 admin "$ROOTPW"
  mc cp labminio/velero/backups/<backup>/<backup>-results.gz - | gunzip | python3 -m json.tool
  ```
- **`velero backup delete` supprime aussi les objets du bucket** ; `kubectl delete backup` ne
  supprime que l'objet Kubernetes et laisse le tarball orphelin dans MinIO. Le bouton de
  suppression de l'UI est celui de `velero` — il vide l'entrée du bucket aussi.
- **L'UI est `cluster-admin` derrière un seul mot de passe.** Elle restaure des objets
  arbitraires dans des namespaces arbitraires, donc elle ne peut pas l'être moins ; c'est la même
  raison qui donne ces droits au ServiceAccount de Velero. Ce qu'il faut retenir, c'est la
  conséquence : qui atteint `velero.<LAB_DOMAIN>` et devine le mot de passe possède le cluster.
  Le mot de passe est généré (24 caractères aléatoires), jamais `admin/admin` — le défaut
  documenté du chart, que cet addon écrase. `VELERO_UI=false` supprime la surface entièrement.
- **Supprimer le Secret `velero-ui-auth` ne déconnecte personne.** Les JWT déjà émis restent
  valides jusqu'à leur expiration (1 h par défaut), parce qu'ils sont vérifiés contre la
  passphrase, pas contre le Secret. Pour vraiment couper l'accès, faites tourner les **deux** :
  supprimez le Secret et relancez le script — la nouvelle passphrase invalide tous les jetons en
  circulation.
- **Les TTL sont de 48 h (horaire) et 7 jours (quotidien).** Un lab éteint quinze jours revient
  avec un bucket vide — le GC tourne sur l'horloge de Velero, pas sur le besoin qu'on avait de
  cette sauvegarde.
- **24 ticks horaires par jour, ce sont 24 objets `Backup` de plus par jour.** À `48h` de TTL ça
  se stabilise vers ~50 objets ; `kubectl -n velero get backups.velero.io` devient bruyant bien avant de
  devenir coûteux. Filtrez avec `-l velero.io/schedule-name=daily-full` quand seules les
  sauvegardes restaurables-avec-données vous intéressent.

## 🧹 Désinstallation

```bash
kubectl delete -f velero/schedule.yaml
helm uninstall velero-ui -n velero       # l'UI seule, pour continuer à sauvegarder sans tableau de bord
helm uninstall velero -n velero
kubectl delete namespace velero          # emporte les CR ; les CRD survivent
kubectl get crd | sed -n '/velero.io/p' | awk '{print $1}' | xargs -r kubectl delete crd
# Le bucket n'est PAS supprimé : mc rb --force labminio/velero
```

> ℹ️ Le binding `cluster-admin` de l'UI est un objet **cluster-scoped** : supprimer le namespace
> ne l'emporte pas. `helm uninstall` le retire bien — vérifiez qu'il est parti, c'est l'objet
> dont parle le piège sur le chemin d'escalade :
> `kubectl get clusterrolebinding velero-ui`.

## 📚 Références

- [Velero — File System Backup](https://velero.io/docs/v1.18/file-system-backup/) — ce que le FSB couvre et ne couvre pas
- [Velero — Backup reference](https://velero.io/docs/v1.18/backup-reference/) · [Restore reference](https://velero.io/docs/v1.18/restore-reference/)
- [Velero — Install the CLI](https://velero.io/docs/v1.18/basic-install/#install-the-cli)
- [velero-plugin-for-aws](https://github.com/vmware-tanzu/velero-plugin-for-aws) — la matrice de versions et les notes sur les providers S3-compatibles
- [Velero UI (otwld)](https://velero-ui.docs.otwld.com/) — le tableau de bord · [variables d'environnement](https://velero-ui.docs.otwld.com/getting-started/environment-variables) · [otwld/velero-ui](https://github.com/otwld/velero-ui)
- [`../minio-s3/cluster/LISEZ-MOI.md`](../minio-s3/cluster/LISEZ-MOI.md) — la cible de sauvegarde
- [`../longhorn/LISEZ-MOI.md`](../longhorn/LISEZ-MOI.md) — les volumes dont les données finissent dans le bucket
