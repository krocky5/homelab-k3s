# KrakenD CI/CD Quick Start Guide

## What Was Changed

✅ **Separated configs** - Settings and endpoints are now in separate files
✅ **Git-safe** - Endpoints are gitignored, only settings are committed
✅ **GitHub Actions** - Automated validation and deployment
✅ **Secret management** - Endpoints stored as GitHub Secrets

## File Structure Created

```
krakend-configs/
├── build.sh                    # Merges settings + endpoints
├── sync-secrets.sh             # Syncs endpoints to GitHub Secrets
├── README.md                   # Full documentation
├── QUICKSTART.md              # This file
├── CLOUDFLARED_SETUP.md       # Cloudflare tunnel instructions
├── dev/
│   ├── settings.json          # ✅ Committed (no secrets)
│   ├── endpoints.json         # ⛔ Gitignored (has internal URLs)
│   ├── endpoints.example.json # ✅ Committed (template)
│   ├── krakend.json           # ⛔ Gitignored (generated)
│   └── krakend.tmpl           # ✅ Committed (optional)
└── prod/
    ├── settings.json          # ✅ Committed (no secrets)
    ├── endpoints.json         # ⛔ Gitignored (has internal URLs)
    ├── endpoints.example.json # ✅ Committed (template)
    ├── krakend.json           # ⛔ Gitignored (generated)
    └── krakend.tmpl           # ✅ Committed (optional)
```

## 5-Minute Setup

### Step 1: Verify Local Build Works

```bash
cd /Users/kevinroccanova/.kube/krakend-configs

# Build both environments
./build.sh dev
./build.sh prod

# Verify output
jq '.name, (.endpoints | length)' dev/krakend.json
jq '.name, (.endpoints | length)' prod/krakend.json
```

### Step 2: Add GitHub Secrets

You need to add 3 secrets to your GitHub repository:

#### 2a. Get endpoint JSON for secrets

```bash
# Copy dev endpoints (compact JSON)
cat dev/endpoints.json | jq -c .

# Copy prod endpoints (compact JSON)
cat prod/endpoints.json | jq -c .
```

#### 2b. Add to GitHub

Go to: `https://github.com/YOUR_USERNAME/YOUR_REPO/settings/secrets/actions`

Add these secrets:

| Secret Name | Value | Source |
|-------------|-------|--------|
| `KRAKEND_DEV_ENDPOINTS` | JSON from `dev/endpoints.json` | Paste compact JSON |
| `KRAKEND_PROD_ENDPOINTS` | JSON from `prod/endpoints.json` | Paste compact JSON |
| `KUBECONFIG` | Base64 encoded kubeconfig | `cat ~/.kube/config \| base64` |

**OR use the helper script:**

```bash
# Interactive upload with gh CLI
./sync-secrets.sh prod YOUR_GITHUB_USER YOUR_REPO_NAME
```

### Step 3: Commit and Push

```bash
cd /Users/kevinroccanova/.kube/k3s

# Check what will be committed (should NOT include endpoints.json)
git status

# You should see:
# - krakend-configs/dev/settings.json (modified/new)
# - krakend-configs/prod/settings.json (modified/new)
# - krakend-configs/dev/endpoints.example.json (new)
# - krakend-configs/prod/endpoints.example.json (new)
# - .github/workflows/krakend-config.yml (new)
# - .gitignore (modified)

# Commit changes
git add .
git commit -m "Setup KrakenD CI/CD with separated configs"
git push origin main
```

### Step 4: Monitor GitHub Actions

1. Go to: `https://github.com/YOUR_USERNAME/YOUR_REPO/actions`
2. Watch the "KrakenD Config CI/CD" workflow
3. It will:
   - ✅ Validate settings.json
   - ✅ Restore endpoints from secrets
   - ✅ Build final krakend.json
   - ✅ Validate with KrakenD CLI
   - ✅ Update ConfigMap in cluster
   - ✅ Restart KrakenD deployment

### Step 5: Setup Cloudflared

See `CLOUDFLARED_SETUP.md` for detailed instructions. Quick version:

```bash
kubectl edit configmap cloudflared-config -n cloudflare-tunnel
```

Add these ingress rules:

```yaml
ingress:
  - hostname: api.krockysphere.com
    service: http://krakend.krakend-prod.svc.cluster.local:8080

  - hostname: api-dev.krockysphere.com
    service: http://krakend.krakend-dev.svc.cluster.local:8080

  # ... your other services ...

  - service: http_status:404  # catch-all (must be last)
```

Restart cloudflared:

```bash
kubectl rollout restart deployment/cloudflared -n cloudflare-tunnel
```

### Step 6: Test

```bash
# Test health endpoints
curl https://api.krockysphere.com/__health
curl https://api-dev.krockysphere.com/__health

# Test API routes
curl https://api.krockysphere.com/api/n8n/health
```

## Daily Workflow

### Adding New Endpoints

1. **Edit locally** (not committed):
```bash
vi krakend-configs/prod/endpoints.json
# Add your new endpoint
```

2. **Test locally**:
```bash
./build.sh prod
jq '.endpoints[-1]' prod/krakend.json  # Check last endpoint
```

3. **Update GitHub Secret**:
```bash
./sync-secrets.sh prod YOUR_GITHUB_USER YOUR_REPO
```

4. **Push to deploy**:
```bash
cd /Users/kevinroccanova/.kube/k3s
git add .
git commit -m "Update KrakenD settings"
git push
```

GitHub Actions will automatically deploy the updated config!

### Changing Settings (non-secret)

1. **Edit settings.json**:
```bash
vi krakend-configs/prod/settings.json
# Change timeout, CORS, etc.
```

2. **Commit and push**:
```bash
git add krakend-configs/prod/settings.json
git commit -m "Update KrakenD timeout settings"
git push
```

That's it! No need to update secrets if you only changed settings.

## Troubleshooting

### "endpoints.json not found" error

```bash
# Make sure endpoints.json exists
ls -la krakend-configs/dev/endpoints.json
ls -la krakend-configs/prod/endpoints.json

# If missing, copy from example
cp krakend-configs/dev/endpoints.example.json krakend-configs/dev/endpoints.json
```

### Build fails locally

```bash
# Check JSON syntax
jq empty krakend-configs/dev/settings.json
jq empty krakend-configs/dev/endpoints.json
```

### GitHub Actions fails

1. Check secrets are set: Settings → Secrets → Actions
2. Check workflow logs: Actions tab → Click failed workflow
3. Common issues:
   - Missing `KUBECONFIG` secret
   - Invalid JSON in endpoint secret
   - Wrong secret name (must be uppercase: `KRAKEND_PROD_ENDPOINTS`)

### Deployment doesn't update

```bash
# Manually update ConfigMap
kubectl create configmap krakend-config \
  --from-file=krakend.json=krakend-configs/prod/krakend.json \
  --namespace=krakend-prod \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart deployment
kubectl rollout restart deployment/krakend -n krakend-prod
```

## Security Checklist

- [ ] Endpoints.json is in .gitignore
- [ ] krakend.json (generated) is in .gitignore
- [ ] GitHub Secrets are set correctly
- [ ] KUBECONFIG secret is base64 encoded
- [ ] Cloudflare Access is enabled for dev environment
- [ ] Rate limiting is configured
- [ ] CORS origins are restrictive in prod

## What's Protected Now

✅ **Internal service URLs** - Not in git, only in GitHub Secrets
✅ **Backend hosts** - Hidden from public repository
✅ **Service topology** - Endpoints reveal nothing about infrastructure
✅ **Rate limits per endpoint** - Stored securely

## What's Safe to Commit

✅ **Settings** - Timeouts, CORS, logging config
✅ **Example templates** - Generic endpoint structures
✅ **Build scripts** - No secrets
✅ **Documentation** - This file and others

## Next Steps

1. ✅ Setup complete - Test the deployment
2. 📊 Monitor in Grafana (already configured)
3. 🔍 Check traces in Jaeger (already configured)
4. 🚨 Set up alerts for API failures
5. 📝 Document your API endpoints for team
6. 🔒 Enable Cloudflare Access for dev environment

## Getting Help

- Full docs: `README.md`
- Cloudflare setup: `CLOUDFLARED_SETUP.md`
- Build script: `./build.sh --help` (coming soon)
- Sync script: `./sync-secrets.sh`

---

**Status**: ✅ Your KrakenD configs are now CI/CD compliant and secure!
