<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🛂 `keycloak/` — Keycloak par son **opérateur**, exposé via la Gateway API

> **Un fournisseur d'identité que le cluster sait reconstruire depuis un fichier.** Keycloak est
> déployé par son **opérateur** : un CR `Keycloak` de trente lignes remplace le StatefulSet, le
> Service et toute la configuration serveur, et un CR `KeycloakRealmImport` rend le realm `lab`
> **reproductible**. La console d'admin et les endpoints OIDC sont publiés sous
> `keycloak.lab.example.io` derrière le même `main-gateway` que le reste du lab, avec le
> **wildcard `*.lab.example.io`** déjà émis — rien de neuf côté certificat.

> 🌐 **`lab.example.io` est le domaine NEUTRE du dépôt (public)** : `keycloak-up.sh` le remplace
> par `LAB_DOMAIN` (`lab.env`) dans le CR `Keycloak`, le realm et l'`HTTPRoute`. Cf.
> [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui).

## 🎯 À quoi ça sert

- Donner au lab un **vrai fournisseur d'identité** : realms, utilisateurs, groupes, clients OIDC
  et SAML.
- Montrer un **déploiement piloté par CRD** : on déclare *ce qu'on veut* (`Keycloak`,
  `KeycloakRealmImport`), l'opérateur en dérive le *comment* et le reconcilie en continu.
- Servir d'**IdP amont** à tout ce qui s'authentifie ensuite — à commencer par `kubectl`
  lui-même, via l'addon Dex.

> ℹ️ **Addon à part** : Keycloak n'est **pas** installé par `../platform-up.sh` (qui ne pose que
> le CNI + Envoy Gateway + metrics-server + le wildcard TLS). Il s'installe à la demande, comme
> `../longhorn/`, `../vault-cluster/`, `../argocd/`…

### Le montage en une phrase

**Envoy termine le TLS, Keycloak parle en clair — et on le lui dit.** `http.httpEnabled: true`
fait écouter le pod en clair sur `8080` ; `proxy.headers: xforwarded` fait confiance aux en-têtes
`X-Forwarded-*` posés par Envoy ; `hostname.hostname` fige l'URL **publique**. Sans le deuxième,
Keycloak fabrique ses redirections depuis son nom interne — le navigateur boucle et OAuth casse.
Sans le troisième, l'`issuer` annoncé dans le document de découverte ne correspond pas à l'URL
réellement appelée, et tous les jetons sont rejetés.

### Pourquoi l'opérateur et pas un chart

Un chart Helm vous donne un StatefulSet et vous laisse avec : la génération du keystore, les
options de proxy, la migration de schéma à chaque montée de version, le cache Infinispan.
L'opérateur, lui, prend un objet `Keycloak` et en dérive tout. Surtout, il apporte ce qui compte
dans un lab : un **realm déclaré**, donc versionnable, donc reproductible — et, pour les
composants d'aval, un client OIDC déclaré par un CR au lieu d'un script `kcadm.sh`.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| `main-gateway` avec l'écouteur **`https:443`** ([`../envoy-gateway/`](../envoy-gateway/LISEZ-MOI.md)) | porte la console et les endpoints OIDC en HTTPS | `kubectl get gateway -n envoy-gateway-system` |
| Cert wildcard `wildcard-lab-example-io-tls` **`READY=True`** ([`../cert-manager/`](../cert-manager/LISEZ-MOI.md) ou [`../self-signed/`](../self-signed/LISEZ-MOI.md)) | sinon TLS non trusté, et les clients OIDC refusent l'issuer | `kubectl -n envoy-gateway-system get certificate` |
| StorageClass **`longhorn-r1`** ([`../longhorn/`](../longhorn/LISEZ-MOI.md)) | le PVC de PostgreSQL | `kubectl get sc longhorn-r1` |
| Opérateur **CloudNativePG** ([`../cloudnative-pg/`](../cloudnative-pg/LISEZ-MOI.md)) | reconcilie le cluster `keycloak-db` | `kubectl get crd clusters.postgresql.cnpg.io` |
| DNS `keycloak.lab.example.io → 192.168.56.200` en **DNS-only** | hostname de l'`HTTPRoute` | `curl --resolve` sinon (cf. ✅) |
| `openssl` sur l'hôte | génère le mot de passe de l'utilisateur de démo | `openssl version` |
| Rien côté nodes | ni `hostPath`, ni `hostNetwork`, ni privilège | `kubectl -n keycloak get pods` |

## ⚡ Installation

Via le point d'entrée du dépôt :
```bash
./install.sh <distro> cnpg keycloak     # <distro> = talos | kubeadm
```

```bash
./keycloak/keycloak-up.sh <distro>
```

Keycloak **`26.7.0`** (opérateur **et** serveur : les manifestes de l'opérateur portent l'image
du serveur), épinglé dans le script via `KEYCLOAK_VERSION` (surchargeable). Idempotent
(`kubectl apply` partout ; le mot de passe de démo n'est généré que si son Secret manque).

<details>
<summary>Équivalent manuel</summary>

```bash
V=26.7.0
B=https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$V/kubernetes
kubectl create namespace keycloak
kubectl apply -f keycloak/01-postgres.yaml
kubectl -n keycloak wait --for=condition=Ready cluster/keycloak-db --timeout=300s
# --server-side est obligatoire : la CRD keycloaks dépasse les 262 144 octets que peut
# porter l'annotation last-applied-configuration écrite par un apply côté client.
for c in keycloaks keycloakrealmimports keycloakoidcclients keycloaksamlclients; do
  kubectl apply --server-side -f "$B/$c.k8s.keycloak.org-v1.yml"
done
kubectl apply -n keycloak -f "$B/kubernetes.yml"
kubectl -n keycloak rollout status deploy/keycloak-operator
kubectl apply -f keycloak/02-keycloak.yaml            # après substitution du domaine
kubectl -n keycloak create secret generic keycloak-demo-user \
  --from-literal=password="$(openssl rand -base64 18)"
kubectl apply -f keycloak/03-realm-lab.yaml
kubectl apply -f keycloak/httproute.yaml
```
</details>

## 🧬 Talos vs kubeadm

**Aucune spécificité de distribution pour ce composant.** Mêmes manifestes, mêmes CR, mêmes
versions sur les deux labs — et, fait rare dans ce dépôt, **pas même une étiquette de namespace
`privileged`** : les pods Keycloak et PostgreSQL n'utilisent ni `hostPath`, ni `hostNetwork`, ni
privilège, ils satisfont donc déjà le niveau PodSecurity `baseline` que Talos applique au niveau
cluster.

La distribution passée en argument ne sert ici qu'à deux choses : le **domaine par défaut**
(`talos.lab.example.io` / `kubeadm.lab.example.io`) et la **localisation du `lab.env` /
`kubeconfig`** du lab (`../Vagrant-Talos/` ou `../Vagrant-KubeADM/`).

> ℹ️ La seule chose qui diffère *vraiment* d'un lab à l'autre est la **confiance dans le
> certificat**, et ça ne mord qu'en aval. Avec `SELF_SIGNED=true` (le défaut du dépôt), l'issuer
> `https://keycloak.<LAB_DOMAIN>` est signé par l'AC locale du lab : le navigateur avertit, et
> tout client OIDC — apiserver Kubernetes compris — doit recevoir cette AC explicitement. Cf.
> [`../self-signed/LISEZ-MOI.md`](../self-signed/LISEZ-MOI.md).

## 🎓 Pas à pas guidé

> Les commandes ci-dessous sont **exactement** ce que fait le script tout-en-un, dans l'ordre.
> Prépare d'abord ton shell (une fois par session) :
> ```bash
> export KUBECONFIG=../Vagrant-Talos/kubeconfig        # ou ../Vagrant-KubeADM/kubeconfig
> export LAB_DOMAIN=talos.lab.example.io               # ou le tien (cf. lab.env du lab)
> ```

### 1. Le namespace et la base

Keycloak stocke **tout** en base — realms, clients, utilisateurs, sessions offline. Sans base, il
repart de zéro à chaque redémarrage de pod.

```bash
kubectl create namespace keycloak
kubectl apply -f keycloak/01-postgres.yaml
kubectl -n keycloak wait --for=condition=Ready cluster/keycloak-db --timeout=300s
kubectl -n keycloak get secret keycloak-db-app -o jsonpath='{.data.username}' | base64 -d; echo
```

Le Secret `keycloak-db-app` est produit par CloudNativePG, pas par nous : c'est tout l'intérêt de
passer par l'opérateur plutôt que d'écrire un Deployment `postgres:17` à la main.

### 2. L'opérateur Keycloak

```bash
V=26.7.0
B=https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$V/kubernetes
for c in keycloaks keycloakrealmimports keycloakoidcclients keycloaksamlclients; do
  kubectl apply --server-side -f "$B/$c.k8s.keycloak.org-v1.yml"
done
kubectl apply -n keycloak -f "$B/kubernetes.yml"
kubectl -n keycloak rollout status deploy/keycloak-operator --timeout=300s
kubectl api-resources --api-group=k8s.keycloak.org
```

Deux détails qui comptent : les CRD passent en **`--server-side`** (celle de `keycloaks` dépasse
le plafond de 262 144 octets de l'annotation d'un apply côté client), et l'opérateur **doit**
vivre dans le namespace `keycloak` (son `ClusterRoleBinding` y désigne son ServiceAccount en dur).

### 3. Le CR `Keycloak` — le déploiement entier

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" keycloak/02-keycloak.yaml | kubectl apply -f -
kubectl -n keycloak get statefulset,svc          # créés par l'opérateur, pas par toi
kubectl -n keycloak wait --for=condition=Ready keycloak/keycloak --timeout=600s
```

Le premier démarrage prend deux bonnes minutes : Keycloak crée son schéma. À suivre avec
`kubectl -n keycloak logs -f keycloak-0`.

### 4. Le realm `lab`, sans un seul mot de passe dans git

```bash
kubectl -n keycloak create secret generic keycloak-demo-user \
  --from-literal=password="$(openssl rand -base64 18)"
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" keycloak/03-realm-lab.yaml | kubectl apply -f -
kubectl -n keycloak wait --for=condition=Done keycloakrealmimport/lab --timeout=300s
kubectl -n keycloak get jobs                     # le Job d'import, exécuté une fois
```

`spec.placeholders` expose la clé du Secret comme variable d'environnement du Job d'import, et
Keycloak substitue `${DEMO_PASSWORD}` pendant l'import. Le dépôt est public : **aucun
identifiant n'est jamais versionné.**

### 5. La route, et le document de découverte

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" keycloak/httproute.yaml | kubectl apply -f -
curl -sk "https://keycloak.${LAB_DOMAIN}/realms/lab/.well-known/openid-configuration" | jq .issuer
```

L'`issuer` doit valoir exactement `https://keycloak.<LAB_DOMAIN>/realms/lab`. S'il affiche un nom
interne, c'est `proxy.headers` ou `hostname.hostname` qui est faux — cf. 🚑 plus bas.

## 🔧 Ce que fait le script

1. crée le namespace `keycloak` et le cluster CloudNativePG `keycloak-db`, puis attend qu'il soit
   `Ready` ;
2. applique les quatre CRD (`--server-side`) et l'opérateur, dans le namespace `keycloak` ;
3. applique le CR `Keycloak` avec le domaine substitué et attend `condition=Ready` ;
4. génère le mot de passe de démo **uniquement si son Secret manque**, puis applique l'import du
   realm ;
5. applique l'`HTTPRoute` et affiche les URL ainsi que les commandes qui lisent les identifiants.

### Fichiers

| Fichier | Rôle |
|---|---|
| `01-postgres.yaml` | `Cluster` CloudNativePG `keycloak-db` — 1 instance, 2Gi sur `longhorn-r1`, base et propriétaire `keycloak` |
| `02-keycloak.yaml` | le CR `Keycloak` : base, `httpEnabled`, `proxy.headers: xforwarded`, hostname public, Ingress de l'opérateur désactivé |
| `03-realm-lab.yaml` | `KeycloakRealmImport` : realm `lab`, groupes `k8s-admins` / `k8s-viewers`, scope `groups`, utilisateurs `demo` et `viewer` dont les mots de passe viennent de Secrets |
| `httproute.yaml` | `HTTPRoute` HTTPS `keycloak.lab.example.io` → `keycloak-service:8080`, `sectionName: https` |
| `keycloak-up.sh` | l'installation tout-en-un (idempotente) |

## ✅ Vérifier

```bash
kubectl -n keycloak get keycloak,keycloakrealmimport      # Ready=True, Done=True
kubectl -n keycloak get pods                              # keycloak-0, keycloak-db-1, opérateur
kubectl -n keycloak get httproute keycloak                # Accepted + ResolvedRefs = True
# test de bout en bout, TLS servi par Envoy :
curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  --resolve keycloak.lab.example.io:443:192.168.56.200 \
  https://keycloak.lab.example.io/realms/lab            # attendu : 200 verify=0
```

`--resolve` court-circuite le DNS : pratique pour tester **avant** de créer l'enregistrement.
`verify=0` ne tient qu'avec un certificat publiquement trusté ; avec `SELF_SIGNED=true`, ajoute
`-k` ou passe l'AC du lab avec `--cacert`.

## 🌐 Accès

| Quoi | Valeur |
|---|---|
| Console d'admin | `https://keycloak.lab.example.io/admin/` |
| Admin de bootstrap | `kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.username}' \| base64 -d ; echo` |
| Son mot de passe | `kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.password}' \| base64 -d ; echo` |
| Realm | `lab` — `https://keycloak.lab.example.io/realms/lab` |
| Découverte | `https://keycloak.lab.example.io/realms/lab/.well-known/openid-configuration` |
| Utilisateur de démo | `demo`, membre de `k8s-admins` |
| Son mot de passe | `kubectl -n keycloak get secret keycloak-demo-user -o jsonpath='{.data.password}' \| base64 -d ; echo` |
| Utilisateur en lecture seule | `viewer`, membre de `k8s-viewers` |
| Son mot de passe | `kubectl -n keycloak get secret keycloak-viewer-user -o jsonpath='{.data.password}' \| base64 -d ; echo` |

> 💡 Crée ton propre admin dans le realm `master`, puis **supprime le Secret de bootstrap** :
> `kubectl -n keycloak delete secret keycloak-initial-admin`.

## 🧪 Scénario — le realm survit à son cluster

L'intérêt d'un realm déclaré, c'est qu'il revient. Détruis-le et laisse l'opérateur reconstruire :

```bash
# 1. Constater l'existant
kubectl -n keycloak get keycloakrealmimport lab -o jsonpath='{.status.conditions}' | jq

# 2. Supprimer tout le déploiement — le CR seulement, la base survit
kubectl -n keycloak delete keycloak keycloak
kubectl -n keycloak get pods -w            # l'opérateur reconstruit le StatefulSet

# 3. Réappliquer : même URL, même realm, mêmes utilisateurs — l'état était dans PostgreSQL
kubectl apply -f keycloak/02-keycloak.yaml
curl -sk https://keycloak.lab.example.io/realms/lab | jq .realm
```

Puis l'autre sens — une base vraiment vide :

```bash
kubectl -n keycloak delete keycloakrealmimport lab
kubectl -n keycloak delete cluster keycloak-db          # ⚠️ détruit les données
./keycloak/keycloak-up.sh <distro>                      # tout revient depuis les fichiers
```

Au second passage, le mot de passe de `demo` est **le même** : le script ne régénère pas un Secret
qui existe déjà.

## 🚑 Dépannage

- **L'`issuer` affiche un nom interne, ou le navigateur boucle à la connexion** → `proxy.headers`
  n'est pas `xforwarded`, ou `hostname.hostname` ne correspond pas au hostname de l'`HTTPRoute` :
  `kubectl -n keycloak get keycloak keycloak -o jsonpath='{.spec.hostname}{"\n"}{.spec.proxy}'`.
- **`metadata.annotations: Too long` en appliquant une CRD** → apply côté client. La CRD
  `keycloaks` dépasse 500 Kio : utiliser `kubectl apply --server-side`.
- **L'opérateur démarre mais ne reconcilie rien** → il n'est pas dans le namespace `keycloak`, et
  son `ClusterRoleBinding` (qui y désigne son ServiceAccount en dur) ne lui donne alors aucun
  droit : `kubectl -n keycloak logs deploy/keycloak-operator`.
- **`keycloak-0` en `CrashLoopBackOff` au premier démarrage** → presque toujours la base.
  Vérifier `kubectl -n keycloak get cluster keycloak-db` et les identifiants de `keycloak-db-app`.
  Un OOMKill pendant la migration Liquibase ressemble exactement à ça : monter
  `spec.resources.limits.memory`.
- **Le Job d'import du realm ne finit jamais** → `kubectl -n keycloak get keycloakrealmimport lab -o yaml`
  puis les logs du Job. Un Secret de placeholder manquant fait échouer l'import avec un message
  obscur.
- **Tu as modifié `03-realm-lab.yaml` et rien ne change** → c'est normal. L'import n'**écrase
  pas** un realm existant. Supprimer le CR *et* le realm, puis réappliquer.
- **`404` sur la route** → `kubectl -n keycloak describe httproute keycloak` ; `sectionName: https`
  doit exister sur `main-gateway` et le hostname matcher le wildcard.

## ⚠️ Pièges

- **`proxy.headers: xforwarded` n'est sûr que derrière un proxy que l'on maîtrise.** Il fait
  confiance à `X-Forwarded-Host`. Si le Service était joignable directement, n'importe qui
  pourrait empoisonner les liens des e-mails de réinitialisation. Il reste en `ClusterIP`
  derrière la Gateway.
- **`keycloak-initial-admin` est un identifiant admin COMPLET, en clair** tant qu'on le garde :
  lisible par tout ce qui a `get secrets` dans le namespace.
- **L'IdP est publié sur la VIP** : tous les pairs Tailscale autorisés atteignent la page de
  connexion. La protection anti-brute-force est active dans le realm, mais un vrai mot de passe
  reste obligatoire.
- **L'import de realm est à sens unique.** Il documente l'état *initial*, pas l'état courant.
  Toute modification faite dans la console dérive silencieusement de ce fichier — ce n'est pas du
  GitOps.
- **Détruire le cluster `keycloak-db` détruit toutes les identités.** Le CR `Keycloak` ne porte
  aucun état ; PostgreSQL les porte tous, et ce lab n'en fait aucune sauvegarde (cf.
  [`../cloudnative-pg/`](../cloudnative-pg/LISEZ-MOI.md) pour les sauvegardes S3 + PITR).
- **Empiler ce composant sur des control planes trop justes en RAM** finit par affamer etcd :
  Keycloak demande 768 Mio et monte plus haut au premier démarrage. `lab.env` (`WK_MEM`) est le
  bouton.

## 📚 Références

- [Keycloak Operator — installation](https://www.keycloak.org/operator/installation)
- [Keycloak Operator — configuration avancée (`proxy`, `hostname`, `db`)](https://www.keycloak.org/operator/advanced-configuration)
- [Keycloak Operator — import de realm](https://www.keycloak.org/operator/realm-import)
- [Keycloak — configuration derrière un reverse proxy](https://www.keycloak.org/server/reverseproxy)
- [`keycloak-k8s-resources` — versions](https://github.com/keycloak/keycloak-k8s-resources/tags)
- [`../cloudnative-pg/LISEZ-MOI.md`](../cloudnative-pg/LISEZ-MOI.md) — l'opérateur derrière la base
- [`../envoy-gateway/LISEZ-MOI.md`](../envoy-gateway/LISEZ-MOI.md) — la Gateway qui porte cette route
