# CLAUDE.md — mode d'emploi de ce dépôt pour un agent

> Ce fichier n'est PAS publié dans la documentation (`docs/build.py` l'exclut) : il ne
> s'adresse qu'à un assistant qui travaille sur ce dépôt.

## 1. Ce qu'est ce dépôt

`k8s-playground` est la **couche applicative Kubernetes commune à deux labs Vagrant** :

| Lab | Base | Dépôt |
|---|---|---|
| Talos | Talos Linux — OS immuable, pas de systemd, PodSecurity `baseline` au niveau cluster, `talosctl` | `OPS-NC/Vagrant-Talos` |
| kubeadm | Debian 13 + `kubeadm` — OS ordinaire, aucun PodSecurity appliqué, kube-proxy remplaçable | `OPS-NC/Vagrant-kubeadm` |

Ce dépôt **ne monte aucun cluster** : pas de `Vagrantfile`, pas de `lab.env`, pas de `_out/`.
Les labs possèdent les VM, l'OS et l'état ; ce dépôt possède les manifestes et les charts,
appliqués depuis l'hôte avec `kubectl` / `helm`. Cette absence est **porteuse** : c'est elle qui
permet de reconnaître le lab (« le parent porte un `Vagrantfile` ») sans ambiguïté.

Disposition normale : **sous-module** monté sur `<lab>/_k8s`. Disposition secondaire : dépôts
voisins (`../Vagrant-Talos`, `../Vagrant-KubeADM`).

## 2. LA règle : tout doit marcher sur Talos ET sur kubeadm

**Aucune ressource de ce dépôt n'a le droit de ne fonctionner que sur une seule des deux
distributions.** Un composant est terminé quand il s'installe et fonctionne sur les deux labs,
et que son README explique — même pour dire « rien ne change » — ce qui diffère.

Corollaires, à respecter sans exception :

1. **Jamais de `if [ "$K8S_DISTRO" = talos ]` dispersé dans un script de composant.** Tout ce
   qui diverge est une **variable de profil** (`lib/profiles/talos.sh` /
   `lib/profiles/kubeadm.sh`). Le script de composant lit la variable, il ne teste pas la
   distribution. Si un nouveau besoin de divergence apparaît : ajouter la variable **dans les
   deux profils** (avec un commentaire expliquant pourquoi elle vaut ça ici), puis la lire.
2. **Le profil documente aussi le cas « inutile ».** Sur kubeadm, la plupart des contournements
   Talos tombent : on ne les supprime pas, on écrit `LONGHORN_PREP_REQUISE=false` avec le
   commentaire qui dit *pourquoi* ça tombe. La comparaison entre les deux labs est un objectif
   pédagogique du dépôt, pas un effet de bord.
3. **Namespaces privilégiés étiquetés dans les deux cas.** Un pod privilégié (hostPath,
   hostNetwork, hostPID) exige `pod-security.kubernetes.io/enforce: privileged` sur son
   namespace : indispensable sur Talos (refus **silencieux** sinon — le Deployment existe, le
   ReplicaSet ne crée aucun pod), sans effet aujourd'hui sur kubeadm, mais posé quand même
   parce qu'il documente le besoin et protège d'un durcissement futur.
4. **Chaque README a une section « 🧬 Talos vs kubeadm »**, y compris quand la réponse est
   « aucune spécificité » — auquel cas on dit explicitement que l'argument de distribution ne
   pilote alors que le domaine par défaut et l'emplacement de `lab.env` / `kubeconfig`.
5. **Rien qui suppose systemd, un `/` inscriptible, un `/opt`, un accès SSH ou un gestionnaire
   de paquets** sans passer par une variable de profil. Sur Talos, la configuration des nodes
   passe par `talosctl` (API) et les prérequis « paquet » deviennent des **extensions** cuites
   dans l'image d'installation — elles ne s'ajoutent pas à chaud.

## 3. Architecture

```
install.sh                  point d'entrée : ./install.sh [talos|kubeadm] <composant...>
platform-up.sh              socle : CNI → Envoy Gateway → metrics-server → wildcard TLS
metric-server.yaml          metrics-server (appliqué par platform-up.sh)
lib/common.sh               socle commun : résolution distro/lab, lecture lab.env, helpers
lib/profiles/{talos,kubeadm}.sh   TOUT ce qui diverge entre les deux labs
<composant>/
  <composant>-up.sh         installation tout-en-un, idempotente
  values.yaml / *.yaml      manifestes et values, en valeurs NEUTRES
  README.md / LISEZ-MOI.md  doc EN (canonique) + miroir FR
docs/build.py               génère la page unique depuis tous les README (make docs)
Makefile                    docs, docs-check, validate — tout ce qui tourne sans cluster
```

### `lib/common.sh` — l'API que tout script de composant utilise

| Fonction / variable | Rôle |
|---|---|
| `k8s_init "$@"` | **Point d'entrée obligatoire.** Résout la distribution, charge son profil, localise le lab, calcule `LAB_DOMAIN` / `WILDCARD_TLS`, positionne `KUBECONFIG`. Les arguments non consommés partent dans `K8S_ARGS`. |
| `log` / `warn` / `fail` | Affichage normalisé (`==>`, `/!\`, `ERREUR :` + `exit 1`). |
| `need bin...` | Échoue si un binaire manque du `PATH`. |
| `exiger_apiserver` | Échoue si l'apiserver ne répond pas, avec le rappel du `cluster-up.sh` de la bonne distro. |
| `exiger_sc <sc>` | Échoue si la StorageClass est absente, avec la commande d'installation. |
| `lire_param NOM DEFAUT` | environnement > `_out/cluster.env` > `lab.env` > défaut. |
| `rendre FICHIER...` | Écrit le manifeste sur stdout avec les marqueurs neutres substitués. |
| `resume_distro` | Ligne de rappel du profil actif, affichée en tête d'installation. |
| `REPO_ROOT`, `LAB_DIR`, `K8S_DISTRO`, `LAB_DOMAIN`, `WILDCARD_TLS` | Variables exportées par `k8s_init`. |

### Le dépôt est public : trois marqueurs neutres, substitués à la volée

Aucun manifeste versionné ne porte de valeur réelle. `rendre` remplace, **sans jamais réécrire
un fichier versionné** (`git status` reste propre) :

| Marqueur versionné | Remplacé par |
|---|---|
| `lab.example.io` | `$LAB_DOMAIN` (défaut `<distro>.lab.example.io`) |
| `lab-example-io` | `$LAB_DOMAIN_DASH` — nom du Secret TLS wildcard |
| `lab-kv` | `$VAULT_KV_MOUNT` (`talos-lab` / `kubeadm-lab`) |

Toute valeur qui dépend du lab **doit** passer par un de ces marqueurs ou par `lire_param`.
Ne jamais committer un domaine réel, un token, un mot de passe : la CI `docs` refuse de publier
si elle détecte un motif de secret dans la page générée.

### Exposition des UI

Une seule Gateway, `main-gateway` (ns `envoy-gateway-system`), écouteurs `:80` et `:443`. Le
TLS est terminé par **Envoy** avec le wildcard `*.<LAB_DOMAIN>`. Un composant qui expose une UI
pose donc un `HTTPRoute` **dans son propre namespace** :

```yaml
parentRefs:
  - name: main-gateway
    namespace: envoy-gateway-system
    sectionName: https        # écouteur TLS :443
hostnames:
  - <appli>.lab.example.io    # matche le wildcard
```

Possible entre namespaces parce que `main-gateway` ouvre ses écouteurs à `from: All` ; le
backend étant dans le même namespace que la route, aucun `ReferenceGrant` n'est nécessaire.
**Corollaire systématique** : l'application derrière doit parler **HTTP en clair** et ne pas
faire sa propre redirection `http→https`, sinon boucle de redirection (cf.
`server.insecure=true` d'Argo CD, `proxy.headers: xforwarded` de Keycloak).

## 4. Ajouter un composant — la checklist

1. `mkdir <composant>/` ; le script s'appelle `<composant>-up.sh`, il est **exécutable** et
   **idempotent** (`helm upgrade --install` + `kubectl apply`, relançable sans casse).
2. En-tête de script : commentaire qui dit **quoi**, **comment le lancer**, **les prérequis**,
   **ce qui diffère entre les deux distributions**, et pourquoi le montage est fait ainsi.
   Les commentaires de ce dépôt expliquent le *pourquoi*, pas le *quoi* — c'est le contrat de
   style, y compris dans les YAML.
3. Squelette :
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   # shellcheck source=../lib/common.sh
   . "${HERE}/../lib/common.sh"
   k8s_init "$@"
   FOO_VERSION="${FOO_VERSION:-x.y.z}"   # version ÉPINGLÉE, surchargeable
   need kubectl helm
   exiger_apiserver
   ```
4. Versions **épinglées** dans le script via une variable d'environnement surchargeable, et
   reportées dans le tableau « Versions épinglées » des deux README racine.
5. Étapes numérotées `log "[1/N] …"`, puis un bloc final qui affiche l'URL, les identifiants
   (jamais leur valeur : la **commande** pour les lire) et une commande de vérification.
6. Secrets : jamais sur stdout, jamais dans un fichier versionné. Le seul emplacement admis
   est `${LAB_DIR}/_out/` (gitignoré), en `0600`, avec `umask 077` posé **avant** la
   redirection (cf. `vault-cluster/vault-up.sh`).
7. Documentation : `README.md` (EN, canonique) **et** `LISEZ-MOI.md` (FR, miroir strict).
8. Référencer le composant :
   - `install.sh` → tableau `CATALOGUE` (`alias|chemin/script|description`), à la bonne place
     dans l'ordre d'installation conseillé (`all`) ;
   - `README.md` et `LISEZ-MOI.md` racine → section « catalogue » + tableau des versions
     (+ « chaîne de dépendances » si le composant en introduit une) ;
   - `docs/build.py` → `GROUPES` (groupe du menu) et `EMOJIS` (pictogramme de la page).
9. `make validate` doit passer.

### Le gabarit d'un README de composant

Ordre des sections, tel qu'on le trouve dans tous les dossiers existants :

```
<!-- i18n -->            bannière de langue (EN : **English** · [Français](LISEZ-MOI.md))
# <emoji> `<dossier>/` — titre
> accroche en une ou deux phrases
> 🌐 rappel du domaine neutre
## 🎯 À quoi ça sert
### Le montage en une phrase
## 📋 Prérequis                (tableau : prérequis | pourquoi | vérifier)
## ⚡ Installation             (install.sh, puis <composant>-up.sh, puis <details> équivalent manuel)
## 🧬 Talos vs kubeadm         (OBLIGATOIRE, même pour dire « aucune spécificité »)
## 🎓 Pas à pas guidé          (les mêmes commandes, une par une — usage formation)
## 🔧 Ce que fait le script + tableau « Fichiers »
## ✅ Vérifier
## 🌐 Accès                    (si UI)
## 🧪 Scénario                 (la démo qui justifie le composant)
## 🚑 Dépannage
## ⚠️ Pièges
## 📚 Références
```

Le miroir FR est **strict** : mêmes sections, mêmes tableaux, mêmes commandes, mêmes ancres
relatives — seuls la langue et les liens changent (`../x/README.md` → `../x/LISEZ-MOI.md`).

## 5. Documentation

- `README.md` = anglais **canonique**, `LISEZ-MOI.md` = miroir français, dans le **même
  dossier**. Toute page a ses deux versions ; un oubli est visible (badge « EN »).
- `docs/build.py` génère `docs/index.html`, **page unique autonome** : aucun CDN, aucun asset
  externe, images embarquées en `data:` URI. Toute page `*.md` du dépôt est découverte
  automatiquement (sauf exclusions) ; seuls le groupe de menu et l'emoji sont déclarés.
- Les liens internes sont réécrits en routes de la page unique. **`make docs-check` échoue si
  un lien ou une ancre ne résout pas** — c'est aussi ce que fait la CI (`--strict`). Un lien
  vers un fichier qui n'existe pas encore casse donc le build : ne pas référencer un composant
  d'une autre branche.
- Commandes : `make docs`, `make docs-open`, `make docs-check`.

## 6. Valider avant de conclure

```bash
make validate        # = validate-shell + validate-yaml + validate-docs
make validate-shell  # bash -n sur tous les *.sh
make validate-yaml   # kubectl create --dry-run=client sur tous les *.yaml/*.yml (sans cluster)
make docs-check      # tous les liens et ancres de la doc résolvent
```

Aucun cluster n'est requis. Une tâche n'est pas terminée tant que `make validate` ne passe pas.

## 7. Conventions

- **Langue** : commentaires de code et scripts en **français** ; `README.md` en **anglais**,
  `LISEZ-MOI.md` en **français**.
- **Commits** : `[Claude] <type>: <description>` — `fix`, `feat`, `refactor`, `docs`, `chore`,
  `perf`, `test`. Message en français.
- **Shell** : `set -euo pipefail` partout. Jamais de `grep` dont l'échec est normal (sous
  `pipefail` + `set -e`, il tue le script) — utiliser `sed -n 's///p'` ou terminer par
  `|| true`.
- **Pas de `sudo`** dans les scripts.
- Ne pas créer de fichier qui n'est pas référencé par un README ou un script.
