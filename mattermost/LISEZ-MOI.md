<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 💬 `mattermost/` — Mattermost (chat) + alertes Alertmanager dans un canal

> **Un chat auto-hébergé, et le point d'arrivée des alertes du lab.** Mattermost **Team Edition**
> (l'édition communautaire gratuite) sur PostgreSQL, exposé en HTTPS derrière Envoy Gateway, plus
> deux CRD qui transforment les alertes Prometheus en messages dans un canal dédié :
> `PrometheusRule` pour les règles, `AlertmanagerConfig` pour le routage. Le même bloc de routage
> fonctionne pour **Slack** et **Microsoft Teams** (voir
> [Autres destinations](#-autres-destinations--slack-microsoft-teams)).

> 🌐 `lab.example.io` est le domaine NEUTRE (public) de ce dépôt : `mattermost-up.sh` le remplace
> par `LAB_DOMAIN` (`lab.env`) dans les values Helm **et** dans l'`HTTPRoute`. Cf.
> [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui).

## 🎯 Objectif

- Donner au lab une **destination de notification qui lui appartient** : aucun SaaS externe, aucun
  webhook sortant vers internet, aucun jeton à faire tourner.
- Montrer la **chaîne d'alerte de bout en bout** : une règle dans Prometheus → une route dans
  Alertmanager → un message dans un canal, le tout déclaré en **CRD Kubernetes**.
- Servir de support concret à la question « et comment je me fais alerter ? », qui suit toujours le
  module [`observability/`](../observability/LISEZ-MOI.md).

### Trois choix de conception à connaître

- **PostgreSQL, pas le MySQL embarqué du chart.** Mattermost **v11 a retiré le driver MySQL de son
  code**. Le chart reste par défaut sur `mysql.enabled: true`, ce qui est **cassé d'origine** sur
  cette version de l'application (voir ⚠️ Pièges). La base est un cluster
  [CloudNativePG](../cloudnative-pg/LISEZ-MOI.md), comme celle de Keycloak.
- **Webhook compatible Slack, aucun plugin.** Les webhooks entrants de Mattermost acceptent le
  format de charge utile de Slack : le receiver `slackConfigs` standard d'Alertmanager y poste
  directement. Rien à installer d'un côté ni de l'autre.
- **Amorçage par `mmctl --local`.** La création de l'admin, de l'équipe, du canal et du webhook
  passe par un **socket unix dans le pod** : ni DNS, ni ingress, ni TLS, ni mot de passe sur une
  ligne de commande.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| `../platform-up.sh` (Cilium + Envoy Gateway + cert-manager) | expose l'UI en HTTPS:443 avec le certificat wildcard | `kubectl get gateway -n envoy-gateway-system` |
| SC **`longhorn-r1`** ([`../longhorn/`](../longhorn/LISEZ-MOI.md)) | 3 PVC : données 5Gi, plugins 1Gi, PostgreSQL 5Gi | `kubectl get sc longhorn-r1` |
| **CloudNativePG** ([`../cloudnative-pg/`](../cloudnative-pg/LISEZ-MOI.md)) | fournit la base ; le script **s'arrête** sans le CRD | `kubectl get crd clusters.postgresql.cnpg.io` |
| **kube-prometheus-stack** ([`../observability/`](../observability/LISEZ-MOI.md)) | Alertmanager + les CRD `PrometheusRule`/`AlertmanagerConfig` | `kubectl -n monitoring get alertmanager` |

> ℹ️ Alertmanager est le seul prérequis **souple** : sans lui, les étapes 4 et 5 sont ignorées avec
> un avertissement et Mattermost s'installe seul. Relance le script après avoir installé
> `observability` pour câbler l'alerting.

## ⚡ Installation

Par le point d'entrée du dépôt :
```bash
./install.sh <distro> mattermost     # <distro> = talos | kubeadm
```

```bash
./mattermost/mattermost-up.sh <distro>
```

Versions épinglées dans le script (surchargeables par variable d'environnement) :

| Chart | Version | Application |
|---|---|---|
| `mattermost/mattermost-team-edition` | `6.6.104` (`MATTERMOST_CHART_VERSION`) | Mattermost 11.9.0 |

Le mot de passe admin est **généré au premier passage** et conservé dans un Secret : relancer le
script ne le change jamais.

```bash
kubectl -n mattermost get secret mattermost-admin -o jsonpath='{.data.password}' | base64 -d; echo
```

## 🧬 Talos vs kubeadm

**Aucun comportement propre à une distribution** : même chart, mêmes manifestes, mêmes values sur
les deux labs. La distribution ne décide que du **domaine**
(`mattermost.talos.lab.example.io` / `mattermost.kubeadm.lab.example.io`) et de l'emplacement du
`lab.env` / `kubeconfig` du lab.

## 🎓 Parcours guidé (pas à pas)

> Les commandes ci-dessous sont **exactement** ce que fait le script, dans l'ordre.
> Prépare ton shell d'abord (une fois par session) :
> ```bash
> export KUBECONFIG=../Vagrant-KubeADM/kubeconfig    # ou ../Vagrant-Talos/kubeconfig
> export LAB_DOMAIN=kubeadm.lab.example.io           # le tien (cf. le lab.env du lab)
> ```

### 1. Prérequis

```bash
kubectl get sc longhorn-r1                              # les 3 PVC
kubectl get crd clusters.postgresql.cnpg.io             # CloudNativePG
kubectl -n monitoring get alertmanager                  # la cible des alertes
```

### 2. La base de données

```bash
kubectl apply -f mattermost/namespace.yaml
kubectl apply -f mattermost/postgres-cluster.yaml
kubectl -n mattermost wait --for=condition=Ready cluster/mattermost-db --timeout=300s
```

### 3. Mattermost lui-même

Le mot de passe généré par CloudNativePG est injecté dans les values ; il n'est jamais écrit dans
un fichier versionné.

```bash
PGPASS=$(kubectl -n mattermost get secret mattermost-db-app -o jsonpath='{.data.password}' | base64 -d)
sed -e "s/lab\.example\.io/${LAB_DOMAIN}/g" -e "s|@@PGPASSWORD@@|${PGPASS}|" \
  mattermost/values.yaml > /tmp/mm-values.yaml

helm repo add mattermost https://helm.mattermost.com && helm repo update mattermost
helm upgrade --install mattermost mattermost/mattermost-team-edition -n mattermost \
  --version 6.6.104 --values /tmp/mm-values.yaml
kubectl -n mattermost rollout status deploy/mattermost-mattermost-team-edition --timeout=300s
```

### 4. L'exposition

```bash
sed "s/lab\.example\.io/${LAB_DOMAIN}/g" mattermost/httproute.yaml | kubectl apply -f -
```

### 5. Amorçage : admin, équipe, canal, webhook

`mmctl --local` parle au serveur par un socket unix dans le pod — aucune authentification requise.

```bash
mm() { kubectl -n mattermost exec deploy/mattermost-mattermost-team-edition \
         -c mattermost-team-edition -- mmctl --local "$@"; }

# PAS `tr -dc … | head -c 24` : head ferme le tube, tr prend un SIGPIPE et le
# script meurt en 141 sous `set -o pipefail`. On borne la lecture, pas l'écriture.
ADMIN_PASS=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)
kubectl -n mattermost create secret generic mattermost-admin \
  --from-literal=username=admin --from-literal=password="$ADMIN_PASS"

mm user create --email "admin@${LAB_DOMAIN}" --username admin --password "$ADMIN_PASS" --system-admin
mm team create --name lab --display-name "Lab k8s"
mm team users add lab "admin@${LAB_DOMAIN}"
mm channel create --team lab --name alertes-k8s --display-name "Alertes k8s"

# `--channel` et `--user` acceptent team:canal et un email, malgré ce que dit --help.
# La première ligne de la réponse est "Id: <identifiant de 26 caractères>".
mm webhook create-incoming --channel lab:alertes-k8s --user "admin@${LAB_DOMAIN}" \
   --display-name Alertmanager --lock-to-channel
```

Puis on range l'URL du webhook là où Alertmanager la lira. **Volontairement l'URL interne au
cluster** : livrer une alerte ne doit dépendre ni du DNS public, ni de la Gateway, ni du
certificat.

```bash
HOOK_ID=<l identifiant renvoyé par la commande précédente>
kubectl -n monitoring create secret generic mattermost-webhook \
  --from-literal=url="http://mattermost-team-edition.mattermost:8065/hooks/${HOOK_ID}"
```

### 6. L'alerting, en deux CRD

```bash
# Sans ça, les alertes de NODE ne sont jamais livrées — voir le ⚠️ plus bas.
kubectl -n monitoring patch alertmanager kube-prometheus-stack-alertmanager --type=merge \
  -p '{"spec":{"alertmanagerConfigMatcherStrategy":{"type":"None"}}}'

kubectl apply -f mattermost/prometheusrule-lab-alerts.yaml
kubectl apply -f mattermost/alertmanagerconfig.yaml
```

## 🔧 Ce que fait le script

1. **PostgreSQL** — applique le namespace et le `Cluster` CloudNativePG, puis attend
   `condition=Ready` (initdb + premier démarrage).
2. **Mattermost** — lit le mot de passe généré par CloudNativePG, rend les values (domaine +
   mot de passe) dans un fichier temporaire, `helm upgrade --install`, attend le rollout.
3. **HTTPRoute** — rend et applique l'exposition.
4. **Amorçage** — par `mmctl --local` : admin (mot de passe généré dans un Secret **seulement
   une fois le compte réellement créé**), équipe, canal, et **un** webhook entrant, réutilisé
   d'un passage à l'autre. Range son URL interne dans le Secret `mattermost-webhook`.
5. **Alerting** — patche `alertmanagerConfigMatcherStrategy`, applique le `PrometheusRule` et
   l'`AlertmanagerConfig`.

Les étapes 4 et 5 sont ignorées avec un avertissement s'il n'y a pas d'Alertmanager : Mattermost
seul fonctionne quand même.

### Fichiers

| Fichier | Rôle |
|---|---|
| `namespace.yaml` | le namespace `mattermost` (aucun label PodSecurity nécessaire) |
| `postgres-cluster.yaml` | `Cluster` CloudNativePG : PG 18, 1 instance, 5Gi sur `longhorn-r1`, sans superuser |
| `values.yaml` | values Helm : MySQL embarqué **coupé**, `externalDB` sur PostgreSQL, PVC sur `longhorn-r1`, pas d'Ingress, stratégie `Recreate`, mode local activé |
| `httproute.yaml` | `mattermost.<LAB_DOMAIN>` → `mattermost-team-edition:8065`, listener `https` |
| `prometheusrule-lab-alerts.yaml` | 6 alertes de lab, **plus rapides** que celles livrées |
| `alertmanagerconfig.yaml` | routage vers le webhook Mattermost + `severity: none` jeté |
| `mattermost-up.sh` | l'ensemble, idempotent |

### Les six alertes, et pourquoi elles côtoient celles du stack

kube-prometheus-stack livre déjà ~150 règles kubernetes-mixin, dont `KubePodCrashLooping`,
`KubeNodeNotReady`, `NodeCPUHighUsage` et `NodeMemoryHighUtilization`. Elles sont **calibrées pour
la production** : `for: 15m` à `30m`, et `NodeCPUHighUsage` est en `severity: info`. Sur un lab,
personne n'attend 15 minutes pour savoir si l'alerting marche. Le préfixe `Lab` fait cohabiter les
deux jeux.

| Alerte | Condition | `for` | Sévérité |
|---|---|---|---|
| `LabPodCrashLooping` | un conteneur en `CrashLoopBackOff` | 2m | critical |
| `LabPodNotReady` | pod `Pending`/`Unknown`/`Failed` (Jobs exclus) | 5m | warning |
| `LabNodeNotReady` | node `Ready != true` | 2m | critical |
| `LabNodeCPUHigh` | CPU node > 85 % (idle/iowait/**steal** exclus) | 5m | warning |
| `LabNodeMemoryHigh` | RAM node > 85 % (sur `MemAvailable`) | 5m | warning |
| `LabNodeDiskAlmostFull` | `/` sous 15 % libre | 5m | warning |

## ✅ Vérifier

```bash
kubectl -n mattermost get pods,pvc              # 2 pods Running, 3 PVC Bound sur longhorn-r1
curl -s "https://mattermost.${LAB_DOMAIN}/api/v4/system/ping"        # {"status":"OK"}

# Les règles sont chargées et saines (6, health=ok) :
curl -sk "https://prometheus.${LAB_DOMAIN}/api/v1/rules" \
  | grep -o '"name":"Lab[A-Za-z]*"' | sort -u

# Le routage est vivant dans Alertmanager (le receiver doit être listé) :
curl -sk "https://alertmanager.${LAB_DOMAIN}/api/v2/receivers"
```

## 🧪 Scénario — la chaîne d'alerte de bout en bout

Le seul test qui prouve quelque chose : provoquer une vraie panne et attendre le message.

```bash
kubectl create deployment crashtest --image=busybox:1.36 -- sh -c 'exit 1'
# ~4 min plus tard (2 min de CrashLoopBackOff + `for: 2m` + 30s de groupWait) un message
# 🔴 [FIRING:1] LabPodCrashLooping arrive dans ~alertes-k8s
kubectl delete deployment crashtest
# et un ✅ [RESOLVED] suit sous ~2 min (sendResolved: true)
```

> ℹ️ **Laisse-lui quatre minutes, pas une.** `kube_pod_container_status_waiting_reason` est une
> série **éparse** : kube-state-metrics ne l'émet que pendant que le conteneur est réellement en
> `Waiting`. Un conteneur qui redémarre vite est souvent scruté en `terminated` à la place, et
> l'alerte ne part qu'une fois le backoff de redémarrage assez grand pour qu'un scrape tombe dans
> la fenêtre `CrashLoopBackOff`. C'est exactement pour ça que la règle utilise
> `max_over_time(...[5m])` et non une requête instantanée.

## 🌐 Accès

| Quoi | Où |
|---|---|
| Mattermost | `https://mattermost.<LAB_DOMAIN>` |
| Compte admin | `admin` — `kubectl -n mattermost get secret mattermost-admin -o jsonpath='{.data.password}' \| base64 -d` |
| Canal d'alertes | équipe **Lab k8s**, canal **~alertes-k8s** |

## 📮 Autres destinations : Slack, Microsoft Teams

Les règles ([`prometheusrule-lab-alerts.yaml`](prometheusrule-lab-alerts.yaml)) ne changent
jamais — seul le receiver de [`alertmanagerconfig.yaml`](alertmanagerconfig.yaml) bouge.

### Slack

**Identique à Mattermost**, et c'est tout l'intérêt du webhook compatible Slack : crée un
[webhook entrant](https://api.slack.com/messaging/webhooks) sur ton espace de travail, puis seul
le contenu du Secret change.

```bash
kubectl -n monitoring create secret generic slack-webhook \
  --from-literal=url="https://hooks.slack.com/services/<WORKSPACE_ID>/<WEBHOOK_ID>/<TOKEN>"
```

```yaml
      slackConfigs:
        - apiURL: { name: slack-webhook, key: url }
          channel: "#alerts-k8s"      # avec le # sur Slack
          sendResolved: true
          title: '...'                # mêmes templates
          text: '...'
```

Deux différences à garder en tête :

- Le nom du canal **prend un `#`** sur Slack ; Mattermost l'accepte avec ou sans.
- Slack rend `*gras*` et `` `code` `` de la même façon, mais **pas** `_italique_` dans un champ
  d'attachement comme le fait Mattermost. Sans conséquence : seul le style diffère.

### Microsoft Teams

Teams ne comprend **pas** les charges utiles Slack : il attend une *MessageCard* / *Adaptive
Card*. Deux voies supportées, selon la version de prometheus-operator :

**1. `msteamsv2Configs` (Power Automate Workflows — la voie actuelle).** Microsoft a
[retiré les connecteurs Office 365](https://devblogs.microsoft.com/microsoft365dev/retirement-of-office-365-connectors-within-microsoft-teams/) ;
le remplacement est un *Workflow* qui te donne une URL de POST HTTP. Exige
prometheus-operator ≥ v0.79 et Alertmanager ≥ v0.28 — les versions épinglées par ce dépôt
(opérateur v0.93.0, Alertmanager v0.33.1) le supportent toutes les deux.

```bash
kubectl -n monitoring create secret generic msteams-webhook \
  --from-literal=url="https://prod-00.westeurope.logic.azure.com:443/workflows/…"
```

```yaml
      msteamsv2Configs:
        - webhookURL: { name: msteams-webhook, key: url }
          sendResolved: true
          title: '{{ if eq .Status "firing" }}🔴{{ else }}✅{{ end }} [{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}'
          text: |-
            {{ range .Alerts -}}
            **{{ .Annotations.summary }}**
            {{ .Annotations.description }}
            {{ end }}
```

**2. `msteamsConfigs`** — l'ancien champ, pour les URL de connecteur `webhook.office.com`
historiques. Même forme, mais `webhookUrl` au lieu de `webhookURL`. À n'utiliser que sur un tenant
déjà câblé.

> ⚠️ **Teams est plus strict sur la charge utile que Mattermost ou Slack.** Le `title` doit rester
> court et le Markdown se limite au **gras** et aux retours à la ligne — pas d'`_italique_`, pas de
> `` `code` ``. Reprends les templates ci-dessus plutôt que ceux de Mattermost, sinon la carte
> affiche les backticks bruts.

> 💡 Vérifie ce que ton cluster supporte vraiment avant d'écrire le manifeste — le champ est
> ignoré en silence si le CRD ne le connaît pas :
> ```bash
> kubectl explain alertmanagerconfig.spec.receivers --recursive | grep -i msteams
> ```

### Plusieurs destinations à la fois

Ajoute les receivers et sépare par matchers — par exemple les critiques vers Teams, tout vers
Mattermost :

```yaml
  route:
    receiver: mattermost
    routes:
      - receiver: "null"
        matchers: [{ name: severity, value: none }]
      - receiver: msteams
        matchers: [{ name: severity, value: critical }]
        continue: true          # SANS ça, Mattermost ne voit jamais les critiques
```

> ⚠️ **`continue: true` est le piège.** Alertmanager s'arrête à la **première** route qui matche.
> Une route `critical` placée avant l'attrape-tout vole en silence toutes les alertes critiques au
> canal du dessous.

## 🚑 Dépannage

| Symptôme | Où regarder |
|---|---|
| Aucun message | `kubectl -n monitoring logs sts/alertmanager-kube-prometheus-stack-alertmanager \| grep -i mattermost` — un 4xx = URL de webhook fausse ou hook supprimé |
| Les alertes de pod arrivent, celles de node non | `kubectl -n monitoring get alertmanager kube-prometheus-stack-alertmanager -o jsonpath='{.spec.alertmanagerConfigMatcherStrategy.type}'` doit afficher `None` |
| Le receiver manque | `curl -sk https://alertmanager.<LAB_DOMAIN>/api/v2/receivers` — si `monitoring/mattermost/mattermost` est absent, l'opérateur n'a pas encore rechargé le CRD (~30s) |
| Règles absentes de Prometheus | `kubectl -n monitoring get prometheusrule lab-alerts` puis `curl -sk https://prometheus.<LAB_DOMAIN>/api/v1/rules \| grep Lab` |
| Mattermost redémarre en boucle | `kubectl -n mattermost logs deploy/mattermost-mattermost-team-edition --previous` — presque toujours la base (cf. le piège MySQL) |
| `mmctl` ne répond rien | le mode local est coupé : vérifie `MM_SERVICESETTINGS_ENABLELOCALMODE` dans les values |

## ⚠️ Pièges

- **Mattermost v11 a retiré MySQL — le défaut du chart est cassé.** `mysql.enabled: true` (défaut
  du chart) construit `MM_CONFIG=mysql://…` ; la v11 ne reconnaît plus ça comme un DSN de base, le
  prend pour un **chemin de fichier** et meurt sur
  `could not create config file: open /mattermost/config/mysql:/mattermost:<mdp>@tcp(...)`.
  Le chemin déformé (`mysql:/` avec un seul slash, à cause du nettoyage de chemin) est l'indice.
  D'où `mysql.enabled: false` + `externalDB` sur PostgreSQL.
- **`deploymentStrategy: Recreate` est obligatoire** avec des volumes Longhorn RWO. Avec le
  `RollingUpdate` par défaut du chart, le nouveau pod tente d'attacher un volume que l'ancien
  détient encore → `Multi-Attach error for volume … Volume is already used by pod(s) …` et le
  rollout se bloque indéfiniment. Même piège que
  [`../wordpress-example/`](../wordpress-example/LISEZ-MOI.md).
  ⚠️ **Basculer une release déjà déployée** vers `Recreate` échoue deux fois. D'abord sur
  `spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy type is 'Recreate'`
  (le champ résiduel). Et si on le retire au `kubectl patch`, le `helm upgrade` **suivant** échoue
  sur `conflict with "kubectl-patch" using apps/v1: .spec.strategy.type` — le patch a pris la
  propriété du champ à Helm, et le server-side apply refuse de la lui reprendre. Supprime plutôt
  le Deployment et laisse Helm le recréer proprement ; les PVC sont des objets distincts, donc
  rien n'est perdu :
  ```bash
  kubectl -n mattermost delete deploy mattermost-mattermost-team-edition
  ./mattermost/mattermost-up.sh <distro>
  ```
  (Helm 4 accepte aussi `--force-conflicts`, mais ça fait taire *tous* les conflits, y compris
  ceux qu'il faut lire.)
- **Les alertes de node n'arrivent jamais** → `alertmanagerConfigMatcherStrategy` est resté sur son
  défaut `OnNamespace`. prometheus-operator injecte alors un matcher `namespace="monitoring"` dans
  la route générée depuis le CRD, et les alertes de node (`LabNodeNotReady`, `LabNodeCPUHigh`…) ne
  portent **aucun label `namespace`**. La panne est silencieuse et ressemble à un succès, parce que
  les alertes de *pod*, elles, arrivent. `type: None` est le correctif.
- **Le canal se noie sous `Watchdog` / `InfoInhibitor`** → ce sont les rouages internes
  d'Alertmanager, **toujours actifs par conception**. Route `severity: none` vers un receiver vide
  (c'est ce que fait `alertmanagerconfig.yaml`) ; matcher sur la sévérité plutôt que sur les deux
  noms couvre aussi les futures.
- **Chaque notification arrive deux fois** → deux webhooks entrants pointent sur le canal. Le
  script réutilise celui nommé `Alertmanager` ; un hook créé à la main sous un autre nom ajoute une
  seconde livraison. `mmctl --local webhook list lab`.
- **`MM_SERVICESETTINGS_SITEURL` doit être l'URL en `https://`.** Mattermost en dérive ses propres
  liens *et les URL de ses webhooks* ; avec une mauvaise valeur les webhooks répondent mais les
  permaliens des messages pointent dans le vide.
- **Aucun shell dans l'image.** `kubectl exec … -- sh` échoue sur
  `exec: "sh": executable file not found`. Appelle `mmctl` directement, sans enrobage shell.
- **Les conteneurs du chart n'ont pas de limite CPU**, ce qui déclenche la policy Kyverno
  `require-requests-limits` du lab. Elle est en **Audit** : cela ne produit qu'un avertissement
  `PolicyViolation`, rien n'est bloqué. Ce dépôt plafonne la RAM et ne *throttle* volontairement
  pas le CPU.

## 🧹 Désinstallation

```bash
kubectl -n monitoring delete alertmanagerconfig mattermost
kubectl -n monitoring delete prometheusrule lab-alerts
kubectl -n monitoring delete secret mattermost-webhook
helm uninstall mattermost -n mattermost
kubectl delete ns mattermost          # ⚠️ supprime les PVC, donc les messages et la base
```

## 📚 Références

- [Chart Helm Mattermost Team Edition](https://github.com/mattermost/mattermost-helm/tree/master/charts/mattermost-team-edition)
- [Mattermost — fonctionnalités retirées et dépréciées (MySQL en v11)](https://docs.mattermost.com/product-overview/deprecated-features.html)
- [Mattermost — webhooks entrants (compatibles Slack)](https://developers.mattermost.com/integrate/webhooks/incoming/)
- [`mmctl` — mode local](https://docs.mattermost.com/manage/mmctl-command-line-tool.html)
- [prometheus-operator — API `AlertmanagerConfig`](https://prometheus-operator.dev/docs/api-reference/api/#monitoring.coreos.com/v1alpha1.AlertmanagerConfig)
- [Alertmanager — arbre de routage et `continue`](https://prometheus.io/docs/alerting/latest/configuration/#route)
- [`../observability/LISEZ-MOI.md`](../observability/LISEZ-MOI.md) — d'où viennent les alertes
