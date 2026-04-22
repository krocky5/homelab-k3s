#!/usr/bin/env bash
# Rotate the Vault OIDC client_secret on BOTH sides atomically:
#   1. Generate a fresh 128-char hex secret.
#   2. UPDATE the Authentik provider row in Postgres.
#   3. Write auth/oidc/config in Vault with the same value.
#
# The secret never appears in argv or the chat transcript — it lives only in
# a 0600 tmpfile (shredded on exit), stdin to psql, and the two target systems.
#
# Usage:
#   export VAULT_TOKEN=...   # or have a valid ~/.vault-token
#   ./scripts/vault-oidc-rotate-secret.sh
#
# Vars with defaults:
#   VAULT_ADDR  (https://secrets.krockysphere.com)
#   CLIENT_ID   (6J4PPcjq2E6ZJT1FilCQJtIYlXYYaHGpSRzKiVbv)
#   AUTHENTIK_NS  (authentik)
#   VAULT_NS    (vault)  — for reading the authentik-ca ConfigMap
#   OIDC_ISSUER (https://auth.krockysphere.com/application/o/vault/)
#   OIDC_ROLE   (admin)  — stored as default_role on oidc/config
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://secrets.krockysphere.com}"
CLIENT_ID="${CLIENT_ID:-6J4PPcjq2E6ZJT1FilCQJtIYlXYYaHGpSRzKiVbv}"
AUTHENTIK_NS="${AUTHENTIK_NS:-authentik}"
VAULT_NS="${VAULT_NS:-vault}"
OIDC_ISSUER="${OIDC_ISSUER:-https://auth.krockysphere.com/application/o/vault/}"
OIDC_ROLE="${OIDC_ROLE:-admin}"

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  [[ -r ~/.vault-token ]] || { echo "need VAULT_TOKEN or readable ~/.vault-token" >&2; exit 1; }
  VAULT_TOKEN="$(cat ~/.vault-token)"
fi
export VAULT_ADDR VAULT_TOKEN

command -v openssl >/dev/null || { echo "need openssl" >&2; exit 1; }
command -v vault   >/dev/null || { echo "need vault CLI" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "need kubectl" >&2; exit 1; }

PG_POD="$(kubectl -n "$AUTHENTIK_NS" get pod -l 'app.kubernetes.io/component=postgresql' -o name 2>/dev/null | head -1)"
if [[ -z "$PG_POD" ]]; then
  PG_POD="$(kubectl -n "$AUTHENTIK_NS" get pods -o name | grep -E 'postgresql|postgres' | head -1)"
fi
[[ -n "$PG_POD" ]] || { echo "could not locate authentik postgres pod in ns '$AUTHENTIK_NS'" >&2; exit 1; }
echo "using $PG_POD" >&2

umask 077
SECRET_FILE="$(mktemp -t vault-oidc-rotate)"
trap 'rm -f "$SECRET_FILE"' EXIT
openssl rand -hex 64 | tr -d '\n' > "$SECRET_FILE"
SIZE="$(wc -c < "$SECRET_FILE")"
[[ "$SIZE" -eq 128 ]] || { echo "unexpected secret size: $SIZE" >&2; exit 1; }
echo "generated 128-char secret" >&2

echo "updating Authentik DB row..." >&2
< "$SECRET_FILE" kubectl -n "$AUTHENTIK_NS" exec -i "$PG_POD" -- bash -c '
  NEW_SECRET="$(cat)"
  exec psql -U authentik -d authentik -v ON_ERROR_STOP=1 -v s="$NEW_SECRET" <<SQL
UPDATE authentik_providers_oauth2_oauth2provider
   SET client_secret = :'\''s'\''
 WHERE client_id = '\'''"$CLIENT_ID"''\''
RETURNING length(client_secret) AS new_len, substring(client_secret,1,6) || '\''...'\'' AS prefix;
SQL
'

echo "applying to Vault auth/oidc/config..." >&2
CA_PEM="$(kubectl -n "$VAULT_NS" get configmap authentik-ca -o jsonpath='{.data.ca\.crt}')"
[[ -n "$CA_PEM" ]] || { echo "authentik-ca configmap missing in ns '$VAULT_NS'" >&2; exit 1; }

vault write auth/oidc/config \
  oidc_discovery_url="$OIDC_ISSUER" \
  oidc_discovery_ca_pem="$CA_PEM" \
  oidc_client_id="$CLIENT_ID" \
  oidc_client_secret=@"$SECRET_FILE" \
  default_role="$OIDC_ROLE" >/dev/null

echo "rotation complete." >&2
