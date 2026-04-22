# Full administrator — equivalent to root on this Vault instance.
# Do not widen further; do not narrow without a plan for replacing break-glass capabilities.
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "patch", "sudo"]
}
