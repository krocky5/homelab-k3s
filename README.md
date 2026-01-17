# homelab-k3s

This repository contains Kubernetes manifests and Helm values for a k3s homelab cluster. It includes:

- Traefik ingress controller with ACME / Cloudflare DNS challenge
- Grafana service and ingress
- Cloudflare Zero Trust tunnel (`cloudflared`) for secure external access

All secrets (Cloudflare API tokens, tunnel tokens) are stored locally on the cluster and **should not be committed to Git**.

---

## Table of Contents

- [Overview](#overview)
- [Folder Structure](#folder-structure)
- [Getting Started](#getting-started)
- [Applying Changes](#applying-changes)
- [Secrets Management](#secrets-management)
- [Adding New Applications](#adding-new-applications)
- [Best Practices](#best-practices)
- [Future Considerations](#future-considerations)

---

## Overview

This repository manages:

- Traefik as the ingress controller with HTTPS via Cloudflare DNS challenge
- Grafana deployment and ingress
- Cloudflare Zero Trust tunnel for secure remote access
- Safe GitOps workflow for future services (Argo CD, Jenkins, etc.)

---

## Folder Structure

```text
homelab-k3s/
├── cloudflare-tunnel/
│   └── cloudflared/
│       ├── configmap.yaml      # cloudflared configuration (non-secret)
│       └── deployment.yaml     # deployment referencing secret stored in cluster
├── services/
│   └── grafana/
│       ├── ingress.yaml        # Grafana ingress configuration
│       └── service.yaml        # Grafana ClusterIP service
└── traefik/
    └── values.yaml             # Traefik Helm values
```

- **Secrets** are not committed. They are stored directly on the k3s nodes or created via `kubectl create secret`.
- This layout is simple, avoids duplication, and is expandable.

---

## Getting Started

1. Clone the repository:

```bash
git clone git@github.com:yourusername/homelab-k3s.git
cd homelab-k3s
```

2. Ensure your kubeconfig points to your k3s cluster:

```bash
kubectl config use-context k3s
kubectl get nodes
```

---

## Applying Changes

1. **Traefik** (Helm values):

```bash
helm upgrade --install traefik traefik/traefik -n kube-system -f traefik/values.yaml
kubectl rollout status deploy/traefik -n kube-system
```

2. **Cloudflare tunnel**:

```bash
kubectl apply -f cloudflare-tunnel/cloudflared/configmap.yaml
kubectl apply -f cloudflare-tunnel/cloudflared/deployment.yaml
```

3. **Grafana service & ingress**:

```bash
kubectl apply -f services/grafana/service.yaml
kubectl apply -f services/grafana/ingress.yaml
```

4. **Verify everything**:

```bash
kubectl get pods -A
kubectl get svc -A
kubectl get ingress -A
kubectl logs -n tunnel deploy/cloudflared
```

---

## Secrets Management

- **Never commit secrets** to Git.
- Example for Cloudflare tunnel token:

```bash
kubectl create secret generic cloudflared-tunnel-token \
  --from-literal=TUNNEL_TOKEN='<YOUR_CLOUDFLARE_TOKEN>' \
  -n tunnel
```

- Reference secrets in your `Deployment` YAML:

```yaml
env:
  - name: TUNNEL_TOKEN
    valueFrom:
      secretKeyRef:
        name: cloudflared-tunnel-token
        key: TUNNEL_TOKEN
```

---

## Adding New Applications

1. Create a folder under `services/` for your app:

```text
services/myapp/
├── deployment.yaml
├── service.yaml
└── ingress.yaml
```

2. Create Cloudflare tunnel route if needed:

```yaml
# cloudflare-hostnames/myapp.yaml
apiVersion: cloudflare.com/v1alpha1
kind: TunnelIngress
metadata:
  name: myapp
  namespace: tunnel
spec:
  hostname: myapp.myDomain.com
  service: myapp-service.monitoring.svc.cluster.local:80
```

3. Apply resources:

```bash
kubectl apply -f services/myapp/
kubectl apply -f cloudflare-hostnames/myapp.yaml
```

4. Verify pod and service status:

```bash
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

---

## Best Practices

- Keep **Terraform** (infrastructure) and **k3s manifests** in separate repositories.
- Use local secrets or sealed secrets; **never commit sensitive tokens**.
- Keep manifests declarative; Helm values separate from secrets.
- Version-control all manifests for reproducibility.
- Consider GitOps tools (Argo CD, Flux) for automated reconciliation.

---

## Future Additions

- Add Argo CD for GitOps automation.
- CI/CD pipelines to validate manifests before applying.
- Network policies and RBAC for security hardening.
- Rotate secrets periodically.
