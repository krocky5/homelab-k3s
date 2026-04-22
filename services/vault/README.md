# vault/

HashiCorp Vault at `secrets.krockysphere.com`, authenticated via Authentik OIDC, with group-based RBAC binding `homelab-admin` / `homelab-user` to Vault policies.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml`   | Namespace `vault`. |
| `deployment.yaml`  | Vault server pod; mounts Authentik CA at `/vault/tls/ca.crt`. |
| `configmap.yaml`   | Vault server config (storage backend, listener). |
| `serviceaccount.yaml` | SA for the pod. |
| `service.yaml`     | ClusterIP on :8200. |
| `ingress.yaml`     | TLS ingress at `secrets.krockysphere.com`. |
| `pvc.yaml`         | 10Gi storage for Vault data. |
| `authentik-ca-configmap.yaml` | Authentik's self-signed CA, mounted so Vault can verify TLS during OIDC discovery. |

## Unsealing

Vault starts **sealed** after any pod restart. It needs 3 of 5 Shamir unseal keys before it will serve requests.

```bash
kubectl -n vault exec -it <vault-pod> -- vault operator unseal
# paste key 1, repeat for keys 2 and 3
```

Sealed status:

```bash
kubectl -n vault exec <vault-pod> -- vault status | grep -i sealed
```

No auto-unseal is configured — this is a deliberate homelab choice to avoid stashing unseal keys in a cloud KMS.

## Root tokens

The original `vault operator init` root token was not retained. Generate a fresh one from any 3 unseal keys:

```bash
./scripts/vault-regen-root.sh
```

It writes the new token to `~/.vault-token`. Subsequent `vault` CLI calls pick it up automatically. The script also auto-revokes any stale root tokens left over from earlier runs.

## Authentication — Authentik OIDC

Users log in via `https://secrets.krockysphere.com/ui/auth/oidc` → redirects to Authentik → back with an id-token containing a `groups` claim → Vault matches groups to external-group aliases → applies the bound policy.

### Config at a glance

- OIDC app in Authentik: slug `vault`, confidential client, scopes include `openid profile groups`.
- Vault mount: `auth/oidc/` with role `admin` (misnomer — it's the default role for ALL logins; policy assignment is via group, not this role).
- Role config:
  - `user_claim=preferred_username` → alias name becomes e.g. `krocky5` (not an opaque UUID).
  - `groups_claim=groups`.
  - `oidc_scopes=openid,profile,groups`.
  - **`token_policies=""` (must stay empty)** — policies come from group binding, not from the role.

### Why `token_policies` MUST be empty

`token_policies` is applied to every OIDC login regardless of group membership. If set to `admin` (which has `path "*"` with sudo), every user gets full root — breaking the whole RBAC scheme. This bit us once; guard against it by only setting the role via `scripts/vault-homelab-rbac.sh`, which hard-codes `token_policies=""`.

## RBAC

Two policies map to two Authentik groups via Vault external groups:

| Authentik group | Vault policy    | Grants |
|-----------------|-----------------|--------|
| `homelab-admin` | `homelab-admin` | `path "*"` with all capabilities incl. `sudo` — root-equivalent. |
| `homelab-user`  | `homelab-user`  | CRUD on `secret/user/<their-username>/*` only. Nothing else. |

Policy files live at `scripts/vault-policies/*.hcl`. The `homelab-user.hcl` uses Vault identity templating (`{{identity.entity.aliases.__OIDC_ACCESSOR__.name}}`) so paths resolve per-user at login time. The `__OIDC_ACCESSOR__` placeholder is substituted by `vault-homelab-rbac.sh` with the live `auth/oidc/` mount accessor.

## `default` policy — keep minimal

Vault auto-attaches the `default` policy to every non-root token. It's tracked at `scripts/vault-policies/default.hcl` and grants only self-token management + cubbyhole. **Do not add `secret/` paths here** — anything here leaks to every user.

## Scripts

All in `scripts/` at repo root. See [`scripts/README.md`](../../scripts/README.md) for details.

- `vault-regen-root.sh` — regenerate a root token from 3 unseal keys; auto-revokes stale roots.
- `vault-homelab-rbac.sh` — apply policies + role + external-group aliases. Idempotent.
- `vault-authentik-oidc.sh` — refresh `auth/oidc/config` (when Authentik's client_secret or CA rotates).
- `vault-oidc-rotate-secret.sh` — atomic secret rotation: writes a new 128-char hex secret to both Authentik's Postgres row AND Vault's `auth/oidc/config` without exposing it in argv.

## Emergency access

If OIDC is broken (Authentik down, misconfigured provider, etc.):

1. `./scripts/vault-regen-root.sh` — still works; uses local unseal keys, no Authentik dependency.
2. Use the resulting root token to fix whatever's broken.
3. Revoke extra root tokens when done.

If unseal keys are lost, Vault's data is unrecoverable. Keep copies in ≥3 separate trusted locations.

## Common operations

```bash
export VAULT_ADDR=https://secrets.krockysphere.com
export VAULT_TOKEN="$(cat ~/.vault-token)"

# What policies does my token have?
vault token lookup | grep -i polic

# What's in my personal namespace?
vault kv list "secret/user/$(whoami)/"
vault kv put  "secret/user/$(whoami)/my-api-key" value=abc123
vault kv get  "secret/user/$(whoami)/my-api-key"

# Verify the OIDC role is still correctly configured
vault read auth/oidc/role/admin | grep -E 'user_claim|groups_claim|token_policies|oidc_scopes'

# List all external groups + their bindings
vault list identity/group-alias/id
```

## Sharing secrets with homelab-user accounts

Default `homelab-user` policy grants no shared reads. To opt in:

1. Edit `scripts/vault-policies/homelab-user.hcl` and uncomment the `secret/.../shared/*` blocks.
2. Move the secrets you want shared under `secret/shared/...`.
3. Run `./scripts/vault-homelab-rbac.sh` to re-apply the policy.
4. Users see the new paths on their next login.
