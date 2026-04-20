#!/bin/bash
set -e

ENV=${1:-prod}

echo "========================================"
echo "KrakenD Local Deployment - $ENV"
echo "========================================"

# Check prerequisites
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }
command -v kubeseal >/dev/null 2>&1 || { echo "kubeseal not found"; exit 1; }
command -v vault >/dev/null 2>&1 || { echo "vault CLI not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found"; exit 1; }

# Set Vault address
export VAULT_ADDR=https://secrets.krockysphere.com

# Check Vault auth
if ! vault token lookup >/dev/null 2>&1; then
  vault login -method=oidc
fi

# Fetch endpoints
vault kv get -format=json secret/krakend/$ENV/endpoints | \
  jq -r '.data.data.endpoints' > krakend-configs/$ENV/endpoints.json

# Build config
chmod +x krakend-configs/build.sh
krakend-configs/build.sh $ENV

# Validate
docker run --rm -v $(pwd)/krakend-configs/$ENV:/etc/krakend \
  devopsfaith/krakend:2.6 check -d -c /etc/krakend/krakend.json

# Create sealed secret
kubectl create secret generic krakend-config \
  --from-file=krakend.json=krakend-configs/$ENV/krakend.json \
  --namespace=krakend-$ENV \
  --dry-run=client -o yaml > /tmp/krakend-secret.yaml

kubeseal -f /tmp/krakend-secret.yaml \
  -w services/krakend-$ENV/sealed-secret.yaml \
  --namespace=krakend-$ENV

# Commit
git add services/krakend-$ENV/sealed-secret.yaml
if ! git diff --staged --quiet; then
  git commit -m "Update sealed KrakenD $ENV config"
  git push
fi

# Wait for ArgoCD
sleep 30

# Check deployment
kubectl rollout status deployment/krakend -n krakend-$ENV --timeout=5m

echo "✅ Deployment Complete!"
