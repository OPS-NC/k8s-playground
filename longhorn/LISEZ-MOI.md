<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🐮 `longhorn/` — stockage bloc répliqué (Longhorn 1.12) sur Talos **et** kubeadm

> Fournit des `PersistentVolume` **répliqués entre workers** (StorageClass `longhorn`) à partir
> du disque des nodes, sans matériel ni cloud provider. C'est le seul stockage **HA** du lab :
> un volume survit à la perte d'un node, contrairement à `../local-path-storage/`.

## 🎯 À quoi ça sert

Poser deux StorageClass et le CSI qui va avec :

| StorageClass | Réplicas bloc | Par défaut | Pour qui |
|---|---|---|---|
| `longhorn` | un par worker, plafonné à 3 | oui (`values.yaml`) | données à protéger : `../wordpress-example/`, `../vault-cluster/` |
| `longhorn-r1` | 1 | non | `../cloudnative-pg/` et `../observability/` (réplication applicative ou donnée reconstructible) |

Fichiers du dossier :

| Fichier | Rôle |
|---|---|
| `longhorn-up.sh` | **l'install** : namespace, chart + les deux StorageClass + `HTTPRoute` |
| `values.yaml` | Valeurs Helm : `defaultDataPath`, `defaultReplicaCount`, `persistence.defaultClass: true` |
| `longhorn-r1-storageclass.yaml` | StorageClass socle `longhorn-r1` (1 réplica bloc) |
| `httproute.yaml` | `HTTPRoute` HTTPS `longhorn.lab.example.io` → `longhorn-frontend:80` sur `main-gateway` |

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| **iSCSI sur chaque node** — **kubeadm** : paquets `open-iscsi` + `nfs-common`, `iscsid` actif, module `iscsi_tcp`, posés par `kubeadm/provision.sh`. **Talos** : extensions `iscsi-tools` + `util-linux-tools` CUITES dans l'image d'installation (cf. `schematic.yaml`), vérifiées par `longhorn-up.sh` | `longhorn-manager` et le plugin CSI appellent `iscsiadm` pour attacher les volumes. Sans lui, les pods CSI partent en `CrashLoopBackOff` avec `iscsiadm: not found` | kubeadm : `vagrant ssh k8s-w1 -c 'systemctl is-active iscsid'` · Talos : `talosctl -n <ip> get extensions` |
| **Montage kubelet `rshared`** sur `/var/lib/longhorn` — **Talos uniquement** (`patch-longhorn.yaml`, appliqué par `longhorn-up.sh`) | le kubelet Talos tourne dans un conteneur, sans propagation de montage bidirectionnelle | `talosctl -n <ip> get mc -o yaml \| grep /var/lib/longhorn` |
| `talosctl` dans le `PATH` — **Talos uniquement** | vérification des extensions + patch du montage | `talosctl version --client` |
| `helm` dans le `PATH` | le chart | `helm version` |
| Namespace `longhorn-system` en PodSecurity `privileged` | les pods Longhorn sont privilégiés (iSCSI, hostPath) — **posé par `longhorn-up.sh`** | `kubectl get ns longhorn-system --show-labels` |
| `../envoy-gateway/` + `../cert-manager/` (optionnel) | uniquement pour exposer l'UI en HTTPS | `kubectl get gateway -n envoy-gateway-system` |

> ℹ️ **Les deux prérequis lourds n'existent que sur Talos** — c'est ce qui fait de cet addon le
> plus dépendant de la distribution du dépôt :
>
> | Talos | kubeadm / Debian |
> |---|---|
> | **Extensions système** `iscsi-tools` + `util-linux-tools`, *cuites* dans l'image de l'installeur. Un node sans elles n'est pas réparable à chaud — il faut le réinstaller ou l'upgrader vers une nouvelle ref Image Factory. `longhorn-up.sh` ne peut que *vérifier* (`talosctl get extensions`) et refuser d'aller plus loin. | Deux **paquets apt**. `kubeadm/provision.sh` fait `apt-get install -y open-iscsi nfs-common`, `systemctl enable --now iscsid` et charge `iscsi_tcp` (`/etc/modules-load.d/iscsi.conf`) sur **chaque** node, au provisioning. Rien à vérifier, rien à cuire. |
> | **Montage kubelet `rshared`** sur `/var/lib/longhorn`, appliqué par `talosctl patch mc` (à chaud, sans reboot) : le kubelet Talos tourne dans un conteneur et n'a pas la propagation de montage bidirectionnelle. | `/var/lib/longhorn` est un dossier ordinaire du système de fichiers racine, et le kubelet tourne directement sur l'hôte : la propagation de montage est déjà bonne. Rien à patcher. |
>
> Conséquence : sur Talos, `longhorn-up.sh` exige `talosctl` et fait **5** étapes ; sur kubeadm,
> il en fait **3**. Les fichiers `patch-longhorn.yaml` et `schematic.yaml` ne servent que sur
> Talos.

## ⚡ Installation

> 🎓 **Deux chemins, même résultat** : le script tout-en-un ci-dessous, ou la section
> **« Pas à pas guidé »** plus bas — les mêmes commandes, une par une, pour une formation.

Via le point d'entrée du dépôt :
```bash
./install.sh <distro> longhorn     # <distro> = talos | kubeadm
```

Version épinglée : chart **Longhorn 1.12.0**.

```bash
./longhorn/longhorn-up.sh <distro>
```

Idempotent : relançable sans casse (`helm upgrade --install`). Il couvre les **deux** étapes
ci-dessous. Il **compte les workers planifiables sur le cluster réel** (plutôt que de faire
confiance à `WORKERS` de `lab.env`, qui n'exprime qu'une intention) et aligne le nombre de
réplicas bloc dessus, plafonné à 3. `REPLICAS=…` force la valeur, `LONGHORN_VERSION=…` surcharge
la version du chart.

> ℹ️ Avec `WORKERS=0`, les control planes sont déteintés (`UNTAINT_CP=auto`) et deviennent les
> seuls nodes de stockage : le script les compte au lieu de s'arrêter.

### 1. Namespace + Pod Security — *automatisé par `longhorn-up.sh`*

```bash
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite
```

> ℹ️ Un cluster kubeadm n'applique **aucun** niveau PodSecurity par défaut : ces étiquettes ne
> changent rien aujourd'hui. On les garde parce qu'elles **documentent l'intention** et gardent
> le namespace fonctionnel si le cluster est durci plus tard
> (`--admission-control-config-file` sur l'apiserver).

### 2. Chart Helm + StorageClass socle — *automatisé par `longhorn-up.sh`*

```bash
helm repo add longhorn https://charts.longhorn.io && helm repo update
# --version : épingle ; vérifier la dernière sur charts.longhorn.io
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.12.0 \
  -f longhorn/values.yaml
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer
kubectl apply -f longhorn/longhorn-r1-storageclass.yaml
```

## 🧬 Talos vs kubeadm

**Le prérequis iSCSI n'est pas au même endroit selon la distribution** — c'est LA différence
structurante de ce composant (`LONGHORN_PREP_REQUISE` dans les profils).

| | Talos | kubeadm |
|---|---|---|
| iSCSI (`iscsiadm`) | **extension système** `iscsi-tools` + `util-linux-tools`, CUITE dans l'image d'installation (`longhorn/schematic.yaml` → image factory, `INSTALLER_IMAGE` dans `lab.env`). Un node sans elles est irrécupérable à chaud : les pods CSI partent en `CrashLoopBackOff` (`iscsiadm: not found`) | **paquet** : `apt-get install -y open-iscsi nfs-common` + `systemctl enable --now iscsid` + module `iscsi_tcp`, posés par `kubeadm/provision.sh` au provisioning |
| Propagation de montage | montage kubelet `rshared` sur `/var/lib/longhorn` à appliquer (`longhorn/patch-longhorn.yaml`, `talosctl patch mc`, à chaud, sans reboot) — le kubelet Talos tourne dans un conteneur | rien à faire : le kubelet tourne sur l'hôte, `/var/lib/longhorn` est un dossier ordinaire |
| Outils requis sur l'hôte | `kubectl`, `helm`, **`talosctl`** | `kubectl`, `helm` |
| Étapes du script | **5** (extensions → patch → namespace → chart → HTTPRoute) | **3** (namespace → chart → HTTPRoute) |
| Où vivent les données | partition `EPHEMERAL` (perdue à un `reset` sans `--preserve`), disque ~20 Go partagé avec l'OS | disque de la box, partagé avec l'OS et les images |
| Label PodSecurity `privileged` | **indispensable** (défaut cluster `baseline`) | documentation d'intention |

## 🎓 Pas à pas guidé (formation)

> Les commandes ci-dessous sont **exactement** ce que fait le script tout-en-un, dans
> l'ordre. Prépare d'abord l'environnement (une fois par session) :
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig        # ou ../Vagrant-KubeADM/kubeconfig
> export LAB_DOMAIN=talos.lab.example.io               # ou ton domaine (cf. lab.env du lab)
> ```

### 1. (Talos uniquement) Vérifier les extensions iSCSI — **avant tout le reste**

Une extension est cuite dans l'installeur : si elle manque, aucun `kubectl` ne rattrapera le
coup, il faut réinstaller ou upgrader le node.

```bash
export TALOSCONFIG=../Vagrant-Talos/_out/talosconfig
for ip in 192.168.56.101 192.168.56.102 192.168.56.103; do
  echo "== $ip"; talosctl -n "$ip" get extensions | grep -E 'iscsi-tools|util-linux-tools'
done
# Manquantes ? générer l'image factory depuis longhorn/schematic.yaml, puis :
#   talosctl -n <ip> upgrade --image <image-factory> --preserve
```

### 2. (Talos uniquement) Appliquer le montage kubelet `rshared`

```bash
talosctl -n 192.168.56.101 get mc -o yaml | grep -q /var/lib/longhorn \
  || talosctl -n 192.168.56.101 patch mc --patch @longhorn/patch-longhorn.yaml
# … à répéter sur chaque worker. Appliqué à chaud, sans reboot.
```

> Sur **kubeadm**, les étapes 1 et 2 n'existent pas : `open-iscsi` est déjà installé et actif
> sur chaque node. Vérification facultative :
> `vagrant ssh k8s-w1 -c 'systemctl is-active iscsid; lsmod | grep iscsi_tcp'`

### 3. Namespace + PodSecurity `privileged`

```bash
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite
```

### 4. Compter les nodes de stockage (et NE PAS dépasser)

`defaultReplicaCount` supérieur au nombre de nodes planifiables laisse **tous** les volumes en
`Degraded` à vie.

```bash
REPLICAS=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers | wc -l | tr -d ' ')
[ "$REPLICAS" -eq 0 ] && REPLICAS=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
[ "$REPLICAS" -gt 3 ] && REPLICAS=3
echo "réplicas bloc : $REPLICAS"
```

### 5. Le chart + la StorageClass à 1 réplica

```bash
helm repo add longhorn https://charts.longhorn.io && helm repo update longhorn
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.12.0 \
  --values longhorn/values.yaml \
  --set "defaultSettings.defaultReplicaCount=${REPLICAS}" \
  --set "persistence.defaultClassReplicaCount=${REPLICAS}" \
  --wait --timeout 10m
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=300s
kubectl apply -f longhorn/longhorn-r1-storageclass.yaml
```

### 6. Exposer l'UI en HTTPS

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" longhorn/httproute.yaml | kubectl apply -f -
```

### 7. Vérifier

```bash
kubectl get sc                                     # longhorn (défaut) + longhorn-r1
kubectl -n longhorn-system get nodes.longhorn.io   # tous « Ready », schedulable
kubectl -n longhorn-system get pods | grep -v Running   # doit ne rien lister d'anormal
curl --resolve "longhorn.${LAB_DOMAIN}:443:192.168.56.200" "https://longhorn.${LAB_DOMAIN}/" -kSI | head -1
```

> ⚠️ L'UI Longhorn n'a **aucune authentification** et permet de supprimer des volumes : ne
> l'expose qu'en réseau de confiance.

## 🔧 Sous le capot

### Pourquoi `longhorn-r1` (1 réplica)

Le `Vagrantfile` n'attache **aucun disque supplémentaire** : Longhorn partage le disque unique
de la box avec l'OS, les images conteneurs et etcd. Empiler des volumes 3-réplicas y déclenche
des `ReplicaSchedulingFailure` (et des évictions `DiskPressure` avant ça). `longhorn-r1` divise
la conso par ~3 pour les cas où la réplication bloc est superflue : donnée reconstructible
(Prometheus, Loki) ou déjà répliquée par l'appli (CloudNativePG, 3 instances). Définie **une
seule fois** ici, consommée ailleurs.

> ℹ️ Sur une base **critique**, rester sur `longhorn` (3 réplicas) ou déléguer explicitement
> la résilience à l'application.

### Disque dédié (setup « propre », optionnel)

Longhorn 1.10+ recommande un disque dédié. Ici, par défaut, on reste sur `/var/lib/longhorn`
(disque unique de la box). Pour faire propre :

1. **VirtualBox** : attacher un `.vdi` supplémentaire par worker (contrôleur SATA, port
   suivant) — nécessite un ajout dans le `Vagrantfile` (bloc
   `vb.customize ["createhd", …]` / `["storageattach", …]`).
2. **Debian** : partitionner, formater et monter de façon persistante, puis pointer
   `defaultDataPath` dessus :
   ```bash
   sudo mkfs.ext4 -L longhorn /dev/sdb
   echo 'LABEL=longhorn /mnt/longhorn ext4 defaults 0 2' | sudo tee -a /etc/fstab
   sudo mkdir -p /mnt/longhorn && sudo mount -a
   ```
   ```bash
   helm upgrade longhorn longhorn/longhorn -n longhorn-system \
     --reuse-values --set defaultSettings.defaultDataPath=/mnt/longhorn
   ```
   Aucun patch de propagation de montage à faire — c'était une contrainte Talos.

## ✅ Vérifier

```bash
vagrant ssh k8s-w1 -c 'systemctl is-active iscsid'   # active
vagrant ssh k8s-w1 -c 'lsmod | grep iscsi_tcp'       # module chargé
kubectl -n longhorn-system get pods              # instance-manager, manager, csi-* Running
kubectl get storageclass                         # longhorn (default) + longhorn-r1
kubectl -n longhorn-system get nodes.longhorn.io # chaque node "Schedulable", disque Ready

# Test rapide : un PVC doit se lier
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: test-longhorn }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources: { requests: { storage: 1Gi } }
EOF
kubectl get pvc test-longhorn                    # Bound
kubectl delete pvc test-longhorn
```

> ℹ️ Longhorn livre un **script de vérification d'environnement** qui audite chaque node (iSCSI,
> NFS, `multipathd`, modules noyau) — le moyen le plus rapide de confirmer les prérequis
> Debian :
> `curl -sSfL https://raw.githubusercontent.com/longhorn/longhorn/v1.12.0/scripts/environment_check.sh | bash`

## 🌐 Accès

`longhorn-up.sh` a déjà appliqué l'`HTTPRoute` (son étape `[3/3]`). Pour la réappliquer seule :

```bash
kubectl apply -f longhorn/httproute.yaml
```

> 🌐 **Domaine** : le manifeste porte le domaine neutre `lab.example.io` (dépôt public).
> `longhorn-up.sh` y substitue `LAB_DOMAIN` à la volée ; appliqué à la main comme ci-dessus, le
> domaine neutre reste. Substitue-le toi-même :
>
> ```bash
> sed 's/lab\.example\.io/kubeadm.lab.mon-domaine.tld/g' \
>   longhorn/httproute.yaml | kubectl apply -f -
> ```
>
> (cf. [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui)).

| Interface | URL / commande | Auth |
|---|---|---|
| UI Longhorn (HTTPS via `main-gateway`) | `https://longhorn.lab.example.io` | **aucune** |
| Sans exposition | `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80` | — |

Cert wildcard `*.lab.example.io` déjà porté par l'écouteur `https` : rien à émettre ici,
quel que soit le mode TLS du lab (auto-signé par défaut, ou cert-manager — le Secret porte le
même nom dans les deux cas, cf. [`../self-signed/LISEZ-MOI.md`](../self-signed/LISEZ-MOI.md)).

> ⚠️ **L'UI Longhorn n'a aucune authentification.** Exposée ainsi, elle est accessible à
> quiconque atteint le VIP (via Tailscale) — et elle permet de supprimer des volumes. Pour la
> protéger : `SecurityPolicy` Envoy Gateway (Basic Auth / OIDC) ciblant cette `HTTPRoute`.

## ⚠️ Pièges

- **`defaultReplicaCount` > nombre de nodes de stockage** → volumes coincés en `Degraded`, à
  vie. `longhorn-up.sh` l'aligne sur les nodes qu'il compte ; en installant le chart à la main,
  le faire soi-même (à 1 worker, mettre `1`).
- **Deux StorageClass par défaut** si `../local-path-storage/` est aussi installé :
  `values.yaml` pose `persistence.defaultClass: true` (⇒ `longhorn`) et
  `local-path-storage.yaml` annote `local-path` avec `is-default-class: "true"`. Un PVC sans
  `storageClassName` devient alors **non déterministe**. Choisir un seul défaut :
  ```bash
  kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class-
  # ou, dans l'autre sens : helm upgrade ... --set persistence.defaultClass=false
  ```
- **`iscsid` arrêté** (ou un node monté hors de `kubeadm/provision.sh`) → pods CSI en
  `CrashLoopBackOff`, erreurs `iscsiadm: not found` / `Failed to execute iscsiadm`. Sur le node :
  `sudo apt-get install -y open-iscsi && sudo systemctl enable --now iscsid`.
- **`multipath-tools` (`multipathd`)** : Debian 13 ne l'installe **pas**, et c'est précisément
  pour ça que Longhorn fonctionne d'emblée ici. Si tu l'installes pour autre chose, `multipathd`
  s'approprie les devices bloc de Longhorn et les volumes ne s'attachent plus
  (`failed to get devicemapper`). Les blacklister dans `/etc/multipath.conf`
  (`devices { device { vendor "IET" ... } }`), ou ne pas installer le paquet.
- **Disque partagé** : Longhorn sur `/var/lib/longhorn` consomme le même système de fichiers que
  l'OS, les images conteneurs et etcd → surveiller `DiskPressure`, préférer `longhorn-r1`, ou
  passer au disque dédié (ci-dessus).
- **`vagrant destroy` d'un worker détruit ses réplicas.** Sur `longhorn` (3 réplicas) Longhorn
  reconstruit ailleurs ; sur `longhorn-r1` (1 réplica) **la donnée est perdue**. Drainer et
  laisser Longhorn reconstruire avant de retirer un node qui stocke quelque chose d'important.
- **Désinstallation** : passer le setting Longhorn `deleting-confirmation-flag` à `true`
  avant `helm uninstall`, sinon la suppression reste bloquée.

## 📚 Références

- [Longhorn — Prérequis d'installation (1.12)](https://longhorn.io/docs/1.12.0/deploy/install/#installation-requirements)
- [Longhorn — Quick Installation](https://longhorn.io/docs/1.12.0/deploy/install/)
- `kubeadm/provision.sh` — là où `open-iscsi`, `nfs-common` et le module `iscsi_tcp` sont posés.
