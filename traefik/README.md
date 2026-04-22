# traefik/

Customises the Traefik that ships with k3s. k3s reads `HelmChartConfig` resources and merges them into the bundled Traefik Helm release, so we don't install our own.

## Files

| File | Purpose |
|------|---------|
| `traefik-config.yaml` | `HelmChartConfig` in `kube-system` — applies `values.yaml` to the k3s-bundled Traefik release. |
| `values.yaml`         | Traefik Helm values: ACME (Let's Encrypt) with Cloudflare DNS-01 challenge, persistence for `/data/acme.json`, HTTP→HTTPS redirect. |

## Apply

```bash
kubectl apply -f traefik/traefik-config.yaml
```

k3s reconciles the change and rolls the Traefik pod. No standalone `helm` required.

## TLS / ACME

Certificates are issued via Cloudflare DNS-01 (not HTTP-01), so you don't need an open port 80. Required secrets:

```bash
# Cloudflare API token with Zone:DNS:Edit on the homelab zone
kubectl -n kube-system create secret generic cloudflare-api-token \
  --from-literal=CLOUDFLARE_API_TOKEN='<token>'

# ACME registration email
kubectl -n kube-system create secret generic traefik-acme-email \
  --from-literal=ACME_EMAIL='you@example.com'
```

Certs are stored in `/data/acme.json` on the Traefik pod's PVC. Losing the PVC means re-issuing (watch for Let's Encrypt rate limits).

## Forward-auth middleware

The Authentik middleware is defined in `services/authentik/middleware.yaml`, not here. Ingresses reference it via annotation:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: authentik-authentik-forwardauth@kubernetescrd
```

Or the cookie-preserving variant:

```yaml
... authentik-authentik-forwardauth-with-cookies@kubernetescrd
```

## Traefik dashboard

The dashboard is exposed at `traefik.krockysphere.com` via `services/traefik/traefik-dashboard.yaml` (a Traefik `IngressRoute`, not a standard `Ingress`). It's unauthenticated — assumption is LAN-only access. If it needs to go public, wrap it in the Authentik forward-auth middleware.

## Debugging

```bash
# Traefik pod logs (acme errors, routing, middleware hits)
kubectl -n kube-system logs -l app.kubernetes.io/name=traefik -f

# Confirm a host is routing
kubectl -n kube-system exec deploy/traefik -- \
  wget -qO- localhost:9000/api/http/routers | jq '.[] | select(.rule | contains("krockysphere"))'
```
