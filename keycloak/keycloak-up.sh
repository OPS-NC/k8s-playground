#!/usr/bin/env bash
#
# keycloak-up.sh — installs Keycloak through its OPERATOR (the `Keycloak` CRD), with a
# CloudNativePG PostgreSQL database, and exposes the console + the OIDC endpoints over HTTPS
# at keycloak.$LAB_DOMAIN through main-gateway.
#
#   ./keycloak/keycloak-up.sh <talos|kubeadm>   (or ./install.sh <distro> keycloak)
#
# Standalone add-on: platform-up.sh only lays down the CNI + Envoy + metrics + wildcard TLS.
#
# WHY THE OPERATOR AND NOT A CHART. The Bitnami chart deploys a StatefulSet and leaves you
# with: keystore generation, proxy options, schema migration on every version bump, the
# Infinispan cache. The operator takes a thirty-line `Keycloak` object and derives all of it —
# and it delivers the promise that matters here: a DECLARED realm (`KeycloakRealmImport`) you
# can version, therefore reproduce. It is also what lets `../dex/` declare its OIDC client
# with a CR instead of a `kcadm.sh` script.
#
# Order:
#   1. namespace + CNPG PostgreSQL database  (Keycloak does not start without a database)
#   2. Keycloak operator                     (4 CRDs + RBAC + Deployment)
#   3. Keycloak CR                           (the operator derives StatefulSet + Service)
#   4. `lab` realm                           (KeycloakRealmImport CRD)
#   5. HTTPRoute keycloak.$LAB_DOMAIN
#
# No distribution-specific behaviour: the pods are ordinary (no hostPath, no hostNetwork, no
# privilege), hence compliant with the `baseline` level Talos enforces cluster-wide — the
# namespace does not need a `privileged` label.
#
# Prerequisites: platform in place (HTTPS main-gateway + wildcard), Longhorn (SC
#                `longhorn-r1`), the CloudNativePG operator, openssl.
# Idempotent: `kubectl apply` everywhere, and the demo password Secret is only generated when
# it does not exist. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${HERE}/../lib/common.sh"
k8s_init "$@"

# --- Pinned version (overridable through an environment variable) ------------
# One version for everything: the operator manifests carry the server image
# (`RELATED_IMAGE_KEYCLOAK`), so operator and server move together.
KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-26.7.0}"
NS="${NS:-keycloak}"
BASE_URL="https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes"

# --- Prerequisites ----------------------------------------------------------
need kubectl openssl
require_apiserver
# The database lives on this repository's base StorageClass for databases.
require_sc longhorn-r1
# The CloudNativePG operator is a separate component: without it the `Cluster` laid down below
# is an inert object nobody reconciles, and Keycloak waits for a database that never arrives.
kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 \
  || fail "the CloudNativePG operator is missing (CRD clusters.postgresql.cnpg.io).
        Install it first:  ./install.sh ${K8S_DISTRO} cnpg"

# ============================================================================
log "[1/5] Namespace ${NS} + CloudNativePG PostgreSQL database"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${HERE}/01-postgres.yaml"
echo "    waiting for the keycloak-db cluster (initdb + first start)..."
kubectl -n "$NS" wait --for=condition=Ready cluster/keycloak-db --timeout=300s

# ============================================================================
log "[2/5] Keycloak operator ${KEYCLOAK_VERSION} (CRDs + RBAC + Deployment)"
# `--server-side` is NOT a nicety: the `keycloaks` CRD is over 500 KiB, and a plain
# `kubectl apply` copies it into the `kubectl.kubernetes.io/last-applied-configuration`
# annotation — capped at 262,144 bytes by the apiserver. A client-side apply therefore fails
# with "metadata.annotations: Too long". A server-side apply does not write that annotation.
for crd in keycloaks keycloakrealmimports keycloakoidcclients keycloaksamlclients; do
  kubectl apply --server-side -f "${BASE_URL}/${crd}.k8s.keycloak.org-v1.yml"
done
# All four CRDs are applied even though this component only uses two: the operator starts one
# controller per CRD and its informer crashes in a loop if one of them is missing.
kubectl wait --for=condition=Established crd/keycloaks.k8s.keycloak.org --timeout=60s

# `kubernetes.yml` sets no namespace on its namespaced objects, but its ClusterRoleBinding
# names the `keycloak-operator` ServiceAccount of the `keycloak` namespace VERBATIM:
# installing the operator anywhere else would leave it with no permissions.
kubectl apply -n "$NS" -f "${BASE_URL}/kubernetes.yml"
kubectl -n "$NS" rollout status deploy/keycloak-operator --timeout=300s

# ============================================================================
log "[3/5] Keycloak CR (the operator derives the StatefulSet, Service and configuration)"
# The versioned manifest carries the neutral domain: substituted on the fly, as everywhere
# else in k8s-playground/ (see ../README.md).
render "${HERE}/02-keycloak.yaml" | kubectl apply -f -
echo "    waiting for Keycloak (schema migration on first start: ~2 min)..."
# The CR's `Ready` condition only shows up once the StatefulSet has rolled out AND the server
# is reachable. `|| true`: we would rather carry on and let the final summary tell the truth
# than die on a timeout, since the rest is re-runnable anyway.
kubectl -n "$NS" wait --for=condition=Ready keycloak/keycloak --timeout=600s || true

# ============================================================================
log "[4/5] 'lab' realm (KeycloakRealmImport) + demo user"
# The password is generated ONCE and never leaves the cluster. `get || create` and not
# `create --dry-run | apply`: the latter would regenerate the password on every run, while the
# realm has already imported the old one — user `demo` could no longer log in and nothing
# would say so.
if kubectl -n "$NS" get secret keycloak-demo-user >/dev/null 2>&1; then
  echo "    Secret keycloak-demo-user already present — not regenerating it."
else
  kubectl -n "$NS" create secret generic keycloak-demo-user \
    --from-literal=password="$(openssl rand -base64 18)"
  echo "    Secret keycloak-demo-user created (random password, never printed)."
fi
render "${HERE}/03-realm-lab.yaml" | kubectl apply -f -
echo "    waiting for the import job..."
kubectl -n "$NS" wait --for=condition=Done keycloakrealmimport/lab --timeout=300s || true

# ============================================================================
log "[5/5] HTTPRoute keycloak.${LAB_DOMAIN}"
render "${HERE}/httproute.yaml" | kubectl apply -f -

# ============================================================================
log "Keycloak installed."
echo "  Admin console : https://keycloak.${LAB_DOMAIN}/admin/"
echo "  Admin account : kubectl -n ${NS} get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d ; echo"
echo "                  kubectl -n ${NS} get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d ; echo"
echo "  Realm         : lab   —   https://keycloak.${LAB_DOMAIN}/realms/lab"
echo "  Discovery     : curl -s https://keycloak.${LAB_DOMAIN}/realms/lab/.well-known/openid-configuration | jq .issuer"
echo "  User          : demo  (group k8s-admins)"
echo "                  kubectl -n ${NS} get secret keycloak-demo-user -o jsonpath='{.data.password}' | base64 -d ; echo"
echo "  Database      : kubectl -n ${NS} get cluster keycloak-db"
echo
echo "  /!\\ The 'keycloak-initial-admin' account is a FULL admin, in plaintext in a Secret."
echo "      Create your own admin in the master realm, then delete it:"
echo "      kubectl -n ${NS} delete secret keycloak-initial-admin"
echo
echo "  Logical next step: ./install.sh ${K8S_DISTRO} dex   (kubectl login over OIDC)"
