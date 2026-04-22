# argocd/

ArgoCD self-configuration and the `Application` manifests that reconcile every workload in this repo.

## Files

| File | Purpose |
|------|---------|
| `argocd-cm.yaml`               | ArgoCD ConfigMap — wires up Authentik as the OIDC provider for UI login. |
| `argocd-rbac-cm.yaml`          | Maps Authentik groups to ArgoCD roles (e.g. `homelab-admin` → `role:admin`). |
| `argocd-oidc-sealed-secret.yaml` | Sealed Secret holding the `argocd` OIDC client secret. |
| `ingress.yaml`                 | Exposes the UI at `argocd.krockysphere.com` via Traefik. |
| `apps/*.yaml`                  | One `Application` per workload; sources from paths under `services/`. |

## Bootstrap

ArgoCD is self-managing after the initial apply. First time on a fresh cluster:

```bash
# install upstream ArgoCD (Helm or manifest, your choice)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# apply this repo's customisations (ConfigMaps, ingress, sealed secret)
kubectl apply -f argocd/

# seed the Applications
./scripts/deploy-argocd-apps.sh
```

After that, UI login goes through Authentik; CLI login with `argocd login argocd.krockysphere.com --sso` works too.

## How syncing works

Every `apps/*.yaml` has:

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

Which means:
- New commits to `main` touching a watched path trigger a sync within ~3 minutes.
- Manual `kubectl` edits get reverted (self-heal).
- Resources removed from Git get deleted from the cluster (prune).

## Adding a new Application

```yaml
# argocd/apps/<name>-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <name>
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/krocky5/homelab-k3s.git
    targetRevision: main
    path: services/<name>
  destination:
    server: https://kubernetes.default.svc
    namespace: <name>
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

Commit, push, and ArgoCD will pick it up.

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| App stuck `OutOfSync` with `comparison error` | CRDs referenced but not installed — check if the source Helm chart needs a `--set installCRDs=true` or equivalent. |
| `Unknown` health | Resource kind not known to ArgoCD's health checks; usually benign. |
| OIDC login fails with `invalid_client` | Authentik client_secret drifted — re-seal `argocd-oidc-sealed-secret.yaml` with the current value from Authentik. |
| Diff shows churn on every sync | Something else mutates the resource (mutation webhook, another operator). Add `ignoreDifferences` to the Application. |

Useful one-liners:

```bash
# what's out of sync
argocd app list | awk '$2 != "Synced"'

# force a resync ignoring cache
argocd app sync <name> --force

# refresh only
argocd app get <name> --refresh
```
