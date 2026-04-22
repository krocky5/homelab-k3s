# Vault's `default` policy is auto-attached to every non-root token, including
# every OIDC login. Keep it MINIMAL — anything broader here leaks to every user.
#
# Per-team access must come from the homelab-admin / homelab-user policies
# bound via external groups, never from here.

# Self-token management (what a user needs to keep their session alive).
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self"  { capabilities = ["update"] }
path "auth/token/revoke-self" { capabilities = ["update"] }

# Capability introspection — lets users see what they're allowed to do.
path "sys/capabilities-self"          { capabilities = ["update"] }
path "sys/internal/ui/resultant-acl"  { capabilities = ["read"] }

# Private per-token scratch space (only the holder of the token can read it).
path "cubbyhole/*" { capabilities = ["create", "read", "update", "delete", "list"] }
