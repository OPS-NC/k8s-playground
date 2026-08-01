<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🪪 `dex/` — Dex devant Keycloak : `kubectl` sans le moindre certificat

> **Le `kubeconfig` du lab cesse d'être un identifiant.** Dex se publie sous
> `dex.lab.example.io` comme l'unique émetteur OIDC auquel le serveur d'API fait confiance, et
> va chercher l'identité réelle dans le realm Keycloak `lab`. `kubectl` se connecte alors par un
> navigateur (`kubectl oidc-login`), et tes droits viennent d'un **groupe Keycloak**, plus d'un
> certificat client recopié de machine en machine.

> 🌐 **`lab.example.io` est le domaine NEUTRE du dépôt (public)** : `dex-up.sh` le remplace par
> `LAB_DOMAIN` (`lab.env`) dans les values Dex, le client Keycloak et l'`HTTPRoute`. Cf.
> [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui).

## 🎯 À quoi ça sert

- Montrer le **seul mécanisme d'authentification de Kubernetes qui passe à l'échelle** : OIDC.
  Aucune base d'utilisateurs dans le cluster, aucun certificat à révoquer, aucun `kubeconfig` à
  distribuer.
- Démontrer que l'autorisation suit un **groupe** : mets un utilisateur dans `k8s-admins` côté
  Keycloak et `cluster-admin` suit — sors-l'en et c'est fini au jeton suivant.
- Expliquer, sur un cluster vivant, pourquoi le serveur d'API est le maillon le plus **dur** à
  modifier de cette chaîne, et à quel point ça se joue différemment sur Talos et sur kubeadm.

> ℹ️ **Addon à part**, et il exige [`../keycloak/`](../keycloak/LISEZ-MOI.md) d'abord : il
> s'appuie sur le realm `lab`, son scope `groups` et son utilisateur `demo`.

### Pourquoi Dex alors que Keycloak parle déjà OIDC

Parce que l'apiserver ne connaît qu'**un seul** émetteur, figé dans sa ligne de commande, et que
changer cette valeur redémarre le control plane. Dex est le point d'indirection : l'apiserver ne
connaît jamais que `https://dex.lab.example.io`, et tout ce qui bouge — ajouter un second
annuaire, changer de realm, faire tourner un secret de client — se fait dans la configuration de
Dex, jamais sur le control plane. C'est exactement ce que fait un cluster managé derrière son SSO.

### Le montage en une phrase

**Trois URL doivent coïncider au caractère près** : `config.issuer` de `values.yaml`, le
`hostnames:` de l'`HTTPRoute`, et `--oidc-issuer-url` de l'apiserver. Cette chaîne est signée
dans chaque jeton ; un `/` final suffit à les faire tous rejeter avec
`oidc: id token issued by a different provider`.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| [`../keycloak/`](../keycloak/LISEZ-MOI.md) installé, realm `lab` | l'annuaire amont, ses groupes et son scope `groups` | `kubectl -n keycloak get keycloak,keycloakrealmimport` |
| `main-gateway` avec l'écouteur **`https:443`** ([`../envoy-gateway/`](../envoy-gateway/LISEZ-MOI.md)) | publie l'émetteur en HTTPS | `kubectl get gateway -n envoy-gateway-system` |
| Cert wildcard `wildcard-lab-example-io-tls` **`READY=True`** | l'apiserver **refuse** un émetteur qu'il ne peut pas vérifier | `kubectl -n envoy-gateway-system get certificate` |
| DNS `dex.lab.example.io → 192.168.56.200` en **DNS-only** | résolu par l'apiserver **et** par ton navigateur | `kubectl get gateway -n envoy-gateway-system` |
| **kubelogin** (`kubectl oidc-login`) sur l'hôte | pilote le flux navigateur et met le jeton en cache | `kubectl oidc-login --version` |
| Accès aux control planes | câbler l'apiserver ne se fait **pas** depuis l'API | `talosctl version` / `vagrant status` |
| Rien côté nodes pour Dex lui-même | ni `hostPath`, ni privilège | `kubectl -n dex get pods` |

Installer kubelogin :

```bash
kubectl krew install oidc-login          # ou : brew install int128/kubelogin/kubelogin
kubectl oidc-login --version             # version de référence de ce lab : v1.36.3
```

## ⚡ Installation

> 🎓 **Deux chemins, même résultat** : le script tout-en-un ci-dessous, ou la section
> **« Pas à pas guidé »** plus bas — les mêmes commandes, une par une, pour une formation.

Via le point d'entrée du dépôt :
```bash
./install.sh <distro> keycloak dex      # <distro> = talos | kubeadm
```

```bash
./dex/dex-up.sh <distro>
```

Chart `dex/dex` **`0.24.1`** (app **v2.44.0**), épinglé dans le script via `DEX_VERSION`
(surchargeable). Idempotent — avec une exception assumée : les secrets de client ne sont générés
que s'ils manquent, parce que les régénérer invaliderait en silence le client que l'opérateur
Keycloak a déjà créé.

> ⚠️ **Le script ne touche pas au serveur d'API.** Le brancher sur Dex redémarre le control
> plane, et un émetteur injoignable l'empêche carrément de redémarrer. Un addon n'a pas à faire
> ça en douce. Le script affiche à la place les commandes exactes pour ta distribution — cf.
> [Câbler le serveur d'API](#-câbler-le-serveur-dapi).

<details>
<summary>Équivalent manuel</summary>

```bash
kubectl create namespace dex
S=$(openssl rand -hex 32)
kubectl -n keycloak create secret generic dex-keycloak-client --from-literal=client-secret="$S"
kubectl -n dex      create secret generic dex-keycloak-client --from-literal=client-secret="$S"
kubectl -n dex create secret generic dex-kubernetes-client \
  --from-literal=client-secret="$(openssl rand -hex 32)"
kubectl apply -f dex/01-keycloak-client.yaml           # après substitution du domaine
helm repo add dex https://charts.dexidp.io && helm repo update dex
helm upgrade --install dex dex/dex -n dex --version 0.24.1 --values dex/values.yaml
kubectl apply -f dex/httproute.yaml
kubectl apply -f dex/rbac.yaml
```
</details>

## 🧬 Talos vs kubeadm

**C'est le composant où les deux labs divergent le plus** — et la divergence n'est pas dans Dex,
identique des deux côtés. Elle est dans la **seule chose que ce dépôt ne possède pas** : le
serveur d'API Kubernetes.

| | Talos | Debian 13 + kubeadm |
|---|---|---|
| Ce qu'est l'apiserver | un pod statique dont Talos **génère** le manifeste depuis la configuration machine | un pod statique dont le manifeste est un fichier sur le disque, généré par `kubeadm` |
| Comment changer ses flags | `talosctl patch mc` — **la configuration est une API** | éditer la ConfigMap `kubeadm-config`, puis relancer `kubeadm init phase` **sur chaque node** |
| Accès nécessaire | rien de plus que `talosctl` : il n'y a pas de SSH sur Talos | une session sur chaque control plane (`vagrant ssh k8s-cpN`) |
| Forme de `extraArgs` | une **map** (`clé: valeur`), Talos `v1alpha1` | une **liste** de `{name, value}`, kubeadm `v1beta4` (Kubernetes ≥ 1.31) |
| Redémarrage | Talos réécrit le manifeste et redémarre l'apiserver lui-même | `kubeadm` réécrit le manifeste, le kubelet le voit et redémarre le pod |
| Où va l'AC OIDC (`SELF_SIGNED=true`) | une entrée `machine.files` **plus** un montage `cluster.apiServer.extraVolumes` : `/` est en lecture seule et le pod statique ne voit que ce qu'on lui monte | un simple `cp` dans `/etc/kubernetes/pki/`, **déjà monté** dans le pod — rien d'autre à déclarer |
| Variables de profil | `APISERVER_OIDC_PATCH`, `APISERVER_OIDC_MECHANISM`, `apiserver_oidc_commands()` | les mêmes trois, d'autres valeurs |
| Patch fourni ici | [`apiserver-oidc.talos.yaml`](apiserver-oidc.talos.yaml) | [`apiserver-oidc.kubeadm.yaml`](apiserver-oidc.kubeadm.yaml) |

Tout le reste — le chart Dex, le CR du client Keycloak, l'`HTTPRoute`, les liaisons RBAC — est
identique à l'octet près sur les deux labs.

## 🎓 Pas à pas guidé

> Les commandes ci-dessous sont **exactement** ce que fait le script tout-en-un, dans l'ordre.
> Prépare d'abord ton shell (une fois par session) :
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig        # ou ../Vagrant-KubeADM/kubeconfig
> export LAB_DOMAIN=talos.lab.example.io               # ou le tien (cf. lab.env du lab)
> ```

### 1. Le namespace et les deux secrets de client

Le secret du client `dex` doit exister dans **deux** namespaces : Keycloak le lit dans `keycloak`
(le CR `KeycloakOIDCClient` y vit), Dex le lit dans `dex`. Un Secret ne franchit pas les
namespaces.

```bash
kubectl create namespace dex
S=$(openssl rand -hex 32)
kubectl -n keycloak create secret generic dex-keycloak-client --from-literal=client-secret="$S"
kubectl -n dex      create secret generic dex-keycloak-client --from-literal=client-secret="$S"
kubectl -n dex create secret generic dex-kubernetes-client \
  --from-literal=client-secret="$(openssl rand -hex 32)"
```

### 2. Le client Keycloak, déclaré

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" dex/01-keycloak-client.yaml | kubectl apply -f -
kubectl -n keycloak get keycloakoidcclient dex -o jsonpath='{.status.conditions}' | jq
```

Il n'y a pas de champ `clientId` dans cette CRD : `metadata.name` **est** l'identifiant du
client, et il doit correspondre au `clientID: dex` du connecteur Dex.

### 3. Dex lui-même

```bash
helm repo add dex https://charts.dexidp.io && helm repo update dex
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" dex/values.yaml > /tmp/dex-values.yaml
helm upgrade --install dex dex/dex -n dex --version 0.24.1 --values /tmp/dex-values.yaml
kubectl -n dex rollout status deploy/dex --timeout=300s
kubectl -n dex logs deploy/dex | head -20        # « config using connector: keycloak »
```

### 4. La route et les liaisons RBAC

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" dex/httproute.yaml | kubectl apply -f -
kubectl apply -f dex/rbac.yaml
curl -sk "https://dex.${LAB_DOMAIN}/.well-known/openid-configuration" | jq '.issuer, .jwks_uri'
```

L'`issuer` doit valoir exactement `https://dex.<LAB_DOMAIN>` — sans `/` final.

### 5. Câbler le serveur d'API

Voir la section dédiée ci-dessous : c'est l'étape que le script refuse de faire à ta place.

### 6. Le contexte `kubectl`

```bash
CTX=$(kubectl config current-context)
CLUSTER=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CTX\")].context.cluster}")
kubectl config set-credentials oidc \
  --exec-api-version=client.authentication.k8s.io/v1beta1 \
  --exec-command=kubectl \
  --exec-arg=oidc-login --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://dex.${LAB_DOMAIN} \
  --exec-arg=--oidc-client-id=kubernetes \
  --exec-arg=--oidc-client-secret=$(kubectl -n dex get secret dex-kubernetes-client \
      -o jsonpath='{.data.client-secret}' | base64 -d) \
  --exec-arg=--oidc-extra-scope=groups --exec-arg=--oidc-extra-scope=email
kubectl config set-context oidc --cluster="$CLUSTER" --user=oidc
kubectl --context=oidc get nodes
```

Cette dernière commande ouvre un navigateur : Dex propose le connecteur `Keycloak`, Keycloak
demande `demo` et son mot de passe, et `kubectl` revient avec un jeton. Rien n'a été recopié,
rien n'a été signé à la main.

> 💡 Avec `SELF_SIGNED=true`, ajoute `--exec-arg=--certificate-authority=<chemin de l'AC du lab>`
> pour que kubelogin fasse confiance à `dex.<LAB_DOMAIN>` lui aussi.
> `--insecure-skip-tls-verify` marche, et enseigne le mauvais réflexe.

## 🔐 Câbler le serveur d'API

C'est la seule étape du dépôt qui **modifie le control plane**, donc la seule qu'on te laisse en
main. À lire avant de lancer quoi que ce soit :

- Elle **ajoute** un authentifieur, elle n'en retire aucun. Le `kubeconfig` du lab et les
  certificats client des composants continuent de marcher — c'est ce qui rend l'opération
  réversible.
- Un `--oidc-issuer-url` faux (injoignable, ou avec un certificat non trusté) **empêche
  l'apiserver de démarrer**. Un control plane à la fois, en vérifiant
  `kubectl get --raw=/readyz` entre chaque ; tant qu'un control plane est sain, le cluster reste
  administrable.
- Pour revenir en arrière : retirer les flags de la même façon qu'on les a posés.

### Talos

```bash
for ip in $(kubectl get nodes -l node-role.kubernetes.io/control-plane \
              -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}'); do
  talosctl -n "$ip" patch mc --patch @dex/apiserver-oidc.talos.yaml
  kubectl get --raw=/readyz && echo
done
```

<details>
<summary><code>SELF_SIGNED=true</code> : donner aussi l'AC du lab à l'apiserver</summary>

`/` est en lecture seule sur Talos et le pod statique ne voit que ce qu'on lui monte. Deux
ajouts, donc : le fichier, et le volume qui l'expose.

```bash
CA=$(sed 's/^/          /' ../Vagrant-Talos/_out/self-signed/ca.crt)   # indenter le PEM
cat > /tmp/oidc-ca.talos.yaml <<EOF
machine:
  files:
    - path: /var/lib/oidc/ca.crt
      permissions: 0o644
      op: create
      content: |
$CA
cluster:
  apiServer:
    extraArgs:
      oidc-ca-file: /etc/kubernetes/oidc/ca.crt
    extraVolumes:
      - hostPath: /var/lib/oidc
        mountPath: /etc/kubernetes/oidc
        readonly: true
EOF
talosctl -n <IP du control plane> patch mc --patch @/tmp/oidc-ca.talos.yaml
```

`op: create` refuse d'écraser : au second passage, utiliser `overwrite`.
</details>

### kubeadm

Le manifeste de l'apiserver est un fichier sur chaque control plane, régénéré par `kubeadm`
depuis la ConfigMap `kubeadm-config`. Éditer le manifeste directement marche — jusqu'au
prochain `kubeadm upgrade` qui l'écrase en silence. La ConfigMap est donc la source de vérité :

```bash
# 1. fusionner le bloc apiServer de dex/apiserver-oidc.kubeadm.yaml dans ClusterConfiguration
kubectl -n kube-system edit configmap kubeadm-config

# 2. sur CHAQUE control plane, régénérer le manifeste du pod statique depuis cette ConfigMap
vagrant ssh k8s-cp1 -c '
  kubectl -n kube-system get cm kubeadm-config -o jsonpath="{.data.ClusterConfiguration}" \
    | sudo tee /tmp/kubeadm.yaml >/dev/null
  sudo kubeadm init phase control-plane apiserver --config /tmp/kubeadm.yaml'
kubectl get --raw=/readyz && echo
```

<details>
<summary><code>SELF_SIGNED=true</code> : donner aussi l'AC du lab à l'apiserver</summary>

`/etc/kubernetes/pki` est **déjà** monté dans le pod statique : le fichier suffit.

```bash
vagrant ssh k8s-cp1 -c 'sudo tee /etc/kubernetes/pki/oidc-ca.crt >/dev/null' \
  < ../Vagrant-KubeADM/_out/self-signed/ca.crt
# puis ajouter dans la ConfigMap, à côté des autres flags :
#   - name: oidc-ca-file
#     value: /etc/kubernetes/pki/oidc-ca.crt
```
</details>

> 💡 Le chemin le plus simple est de n'avoir aucun problème d'AC : avec `SELF_SIGNED=false`, le
> wildcard est émis par Let's Encrypt, publiquement trusté, et ni l'apiserver ni kubelogin n'ont
> besoin de quoi que ce soit. Cf. [`../cert-manager/LISEZ-MOI.md`](../cert-manager/LISEZ-MOI.md).

## 🔧 Ce que fait le script

1. crée le namespace `dex` et les deux secrets de client — en ne les générant **que s'ils
   manquent** ;
2. applique le CR `KeycloakOIDCClient` avec le domaine substitué, et attend `Ready` ;
3. installe le chart Dex avec les values rendues, et attend le déroulement ;
4. applique l'`HTTPRoute` et les deux `ClusterRoleBinding` ;
5. affiche les commandes de câblage de l'apiserver pour la distribution détectée, puis le
   contexte `kubectl` — il n'exécute ni l'un ni l'autre.

### Fichiers

| Fichier | Rôle |
|---|---|
| `01-keycloak-client.yaml` | `KeycloakOIDCClient` : le client `dex` du realm `lab`, flux `STANDARD` seul, une URL de redirection exacte |
| `values.yaml` | Dex : issuer public, stockage Kubernetes, connecteur `oidc` vers le realm, client statique `kubernetes` ; les deux secrets viennent de variables d'environnement |
| `httproute.yaml` | `HTTPRoute` HTTPS `dex.lab.example.io` → `dex:5556`, `sectionName: https` |
| `rbac.yaml` | `oidc:k8s-admins` → `cluster-admin`, `oidc:k8s-viewers` → `view` |
| `apiserver-oidc.talos.yaml` | patch de configuration machine Talos (`talosctl patch mc`) |
| `apiserver-oidc.kubeadm.yaml` | fragment de `ClusterConfiguration` à fusionner dans `kubeadm-config` |
| `dex-up.sh` | l'installation tout-en-un (idempotente), hors modification du control plane |

## ✅ Vérifier

```bash
kubectl -n dex get pods,httproute                       # dex Running, route Accepted
kubectl -n keycloak get keycloakoidcclient dex          # Ready=True
curl -sk https://dex.lab.example.io/.well-known/openid-configuration | jq .issuer

# l'apiserver voit réellement les flags (Talos comme kubeadm) :
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep oidc

# toute la chaîne, en une commande :
kubectl --context=oidc auth whoami                      # oidc:demo@lab.example.io, oidc:k8s-admins
kubectl --context=oidc auth can-i '*' '*' --all-namespaces   # yes
```

## 🧪 Scénario — l'autorisation vit dans Keycloak, pas dans le cluster

```bash
# 1. demo est dans k8s-admins : tous les droits
kubectl --context=oidc auth can-i delete nodes                  # yes

# 2. Dans la console Keycloak (https://keycloak.<LAB_DOMAIN>/admin/), realm `lab` :
#    Users -> demo -> Groups -> quitter k8s-admins, rejoindre k8s-viewers

# 3. Forcer un jeton neuf — l'ancien est en cache et reste valide jusqu'à expiration
rm -rf ~/.kube/cache/oidc-login
kubectl --context=oidc auth whoami                              # oidc:k8s-viewers
kubectl --context=oidc auth can-i delete nodes                  # no
kubectl --context=oidc get pods -A                              # marche encore : `view`
```

Pas une commande `kubectl` n'a été nécessaire pour changer ces droits, et rien n'a été révoqué
dans le cluster. C'est tout l'intérêt — et le cache est tout le bémol : **un jeton déjà émis
garde ses groupes jusqu'à son expiration.** Le déprovisionnement OIDC n'est jamais instantané.

## 🚑 Dépannage

- **`oidc: id token issued by a different provider`** → les trois URL ne coïncident pas.
  Comparer `config.issuer`
  (`kubectl -n dex get secret dex -o jsonpath='{.data.config\.yaml}' | base64 -d`), le hostname
  de l'`HTTPRoute` et `--oidc-issuer-url` de l'apiserver. Un `/` final suffit.
- **L'apiserver ne redémarre plus après le patch** → presque toujours l'émetteur : injoignable,
  ou certificat non trusté. Sur Talos, `talosctl -n <ip> logs kubelet` ; sur kubeadm,
  `sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1)`. Défaire les flags.
- **La connexion marche mais tout est `Forbidden`** → les groupes manquent dans le jeton.
  Vérifier dans l'ordre : le scope `groups` demandé par Dex (`values.yaml`),
  `insecureEnableGroups: true` sur le connecteur, le client scope `groups` du realm
  ([`../keycloak/`](../keycloak/LISEZ-MOI.md)), et le préfixe `oidc:` de `rbac.yaml`.
- **`kubectl auth whoami` affiche le bon utilisateur mais aucun groupe** → mêmes causes, et
  vérifier que le client Keycloak a bien reçu le scope `groups` : le realm l'attribue aux
  **nouveaux** clients (`defaultDefaultClientScopes`) ; un client créé avant ce réglage ne l'a pas.
- **Le navigateur ne revient jamais / `redirect_uri_mismatch`** → kubelogin écoute sur `:8000`.
  L'URI doit figurer dans `staticClients[].redirectURIs` (Dex) ; côté Keycloak, le client ne
  liste que `https://dex.<LAB_DOMAIN>/callback`, qui est le callback de Dex, pas celui de kubectl.
- **`x509: certificate signed by unknown authority`** → `SELF_SIGNED=true` et quelqu'un dans la
  chaîne n'a pas l'AC du lab : l'apiserver (`oidc-ca-file`), kubelogin
  (`--certificate-authority`), ou Dex quand il appelle Keycloak.
- **Le pod Dex redémarre en boucle** → `kubectl -n dex logs deploy/dex`. Un Secret manquant, ou
  un `$KEYCLOAK_CLIENT_SECRET` non substitué, se voit comme un connecteur qui refuse de démarrer.

## ⚠️ Pièges

- **`cluster-admin` est donné à un groupe : quiconque Keycloak y met devient admin du cluster.**
  L'IdP fait désormais partie du périmètre de confiance du cluster ; qui administre le realm
  administre Kubernetes.
- **La révocation n'est pas immédiate.** Un jeton déjà délivré reste valide jusqu'à son
  expiration, quoi qu'on change dans Keycloak. Kubernetes ne vérifie rien côté IdP à chaque
  requête.
- **Le préfixe `oidc:` est porteur.** Sans lui, un annuaire qui déclare un groupe
  `system:masters` prend le cluster. Si tu le changes, change aussi `rbac.yaml`.
- **Ne jamais retirer les authentifieurs par certificat.** OIDC s'y ajoute ; un cluster dont la
  seule porte est un IdP est un cluster où l'on ne rentre plus quand l'IdP est tombé — et ici,
  l'IdP tourne *dans* ce cluster.
- **`insecureEnableGroups` est mal nommé mais obligatoire** : sans lui, le connecteur OIDC
  générique de Dex jette les groupes de l'amont, sans rien dire.
- **Les secrets de client sont générés une fois.** Relancer le script ne les fait pas tourner,
  volontairement : régénérer celui de `dex` d'un seul côté casserait le client sans la moindre
  erreur visible. Les faire tourner délibérément — les deux namespaces, puis redémarrer Dex.
- **Éditer `/etc/kubernetes/manifests/kube-apiserver.yaml` à la main sur kubeadm** tient jusqu'au
  prochain `kubeadm upgrade`, qui le régénère depuis `kubeadm-config`.

## 📚 Références

- [Kubernetes — jetons OpenID Connect](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#openid-connect-tokens)
- [Dex — connecteur OIDC](https://dexidp.io/docs/connectors/oidc/)
- [Dex — stockage dans Kubernetes](https://dexidp.io/docs/storage/#kubernetes-custom-resource-definitions-crds)
- [kubelogin (`kubectl oidc-login`)](https://github.com/int128/kubelogin)
- [Talos — `cluster.apiServer.extraArgs` / `extraVolumes`](https://docs.siderolabs.com/talos/v1.11/reference/configuration/v1alpha1/config)
- [kubeadm — `ClusterConfiguration` v1beta4](https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/)
- [`../keycloak/LISEZ-MOI.md`](../keycloak/LISEZ-MOI.md) — le realm, les groupes et le scope `groups`
- [`../envoy-gateway/LISEZ-MOI.md`](../envoy-gateway/LISEZ-MOI.md) — la Gateway qui porte cette route
