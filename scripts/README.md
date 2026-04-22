# scripts/

Operational scripts. Each is idempotent and safe to re-run.

## Index

| Script | What it does | When to run |
|--------|--------------|-------------|
| `deploy-argocd-apps.sh` | Applies every `Application` manifest under `argocd/apps/`. | Bootstrap; after adding a new app manifest. |
| `vault-regen-root.sh` | Generates a fresh Vault root token from 3 Shamir unseal keys; writes to `~/.vault-token`; auto-revokes stale roots. | When you need root (e.g. recovery, policy changes, OIDC fixes). |
| `vault-authentik-oidc.sh` | Refreshes Vault's `auth/oidc/config` (discovery URL, CA PEM, client_id, client_secret, default role). | After rotating the Authentik client_secret or the Authentik TLS CA. |
| `vault-homelab-rbac.sh` | Writes `default`, `homelab-admin`, `homelab-user` policies; patches the OIDC role with `groups_claim`/`user_claim=preferred_username`/`token_policies=""`; creates external-group aliases. | First-time RBAC setup; after editing anything under `scripts/vault-policies/`. |
| `vault-oidc-rotate-secret.sh` | Rotates Vault OIDC `client_secret` on both sides atomically — writes a fresh 128-char hex to the Authentik Postgres row AND `vault auth/oidc/config`. | Any time you want to rotate; after a suspected secret compromise. |

## Vault script order (from a clean state)

```bash
# 1. Root token
./scripts/vault-regen-root.sh

# 2. Set Authentik OIDC config (requires client_secret from Authentik UI)
VAULT_TOKEN="$(cat ~/.vault-token)" \
  OIDC_CLIENT_ID=<id> \
  OIDC_CLIENT_SECRET=<secret> \
  OIDC_ROLE=admin \
  ./scripts/vault-authentik-oidc.sh

# 3. Apply RBAC (policies, role patch, external groups)
./scripts/vault-homelab-rbac.sh
```

Thereafter, the only one you typically touch is `vault-oidc-rotate-secret.sh` (for rotations) or re-running `vault-homelab-rbac.sh` after editing a policy HCL file.

## Why the Vault scripts are split

Vault's `auth/oidc/config` and `auth/oidc/role/*` endpoints are both **full-replace on write, not merge**, and `vault patch` returns 405 for them. That means any script touching one of those endpoints must know every field to avoid silently erasing settings. Splitting by concern keeps each script's "known fields" small and auditable:

- `vault-authentik-oidc.sh` owns `auth/oidc/config` only (never writes to roles).
- `vault-homelab-rbac.sh` owns `auth/oidc/role/<name>` + policies + group aliases (never writes to config).
- `vault-oidc-rotate-secret.sh` touches both `auth/oidc/config` (on the Vault side) and the Authentik Postgres row (on the Authentik side).

## `scripts/vault-policies/`

HCL policy sources consumed by `vault-homelab-rbac.sh`:

| File | Applied as |
|------|-----------|
| `default.hcl`       | Vault's `default` policy (auto-attached to every non-root token). Kept minimal — no `secret/` paths. |
| `homelab-admin.hcl` | `path "*"` with all capabilities incl. sudo. Bound to Authentik group `homelab-admin`. |
| `homelab-user.hcl`  | Per-user namespace via identity templating. Contains `__OIDC_ACCESSOR__` placeholder substituted at apply time. |

Edit the HCL, re-run `./scripts/vault-homelab-rbac.sh`. Changes apply on users' next login (existing tokens are not retroactively updated).
