# authentik/

Self-hosted OpenID Connect identity provider + policy engine. Everything else in this cluster authenticates through it.

## Components

| Pod | Role |
|-----|------|
| `authentik-server`  | HTTP server + OIDC endpoints + admin UI. |
| `authentik-worker`  | Runs background flows, policy evaluation, notifications. |
| `authentik-postgresql` | State — users, groups, providers, tokens. 10Gi PVC. |
| `authentik-redis`   | Cache and task queue. |

All live in namespace `authentik`.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml`  | Namespace. |
| `deployment.yaml` / `worker.yaml` | The two Authentik pods. |
| `postgres.yaml` / `redis.yaml`    | Database + cache. |
| `service.yaml`    | ClusterIP for the server. |
| `ingress.yaml`    | Exposes `auth.krockysphere.com` via Traefik. |
| `middleware.yaml` | Two Traefik forward-auth middlewares consumed by other services' ingresses. |

## Forward-auth middleware

Every protected service's ingress references one of these:

- `authentik-authentik-forwardauth@kubernetescrd` — base.
- `authentik-authentik-forwardauth-with-cookies@kubernetescrd` — preserves cookies for apps that read `X-authentik-*` headers.

These are defined in `middleware.yaml`; point new services at them via ingress annotation:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: authentik-authentik-forwardauth-with-cookies@kubernetescrd
```

## OIDC providers

Services that speak OIDC natively (ArgoCD, Grafana, Vault, Homarr v1, Windmill) each have a dedicated **Provider** in the Authentik admin UI. For each:

1. **Create Provider** (Applications → Providers → OAuth2/OIDC).
2. **Create Application** linked to the Provider, with a slug that appears in the issuer URL: `https://auth.krockysphere.com/application/o/<slug>/`.
3. **Note the Client ID and Client Secret** — only the secret is shown once; copy it into a Sealed Secret alongside the service.
4. **Add scope mappings** — `openid`, `profile`, `email` are default. Add the `groups` scope (built-in or custom) to emit group membership in the id-token.

## Groups

Two groups drive RBAC in downstream services:

| Group | Used by |
|-------|---------|
| `homelab-admin` | Vault (full admin policy), Grafana (Admin role), ArgoCD (admin). |
| `homelab-user`  | Vault (per-user private namespace), Grafana (Editor/Viewer). |

Group claim arrives in id-tokens as the `groups` array when the groups scope is included. Vault binds these via external-group aliases (see `services/vault/README.md`).

## Self-signed TLS / CA distribution

Authentik serves TLS with a self-signed cert stored in secret `authentik/authentik-tls` (expires 2036-04-18). Services that call `auth.krockysphere.com` over HTTPS for OIDC token exchange need this CA in their trust store.

The CA is replicated to each consumer's namespace as a ConfigMap named `authentik-ca`:

```text
services/homarr-v1/authentik-ca-configmap.yaml
services/vault/authentik-ca-configmap.yaml
services/windmill/authentik-ca-configmap.yaml
```

Each copy has the same `ca.crt` content. When the cert rotates, rewrite all three ConfigMaps from the new `authentik-tls` secret:

```bash
CA=$(kubectl -n authentik get secret authentik-tls -o jsonpath='{.data.tls\.crt}' | base64 -d)
for ns in homarr-v1 vault windmill; do
  kubectl -n "$ns" create configmap authentik-ca \
    --from-literal=ca.crt="$CA" \
    --dry-run=client -o yaml > /tmp/auca.yaml
  # edit metadata.name, commit as services/<ns>/authentik-ca-configmap.yaml
done
```

## Database access

For diagnostics, direct psql into the Authentik DB:

```bash
kubectl -n authentik exec -it authentik-postgresql-<hash> -- \
  psql -U authentik -d authentik
```

Key tables:

| Table | What it holds |
|-------|---------------|
| `authentik_core_user` | Users, emails, `uuid` (used as `sub` claim by default). |
| `authentik_core_group` | Groups (`homelab-admin`, `homelab-user`, ...). |
| `authentik_core_user_ak_groups` | User↔group mapping. |
| `authentik_providers_oauth2_oauth2provider` | OIDC clients — `client_id`, `client_secret`, `redirect_uris`. |
| `authentik_core_propertymapping` + `..._scopemapping` | Scope → claim mappings. |
| `authentik_core_provider_property_mappings` | Which scope mappings attach to which provider. |

Rotating a client_secret directly in this table is supported (e.g. `scripts/vault-oidc-rotate-secret.sh` does this for the Vault provider).

## Common operations

```bash
# Find a user's UUID (used as sub by default)
kubectl -n authentik exec authentik-postgresql-<hash> -- \
  psql -U authentik -d authentik -c \
  "SELECT username, uuid FROM authentik_core_user WHERE username='alice';"

# List providers and their client_ids
kubectl -n authentik exec authentik-postgresql-<hash> -- \
  psql -U authentik -d authentik -c \
  "SELECT cp.name, p.client_id, p.client_type FROM authentik_providers_oauth2_oauth2provider p JOIN authentik_core_provider cp ON cp.id=p.provider_ptr_id;"

# Tail server logs (login errors, policy denials)
kubectl -n authentik logs -l app.kubernetes.io/component=server -f --tail=200
```

See also: [`services/vault/README.md`](../vault/README.md) for how Vault consumes Authentik groups.
