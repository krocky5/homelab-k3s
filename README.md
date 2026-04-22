# homelab-k3s

Kubernetes manifests, Helm values, and operational scripts for a k3s homelab cluster fronted by Cloudflare and protected by Authentik SSO. Managed declaratively via ArgoCD; all traffic lands at Traefik behind a Cloudflare Zero Trust tunnel.

All public hostnames live under `*.krockysphere.com`.

---

## Contents

- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Services at a glance](#services-at-a-glance)
- [Getting started](#getting-started)
- [Core flows](#core-flows)
- [Secrets & authentication](#secrets--authentication)
- [Adding a new service](#adding-a-new-service)
- [Per-area documentation](#per-area-documentation)

---

## Architecture

```
                ┌──────────────────────────────────────────────┐
                │               Cloudflare DNS                 │
                │          *.krockysphere.com → Tunnel         │
                └───────────────────┬──────────────────────────┘
                                    │ outbound tunnel
                                    ▼
                  ┌───────────────────────────────────┐
                  │  cloudflared (namespace: tunnel)  │
                  └───────────────────┬───────────────┘
                                      │
                                      ▼
                  ┌───────────────────────────────────┐
                  │   Traefik (ingress, kube-system)  │
                  │   + Let's Encrypt (DNS01)         │
                  │   + Authentik forward-auth MW     │
                  └──┬────────────────────────────────┘
                     │
       ┌─────────────┼──────────────┬──────────────┬──────────────┐
       ▼             ▼              ▼              ▼              ▼
  Authentik      Vault         Grafana         KrakenD        Homarr, n8n,
  (OIDC IdP)   (secrets)    (dashboards)    (API gateway)    Windmill, ...

                         ┌───────────── ArgoCD ──────────────┐
                         │  watches services/* + argocd/     │
                         │  prunes + self-heals              │
                         └───────────────────────────────────┘
```

- **Ingress:** k3s-bundled Traefik with ACME via Cloudflare DNS-01.
- **Auth:** Every public service sits behind Authentik — either OIDC (native to the app) or Traefik forward-auth middleware.
- **GitOps:** ArgoCD reconciles everything under `services/`. New manifests merged to `main` are applied automatically.
- **Observability:** KrakenD and n8n export OTLP → OpenTelemetry Collector → Jaeger. Grafana reads Prometheus metrics (including KrakenD's `:8090/__stats`).
- **Secrets:** Sealed Secrets for in-repo encrypted material, Vault for runtime, GitHub Actions secrets for CI/CD (KrakenD config merge).

---

## Repository layout

```text
homelab-k3s/
├── argocd/                     # ArgoCD self-config + Application manifests
│   └── apps/                   #   one Application per service
├── cloudflare-tunnel/          # cloudflared Deployment (namespace: tunnel)
├── examples/                   # Copy-paste ingress templates w/ forward-auth
├── krakend-configs/            # KrakenD source configs (merged at build time)
│   ├── dev/                    #   settings.json (tracked) + endpoints.json (gitignored)
│   └── prod/                   #   same pattern
├── scripts/                    # Operational scripts (Vault RBAC, rotations, bootstrap)
│   └── vault-policies/         #   HCL policy files applied by vault-homelab-rbac.sh
├── services/                   # One subdir per workload — see table below
├── traefik/                    # HelmChartConfig tuning k3s's bundled Traefik
├── test-endpoints.json         # KrakenD endpoint test fixtures
├── deploy-local.sh             # Local bootstrap helper
└── README.md                   # this file
```

---

## Services at a glance

| Service          | Namespace      | Hostname                          | Auth                       | State        |
|------------------|----------------|-----------------------------------|----------------------------|--------------|
| Authentik        | authentik      | auth.krockysphere.com             | native                     | Postgres PVC |
| ArgoCD           | argocd         | argocd.krockysphere.com           | Authentik OIDC             | stateless    |
| Vault            | vault          | secrets.krockysphere.com          | Authentik OIDC + groups    | 10Gi PVC     |
| Grafana          | monitoring     | grafana.krockysphere.com          | Authentik OIDC (OAuth)     | via Prom stack |
| Jaeger           | monitoring     | jaeger.krockysphere.com           | Authentik forward-auth     | 10Gi PVC     |
| OTel Collector   | monitoring     | (internal only)                   | none                       | stateless    |
| KrakenD (prod)   | krakend-prod   | api.krockysphere.com              | Authentik forward-auth + rate-limit | stateless |
| KrakenD (dev)    | krakend-dev    | api-dev.krockysphere.com          | Authentik forward-auth     | stateless    |
| Homarr v1        | homarr-v1      | home.krockysphere.com             | Authentik OIDC             | 2 PVCs       |
| Homarr (legacy)  | homarr         | (inactive)                        | Authentik forward-auth     | 10Gi PVC     |
| n8n              | n8n            | automationsv2.krockysphere.com    | Authentik forward-auth     | Postgres PVC |
| Windmill         | windmill       | windmill.krockysphere.com         | Authentik OIDC + forward   | Postgres PVC |
| Proxmox (proxy)  | default        | proxmox.krockysphere.com          | passthrough                | external VM  |
| Traefik dashboard| kube-system    | traefik.krockysphere.com          | none (LAN-only assumption) | stateless    |

---

## Getting started

### Prerequisites

- k3s cluster up and reachable via `kubectl` (`kubectl get nodes` works).
- Cloudflare API token (DNS edit) stored as a k8s secret named `cloudflare-api-token`.
- A Cloudflare Zero Trust tunnel created; token stored as `cloudflared-tunnel-token` in namespace `tunnel`.
- (Optional but assumed) `sealed-secrets-controller` running for decrypting `*-sealed-secret.yaml`.

### Bootstrap order

```bash
# 1. Traefik config (ACME, DNS challenge, persistence)
kubectl apply -f traefik/traefik-config.yaml

# 2. Cloudflare tunnel
kubectl apply -f cloudflare-tunnel/cloudflared/deployment.yaml

# 3. ArgoCD + its Applications
kubectl apply -f argocd/
./scripts/deploy-argocd-apps.sh

# 4. Authentik (often already pulled in by ArgoCD)
kubectl apply -f services/authentik/
```

Once ArgoCD is running, new services only need:
1. A subdir under `services/` with manifests.
2. An `Application` YAML under `argocd/apps/`.
3. A merged commit to `main`.

See [Adding a new service](#adding-a-new-service).

---

## Core flows

### Authentication

Public services use Authentik in one of two modes:

- **OIDC integration (preferred)** — the app handles login via Authentik as an OIDC provider. Used by ArgoCD, Grafana, Vault, Homarr v1, Windmill.
- **Forward-auth middleware** — the app has no login code; Traefik calls Authentik before routing the request. Attached via Ingress annotation `traefik.ingress.kubernetes.io/router.middlewares: authentik-authentik-forwardauth@kubernetescrd` (or the `-with-cookies` variant). Used by n8n, KrakenD, Jaeger.

Groups `homelab-admin` and `homelab-user` exist in Authentik and drive RBAC in Vault and Grafana.

### Secrets

- **Sealed Secrets** for anything committed (OIDC client secrets, DB passwords). Encrypt with `kubeseal`.
- **Vault** at `secrets.krockysphere.com` for runtime secrets consumed by humans or workflows. See [`services/vault/README.md`](services/vault/README.md).
- **GitHub Actions secrets** for CI merging KrakenD endpoints into ConfigMaps.

### Observability

KrakenD and n8n export OTLP traces over gRPC to `otel-collector.default.svc.cluster.local:4317`. The collector forwards to Jaeger; the Jaeger UI is at `jaeger.krockysphere.com`. Prometheus (from the kube-prometheus-stack Helm chart) scrapes KrakenD's `:8090/__stats` via a `ServiceMonitor`.

---

## Adding a new service

1. Create `services/<name>/` with `namespace.yaml`, `deployment.yaml`, `service.yaml`, `ingress.yaml`, and any PVCs.
2. Use `examples/n8n-ingress-protected.yaml` as your ingress template — it wires up the Authentik forward-auth middleware correctly. For OIDC-native apps, register a new provider in Authentik first and wire client id/secret via a Sealed Secret.
3. If the app calls Authentik over HTTPS (outbound OIDC), mount the `authentik-ca` ConfigMap into its trust store (Homarr v1 and Windmill show two patterns: init container copy, or merged CA bundle via `SSL_CERT_FILE`).
4. Add `argocd/apps/<name>-app.yaml` pointing at the new path. Use an existing app as a template.
5. Commit and push. ArgoCD picks it up within ~3 minutes.

See [`services/README.md`](services/README.md) for the detailed template.

---

## Per-area documentation

- [`argocd/README.md`](argocd/README.md) — GitOps bootstrap, sync behaviour, troubleshooting.
- [`traefik/README.md`](traefik/README.md) — Ingress, TLS, ACME, Cloudflare DNS challenge.
- [`services/README.md`](services/README.md) — Service overview + add-a-service template.
- [`services/authentik/README.md`](services/authentik/README.md) — OIDC IdP, groups, forward-auth middleware, CA distribution.
- [`services/vault/README.md`](services/vault/README.md) — Unsealing, OIDC auth, homelab RBAC, rotation scripts.
- [`scripts/README.md`](scripts/README.md) — Every operational script and when to run it.
- [`krakend-configs/README.md`](krakend-configs/README.md) — KrakenD config merging + GitHub Actions flow.
