#!/usr/bin/env bash
# Refresh Vault's auth/oidc/config from Authentik.
#
# Use this when:
#   - The Authentik client_secret was rotated (or the Provider was re-saved
#     and the stored secret diverged).
#   - The Authentik CA PEM changed.
#
# This script intentionally does NOT touch auth/oidc/role/* — role config
# (allowed_redirect_uris, oidc_scopes, groups_claim, ...) is managed by
# scripts/vault-homelab-rbac.sh. Writing a role with a subset of fields
# wipes the rest (full-replace endpoint).
#
# Usage:
#   VAULT_TOKEN=<root-or-admin-token> \
#   OIDC_CLIENT_ID=<authentik-client-id> \
#   OIDC_CLIENT_SECRET=<authentik-client-secret> \
#   OIDC_ROLE=<default-role-name>  # typically "admin" \
#   ./scripts/vault-authentik-oidc.sh
#
# OIDC_ISSUER and VAULT_ADDR have sane defaults below.
set -euo pipefail

: "${VAULT_TOKEN:?need VAULT_TOKEN}"
: "${OIDC_CLIENT_ID:?need OIDC_CLIENT_ID}"
: "${OIDC_CLIENT_SECRET:?need OIDC_CLIENT_SECRET}"
: "${OIDC_ROLE:?need OIDC_ROLE (run: vault list auth/oidc/role)}"

VAULT_ADDR="${VAULT_ADDR:-https://secrets.krockysphere.com}"
OIDC_ISSUER="${OIDC_ISSUER:-https://auth.krockysphere.com/application/o/vault/}"
export VAULT_ADDR VAULT_TOKEN

CA_PEM="$(kubectl -n vault get configmap authentik-ca -o jsonpath='{.data.ca\.crt}')"
if [[ -z "$CA_PEM" ]]; then
  echo "failed to read authentik-ca configmap from vault namespace" >&2
  exit 1
fi

echo "Current oidc/config:" >&2
vault read auth/oidc/config || true

echo "Updating auth/oidc/config..." >&2
vault write auth/oidc/config \
  oidc_discovery_url="$OIDC_ISSUER" \
  oidc_discovery_ca_pem="$CA_PEM" \
  oidc_client_id="$OIDC_CLIENT_ID" \
  oidc_client_secret="$OIDC_CLIENT_SECRET" \
  default_role="$OIDC_ROLE"

echo "Done. Try logging in via OIDC at ${VAULT_ADDR}/ui/" >&2
echo "If role fields need updating, run scripts/vault-homelab-rbac.sh" >&2
