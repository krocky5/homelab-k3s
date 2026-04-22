#!/usr/bin/env bash
# Configure Vault RBAC for homelab users via Authentik OIDC group claims.
#
# Creates two policies (homelab-admin, homelab-user), updates the OIDC role
# to emit the `groups` claim, and binds Authentik groups of those names to
# the matching policies via Vault external groups.
#
# Prereqs in Authentik (UI):
#   1. Groups `homelab-admin` and `homelab-user` exist, with users assigned.
#   2. The Vault provider's scopes include the built-in
#      "authentik default OAuth Mapping: OpenID 'groups'" scope mapping.
#
# Usage:
#   VAULT_TOKEN=<root-or-admin> ./scripts/vault-homelab-rbac.sh
#
# Vars with defaults:
#   VAULT_ADDR (https://secrets.krockysphere.com)
#   OIDC_ROLE  (admin) — the OIDC role name used for login
set -euo pipefail

: "${VAULT_TOKEN:?need VAULT_TOKEN}"
command -v jq    >/dev/null || { echo "need jq"    >&2; exit 1; }
command -v vault >/dev/null || { echo "need vault CLI" >&2; exit 1; }

VAULT_ADDR="${VAULT_ADDR:-https://secrets.krockysphere.com}"
OIDC_ROLE="${OIDC_ROLE:-admin}"
export VAULT_ADDR VAULT_TOKEN

POLICY_DIR="$(cd "$(dirname "$0")/vault-policies" && pwd)"

echo "==> Fetching oidc/ mount accessor" >&2
ACCESSOR="$(vault auth list -format=json | jq -r '."oidc/".accessor // empty')"
if [[ -z "$ACCESSOR" ]]; then
  echo "ERROR: oidc auth method is not mounted at auth/oidc/" >&2
  exit 1
fi
echo "    accessor=$ACCESSOR" >&2

echo "==> Writing policies from $POLICY_DIR" >&2
vault policy write default       "$POLICY_DIR/default.hcl"
vault policy write homelab-admin "$POLICY_DIR/homelab-admin.hcl"
# homelab-user.hcl contains the __OIDC_ACCESSOR__ placeholder; substitute it
# with the live mount accessor before applying.
HOMELAB_USER_HCL="$(sed "s/__OIDC_ACCESSOR__/$ACCESSOR/g" "$POLICY_DIR/homelab-user.hcl")"
echo "$HOMELAB_USER_HCL" | vault policy write homelab-user -

echo "==> Reading current OIDC role '$OIDC_ROLE' to preserve its fields" >&2
CURRENT_JSON="$(vault read -format=json "auth/oidc/role/$OIDC_ROLE")"

get_csv() { echo "$CURRENT_JSON" | jq -r ".data.$1 | if (. == null or . == []) then empty else join(\",\") end"; }

REDIRECTS="$(get_csv allowed_redirect_uris)"
BOUND_AUD="$(get_csv bound_audiences)"

if [[ -z "$REDIRECTS" ]]; then
  echo "ERROR: auth/oidc/role/$OIDC_ROLE has no allowed_redirect_uris — refusing to overwrite" >&2
  exit 1
fi

# user_claim is pinned to `preferred_username` so entity aliases are human-
# readable (e.g. "krocky5") and the identity-templated homelab-user policy
# resolves to paths like `secret/user/krocky5/*` instead of an opaque UUID.
#
# token_policies is DELIBERATELY cleared. With group-based RBAC every OIDC
# login should get policies ONLY from the matching external group plus the
# `default` policy — NEVER from the role's token_policies list.
echo "==> Patching OIDC role (user_claim=preferred_username, token_policies cleared)" >&2
ROLE_ARGS=(
  "auth/oidc/role/$OIDC_ROLE"
  "user_claim=preferred_username"
  "oidc_scopes=openid,profile,groups"
  "groups_claim=groups"
  "allowed_redirect_uris=$REDIRECTS"
  "token_policies="
)
[[ -n "$BOUND_AUD" ]] && ROLE_ARGS+=("bound_audiences=$BOUND_AUD")
vault write "${ROLE_ARGS[@]}" >/dev/null

bind_group() {
  local GNAME="$1" POLICY="$2"
  echo "==> External group '$GNAME' -> policy '$POLICY'" >&2

  local GID GDATA ALIAS_ID
  if GDATA="$(vault read -format=json "identity/group/name/$GNAME" 2>/dev/null)"; then
    GID="$(echo "$GDATA" | jq -r '.data.id')"
    vault write "identity/group/id/$GID" \
      name="$GNAME" type="external" policies="$POLICY" >/dev/null
    ALIAS_ID="$(echo "$GDATA" | jq -r '.data.alias.id // empty')"
  else
    vault write identity/group \
      name="$GNAME" type="external" policies="$POLICY" >/dev/null
    GID="$(vault read -field=id "identity/group/name/$GNAME")"
    ALIAS_ID=""
  fi

  if [[ -n "$ALIAS_ID" ]]; then
    vault write "identity/group-alias/id/$ALIAS_ID" \
      name="$GNAME" mount_accessor="$ACCESSOR" canonical_id="$GID" >/dev/null
  else
    vault write identity/group-alias \
      name="$GNAME" mount_accessor="$ACCESSOR" canonical_id="$GID" >/dev/null
  fi
  echo "    group_id=$GID" >&2
}

bind_group "homelab-admin" "homelab-admin"
bind_group "homelab-user"  "homelab-user"

cat >&2 <<EOF

Done.

Next:
  1. In Authentik, put yourself in the 'homelab-admin' group, others in 'homelab-user'.
  2. Log OUT of Vault and log back in via OIDC.
  3. Verify:
       vault token lookup               # token_policies should include homelab-admin|user
       vault list identity/group-alias/id

Note: Vault resolves external-group membership at login time from the id-token's
\`groups\` claim. Changes in Authentik group membership take effect on next login,
not retroactively on existing Vault tokens.
EOF
