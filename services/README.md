# services/

Each subdirectory is one workload. Every service has its own namespace and its own ArgoCD `Application` in `argocd/apps/`.

## Summary

| Directory        | Namespace     | Hostname                        | Auth                              | Notes |
|------------------|---------------|---------------------------------|-----------------------------------|-------|
| authentik        | authentik     | auth.krockysphere.com           | native                            | OIDC IdP + forward-auth middleware source. |
| vault            | vault         | secrets.krockysphere.com        | Authentik OIDC + group policies   | See `vault/README.md`. |
| grafana          | monitoring    | grafana.krockysphere.com        | Authentik OIDC (generic OAuth)    | Deployed as part of kube-prometheus-stack. |
| jaeger           | monitoring    | jaeger.krockysphere.com         | Authentik forward-auth            | OTLP receiver from otel-collector. |
| otel-collector   | monitoring    | (internal only)                 | —                                 | gRPC :4317, HTTP :4318; forwards to Jaeger. |
| krakend-prod     | krakend-prod  | api.krockysphere.com            | Authentik forward-auth + rate-limit | Configs live in `krakend-configs/prod/`. |
| krakend-dev      | krakend-dev   | api-dev.krockysphere.com        | Authentik forward-auth            | Configs live in `krakend-configs/dev/`. |
| homarr-v1        | homarr-v1     | home.krockysphere.com           | Authentik OIDC                    | Active launcher with OIDC + CA trust. |
| homarr           | homarr        | (inactive)                      | Authentik forward-auth            | Legacy — leave dormant or delete. |
| n8n              | n8n           | automationsv2.krockysphere.com  | Authentik forward-auth            | PostgreSQL-backed; exports traces to OTel. |
| windmill         | windmill      | windmill.krockysphere.com       | Authentik OIDC + forward-auth     | Merges CA bundle for outbound TLS. |
| proxmox          | default       | proxmox.krockysphere.com        | passthrough                       | Proxies to external Proxmox VM (192.168.4.170:8006). |
| traefik          | kube-system   | traefik.krockysphere.com        | none                              | Dashboard `IngressRoute`; LAN-only assumption. |
| test_api         | —             | —                               | —                                 | KrakenD test/reference, not actively deployed. |

## Common patterns

### Authentication

- **OIDC native** — app speaks OIDC directly. Register provider in Authentik, create a Sealed Secret with client_id/client_secret, reference it in the Deployment env. Examples: ArgoCD, Grafana, Vault, Homarr v1, Windmill.
- **Forward-auth** — app doesn't know about auth; Traefik asks Authentik. Attach the middleware via ingress annotation. Examples: n8n, KrakenD, Jaeger.

Ingress snippet for forward-auth (see `examples/n8n-ingress-protected.yaml` for a full file):

```yaml
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: authentik-authentik-forwardauth-with-cookies@kubernetescrd
```

### Self-signed CA trust (outbound to Authentik)

Services that call `auth.krockysphere.com` over HTTPS during login (OIDC code exchange, userinfo) need Authentik's self-signed CA in their trust store. Two patterns in this repo:

- **Init container copy** (Homarr v1, Vault) — mount the `authentik-ca` ConfigMap in an init container, copy the cert into the app's trusted-certs dir.
- **Merged CA bundle** (Windmill) — init container concatenates `/etc/ssl/certs/ca-certificates.crt` and the mounted Authentik cert into a single file; main container gets `SSL_CERT_FILE=<bundle>`.

The CA ConfigMap itself lives in each service's namespace as `<name>/authentik-ca-configmap.yaml`. Source of truth is the `authentik/authentik-tls` secret; manually rotated when the cert expires (currently 2036).

### Persistence

- Stateless apps: no PVC needed.
- Single-instance stateful: a PVC in the same namespace, `local-path` storage class.
- App + DB: co-located PostgreSQL Deployment + PVC in the same namespace (see n8n, Windmill, Authentik).

---

## Adding a new service

1. **Create the directory** with at minimum:

   ```text
   services/<name>/
   ├── namespace.yaml
   ├── deployment.yaml
   ├── service.yaml
   └── ingress.yaml
   ```

2. **Pick an auth mode.**
   - Forward-auth → copy `examples/n8n-ingress-protected.yaml` into `ingress.yaml`, adjust host/service.
   - OIDC → register provider in Authentik first, then:
     ```bash
     kubectl create secret generic <name>-oidc \
       --from-literal=client_id=... --from-literal=client_secret=... \
       --dry-run=client -o yaml | kubeseal -o yaml > services/<name>/oidc-sealed-secret.yaml
     ```

3. **If the app calls Authentik outbound**, add `authentik-ca-configmap.yaml` (copy from a neighbour) and wire the init container.

4. **Create the ArgoCD app:**

   ```bash
   cp argocd/apps/n8n-app.yaml argocd/apps/<name>-app.yaml
   # edit metadata.name, spec.source.path, spec.destination.namespace
   ```

5. **Commit, push.** ArgoCD picks it up automatically.

6. **Verify:**

   ```bash
   argocd app get <name>
   kubectl -n <name> get pods,ingress
   curl -I https://<name>.krockysphere.com
   ```
