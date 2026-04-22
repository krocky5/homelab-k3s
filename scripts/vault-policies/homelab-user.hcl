# Each homelab-user gets a private namespace at `secret/user/<their-username>/*`
# where <their-username> is the Authentik `preferred_username` claim (e.g. "krocky5").
#
# The __OIDC_ACCESSOR__ placeholder is substituted at apply time by
# scripts/vault-homelab-rbac.sh with the current `auth/oidc/` mount accessor
# (looks like `auth_oidc_XXXXXXXX`). This must be regenerated if the OIDC
# mount is ever disabled + re-enabled.
#
# Users navigate directly to `secret/user/<their-username>/` in the UI — they
# cannot list the parent `secret/user/` (which would reveal other usernames).

path "secret/data/user/{{identity.entity.aliases.__OIDC_ACCESSOR__.name}}/*" {
  capabilities = ["create", "read", "update", "delete", "list", "patch"]
}
path "secret/metadata/user/{{identity.entity.aliases.__OIDC_ACCESSOR__.name}}/*" {
  capabilities = ["read", "list", "delete"]
}

# Optional shared-secrets area — uncomment to let every homelab-user READ
# anything you place under `secret/shared/...`.
#
# path "secret/data/shared/*" {
#   capabilities = ["read"]
# }
# path "secret/metadata/shared/*" {
#   capabilities = ["read", "list"]
# }
