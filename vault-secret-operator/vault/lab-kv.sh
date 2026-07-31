#!/usr/bin/env bash
# Config côté serveur Vault pour le lab : auth Kubernetes + moteur KV-v2 "$VAULT_KV_MOUNT/"
# (un sous-dossier par appli) + policy/role de l'appli de démo "nginx-test-vault".
#
# Idempotent : relançable sans casse. À lancer depuis l'hôte avec le CLI vault :
#   export VAULT_ADDR=https://vault.lab.example.io
#   export VAULT_TOKEN=<root-token>
#   ./vault-secret-operator/vault/lab-kv.sh <talos|kubeadm>
#
# (Vault tourne IN-CLUSTER — chart vault-cluster/ — donc l'auth k8s se configure en mode
#  in-cluster : Vault valide les tokens de SA via son propre SA délégateur.)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
. "${HERE}/../../lib/common.sh"
k8s_init "$@"

# Nom du moteur KV-v2 du lab : `talos-lab/` ou `kubeadm-lab/` selon le profil (les deux labs
# peuvent ainsi coexister dans un même Vault). Les fichiers versionnés portent le nom NEUTRE
# `lab-kv` — substitué ici, exactement comme le domaine (cf. lib/common.sh, `rendre`).
MOUNT="${VAULT_KV_MOUNT}"
# Le CLI `vault` parle à l'API de Vault : sans lui, rien de ce qui suit ne marche.
need vault

: "${VAULT_ADDR:?export VAULT_ADDR (ex: https://vault.lab.example.io)}"
: "${VAULT_TOKEN:?export VAULT_TOKEN (root token, cf. vault-cluster/)}"

echo "==> 1. Auth Kubernetes"
vault auth enable kubernetes 2>/dev/null || echo "   (auth/kubernetes déjà activé)"
# Vault étant in-cluster, il joint l'API via l'adresse de service interne et utilise le
# token/CA montés dans son pod + son SA délégateur (chart vault : authDelegator activé).
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" >/dev/null
echo "   auth/kubernetes configuré (host=https://kubernetes.default.svc)"

echo "==> 2. Moteur KV-v2 ${MOUNT}/"
vault secrets enable -path="${MOUNT}" -version=2 kv 2>/dev/null \
  || echo "   (moteur ${MOUNT}/ déjà activé)"

echo "==> 3. Secrets de démo (un sous-dossier par appli)"
# Convention : ${MOUNT}/<appli>/<clé-logique>. Ici l'appli nginx-test-vault.
vault kv put "${MOUNT}/nginx-test-vault/config" \
  APP_GREETING="Bonjour depuis Vault" \
  APP_COLOR="blue" \
  APP_SECRET_TOKEN="s3cr3t-v1" >/dev/null
echo "   ${MOUNT}/nginx-test-vault/config écrit"

echo "==> 4. Policy (lecture du sous-dossier nginx-test-vault uniquement)"
# La policy versionnée porte le mount NEUTRE `lab-kv` : substitué à la volée, la policy
# est donc nommée et scopée sur le mount réel du profil.
sed "s/lab-kv/${MOUNT}/g" "$HERE/policies/lab-kv-nginx-test-vault.hcl" \
  | vault policy write "${MOUNT}-nginx-test-vault" -

echo "==> 5. Role auth/kubernetes 'nginx-test-vault' -> SA nginx-test-vault / ns nginx-test-vault"
# bound_service_account_* = QUI peut se logger (identité exacte du pod applicatif).
# audience "vault" DOIT matcher VaultAuth.spec.kubernetes.audiences côté K8s.
vault write auth/kubernetes/role/nginx-test-vault \
  bound_service_account_names="nginx-test-vault" \
  bound_service_account_namespaces="nginx-test-vault" \
  audience="vault" \
  token_policies="${MOUNT}-nginx-test-vault" \
  token_ttl="15m" >/dev/null

echo "==> OK. Vérifs :"
echo "   vault kv get ${MOUNT}/nginx-test-vault/config"
echo "   vault read auth/kubernetes/role/nginx-test-vault"
