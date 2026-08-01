#!/usr/bin/env bash
#
# vso-up.sh — installe le Vault Secrets Operator (VSO), et RIEN D'AUTRE.
#
#   ./vault-secret-operator/vso-up.sh <talos|kubeadm>   (ou ./install.sh <distro> vso)
#
# ⚠️ CE SCRIPT NE POSE QUE LA MOITIÉ « OPÉRATEUR » DU MONTAGE, et c'est délibéré.
#    L'intégration Vault ↔ Kubernetes se câble des DEUX côtés, dans cet ordre :
#
#      1. côté VAULT  — auth kubernetes, moteurs, policies, roles.  vault/*.sh
#         Exige VAULT_ADDR + un VAULT_TOKEN d'admin : un secret qui n'a rien à faire
#         dans un script d'installation lancé en boucle par `install.sh all`.
#      2. côté OPÉRATEUR — le chart. C'est CE script, et lui seul.
#      3. côté KUBERNETES — les CR (VaultConnection, VaultAuth, VaultStaticSecret…).
#         Elles ne servent à rien tant que l'étape 1 n'a pas créé le role correspondant :
#         VSO se connecte, Vault refuse, et le Secret n'est jamais rempli.
#
#    L'opérateur seul est inerte et inoffensif : il attend des CR. Le poser ici rend le
#    catalogue honnête (`./install.sh list` le montre) sans prétendre que l'intégration
#    est faite. Les étapes 1 et 3 restent des commandes explicites, documentées dans
#    vault/README.md et k8s/README.md — et rappelées à la fin de ce script.
#
# Aucune spécificité de distribution : l'opérateur est un contrôleur ordinaire. La seule
# divergence du composant est cosmétique — le nom du montage KV-v2 de démonstration
# (`VAULT_KV_MOUNT` : talos-lab / kubeadm-lab), et il n'intervient qu'à l'étape 1.
#
# Prérequis : un cluster joignable. Le serveur Vault n'a PAS besoin d'être debout pour
# poser l'opérateur — il le sera pour que les CR aboutissent.
# Idempotent : `helm upgrade --install`. Relançable sans casse.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Version épinglée (overridable par variable d'env) ----------------------
VSO_VERSION="${VSO_VERSION:-1.5.0}"        # app 1.5.0
NS="${NS:-vault-secrets-operator}"

need kubectl helm
require_apiserver

# ============================================================================
log "[1/1] Vault Secrets Operator ${VSO_VERSION}"
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null
# values.yaml ne porte aucun domaine (l'adresse Vault par défaut est le Service
# in-cluster) : appliqué tel quel, sans passer par `render`.
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace "$NS" --create-namespace \
  --version "${VSO_VERSION}" \
  --values "${HERE}/values.yaml"
kubectl -n "$NS" rollout status deploy/vault-secrets-operator-controller-manager --timeout=300s

# ============================================================================
log "Vault Secrets Operator installé — l'intégration, elle, reste à faire."
echo "  CRD          : kubectl api-resources --api-group=secrets.hashicorp.io"
echo "  Connexion    : kubectl get vaultconnection -A     (le 'default' posé par le chart)"
echo
echo "  Il manque les deux autres moitiés, dans cet ordre :"
echo "    1. côté Vault (exige un token d'admin) :"
echo "         export VAULT_ADDR=https://vault.${LAB_DOMAIN}"
echo "         export VAULT_TOKEN=\$(jq -r .root_token ${LAB_DIR}/_out/vault-init.json)"
echo "         ./vault-secret-operator/vault/00-secrets-engines.sh ${K8S_DISTRO}"
echo "         ./vault-secret-operator/vault/01-kubernetes-auth.sh ${K8S_DISTRO}"
echo "         ./vault-secret-operator/vault/02-roles.sh ${K8S_DISTRO}"
echo "       (le MODE=incluster/external de 01- est un piège : cf. vault/README.md)"
echo "    2. côté Kubernetes, les CR de démonstration :"
echo "         ./vault-secret-operator/vault/lab-kv.sh ${K8S_DISTRO}"
echo "         kubectl apply -f vault-secret-operator/k8s/nginx-test-vault/nginx-test-vault.yaml"
echo "       (détails : vault-secret-operator/k8s/README.md)"
