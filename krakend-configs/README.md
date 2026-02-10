# KrakenD Configuration

This directory contains KrakenD API Gateway configurations split for CI/CD compliance and security.

## Structure

```
krakend-configs/
├── dev/
│   ├── settings.json          # Base settings (committed to git)
│   ├── endpoints.json          # Actual endpoints (gitignored, secret)
│   ├── endpoints.example.json  # Example template (committed to git)
│   └── krakend.tmpl           # Optional template file
├── prod/
│   ├── settings.json          # Base settings (committed to git)
│   ├── endpoints.json          # Actual endpoints (gitignored, secret)
│   ├── endpoints.example.json  # Example template (committed to git)
│   └── krakend.tmpl           # Optional template file
└── build.sh                    # Build script to merge configs
```

## Files

### settings.json (Committed)
Contains non-sensitive configuration:
- Timeouts, caching, port
- Logging, metrics, telemetry
- CORS settings
- Security policies

### endpoints.json (Secret - NOT committed)
Contains sensitive endpoint mappings:
- Internal service URLs
- Backend host configurations
- Rate limits per endpoint
- Circuit breaker configs

### endpoints.example.json (Committed)
Template showing endpoint structure without real internal URLs.

## Usage

### Local Development

1. Copy example endpoints:
```bash
cp dev/endpoints.example.json dev/endpoints.json
# Edit dev/endpoints.json with your actual endpoints
```

2. Build configuration:
```bash
./build.sh dev
```

3. Validate (if KrakenD installed locally):
```bash
krakend check -c dev/krakend.json -d
```

### GitHub Actions Setup

1. **Add GitHub Secrets** for each environment:
   - `KRAKEND_DEV_ENDPOINTS` - Content of `dev/endpoints.json`
   - `KRAKEND_PROD_ENDPOINTS` - Content of `prod/endpoints.json`
   - `KUBECONFIG` - Base64 encoded kubeconfig for cluster access

2. **Encode endpoints for GitHub Secrets**:
```bash
# For dev environment
cat dev/endpoints.json | base64

# For prod environment
cat prod/endpoints.json | base64
```

3. Add to GitHub Repository:
   - Go to Settings → Secrets and variables → Actions
   - Add each secret

### Kubernetes Deployment

The GitHub Actions workflow will:
1. Validate settings.json on every push
2. Merge settings + endpoints from secrets
3. Build final krakend.json
4. Update ConfigMap in cluster
5. Restart KrakenD deployment

### Manual Kubernetes Update

If needed, update manually:
```bash
# Build config
./build.sh prod

# Update ConfigMap
kubectl create configmap krakend-config \
  --from-file=krakend.json=prod/krakend.json \
  --namespace=krakend-prod \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart deployment
kubectl rollout restart deployment/krakend -n krakend-prod
```

## Security

- ✅ `settings.json` - Safe to commit (no internal URLs)
- ✅ `endpoints.example.json` - Safe to commit (examples only)
- ⛔ `endpoints.json` - NEVER commit (contains internal service URLs)
- ⛔ `krakend.json` - NEVER commit (generated, contains merged secrets)

## Adding New Endpoints

1. Edit `endpoints.json` locally (not committed)
2. Test locally with `./build.sh <env>`
3. Update the GitHub Secret with new endpoints:
```bash
cat prod/endpoints.json | jq -c . | pbcopy  # macOS
# Paste into GitHub Secrets
```
4. Push changes to settings.json if needed
5. GitHub Actions will deploy automatically

## Troubleshooting

### Configuration validation fails
```bash
# Check JSON syntax
jq empty dev/endpoints.json
jq empty dev/settings.json

# Check merged output
./build.sh dev
jq empty dev/krakend.json
```

### Missing endpoints in deployment
- Verify GitHub Secret `KRAKEND_<ENV>_ENDPOINTS` is set
- Check GitHub Actions logs for secret restoration step
- Ensure secret contains valid JSON

### ConfigMap not updating
```bash
# Verify ConfigMap contents
kubectl get configmap krakend-config -n krakend-prod -o yaml

# Force update
kubectl delete configmap krakend-config -n krakend-prod
kubectl create configmap krakend-config --from-file=krakend.json=prod/krakend.json -n krakend-prod
```
