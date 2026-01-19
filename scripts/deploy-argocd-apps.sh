#!/bin/bash
# Deploy all Argo CD applications

set -e

echo "Deploying Argo CD Applications..."

# Replace with your actual GitHub username
GITHUB_USER="krocky5"

# Update all app manifests with correct repo URL
echo "Updating repository URLs..."
find ~/.kube/k3s/argocd/apps -name "*.yaml" -type f -exec sed -i '' "s|yourusername|${GITHUB_USER}|g" {} \;

# Apply all applications
echo ""
echo "Deploying applications..."

apps=(
  "n8n"
  "jaeger"
  "otel-collector"
  "grafana"
  "cloudflared"
  "windmill"
)

for app in "${apps[@]}"; do
  echo "  ➜ Deploying ${app}..."
  kubectl apply -f ~/.kube/k3s/argocd/apps/${app}-app.yaml
done

echo ""
echo "All applications deployed!"
echo ""
echo "Check status:"
echo "  kubectl get applications -n argocd"
echo ""
echo "Access Argo CD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  https://localhost:8080"
