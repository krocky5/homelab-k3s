# Cloudflared Configuration for KrakenD

## Overview

Since you're using Cloudflare Tunnel (cloudflared) to expose your services, you need to configure it to route traffic to your KrakenD API Gateway endpoints.

## Current Setup

Based on your ingress configurations:
- **Dev Environment**: `api-dev.krockysphere.com` → KrakenD (port 8080) in `krakend-dev` namespace
- **Prod Environment**: `api.krockysphere.com` → KrakenD (port 8080) in `krakend-prod` namespace

## Cloudflared Configuration

### Option 1: Update cloudflared ConfigMap

Add these ingress rules to your cloudflared configuration:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: cloudflare-tunnel
data:
  config.yaml: |
    tunnel: YOUR_TUNNEL_ID
    credentials-file: /etc/cloudflared/credentials.json

    ingress:
      # KrakenD Production API Gateway
      - hostname: api.krockysphere.com
        service: http://krakend.krakend-prod.svc.cluster.local:8080
        originRequest:
          connectTimeout: 30s
          noTLSVerify: false

      # KrakenD Development API Gateway
      - hostname: api-dev.krockysphere.com
        service: http://krakend.krakend-dev.svc.cluster.local:8080
        originRequest:
          connectTimeout: 30s
          noTLSVerify: false

      # Existing services...
      # (keep your other tunnel configurations here)

      # Catch-all rule (must be last)
      - service: http_status:404
```

### Option 2: Separate ConfigMap for KrakenD Routes

Create a dedicated ConfigMap and merge it:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-krakend-routes
  namespace: cloudflare-tunnel
data:
  krakend-routes.yaml: |
    # KrakenD API Gateway Routes
    - hostname: api.krockysphere.com
      service: http://krakend.krakend-prod.svc.cluster.local:8080
      originRequest:
        connectTimeout: 30s
        noTLSVerify: false
        httpHostHeader: api.krockysphere.com

    - hostname: api-dev.krockysphere.com
      service: http://krakend.krakend-dev.svc.cluster.local:8080
      originRequest:
        connectTimeout: 30s
        noTLSVerify: false
        httpHostHeader: api-dev.krockysphere.com
```

## Cloudflare Dashboard Setup

### 1. Create DNS Records

In your Cloudflare dashboard (krockysphere.com zone):

```
Type: CNAME
Name: api
Content: YOUR_TUNNEL_ID.cfargotunnel.com
Proxy status: Proxied (orange cloud)

Type: CNAME
Name: api-dev
Content: YOUR_TUNNEL_ID.cfargotunnel.com
Proxy status: Proxied (orange cloud)
```

### 2. Configure Tunnel Routes

Via Cloudflare Dashboard:
1. Go to **Zero Trust** → **Networks** → **Tunnels**
2. Select your tunnel
3. Go to **Public Hostname** tab
4. Add routes:

**Production Route:**
- **Public hostname**: `api.krockysphere.com`
- **Service**: `http://krakend.krakend-prod.svc.cluster.local:8080`
- **Additional settings**:
  - Connect Timeout: 30s
  - HTTP Host Header: `api.krockysphere.com`

**Development Route:**
- **Public hostname**: `api-dev.krockysphere.com`
- **Service**: `http://krakend.krakend-dev.svc.cluster.local:8080`
- **Additional settings**:
  - Connect Timeout: 30s
  - HTTP Host Header: `api-dev.krockysphere.com`

## Advanced Configuration

### With Rate Limiting (Cloudflare WAF)

Add Cloudflare WAF rules for your KrakenD endpoints:

```
Zone: krockysphere.com
Rule name: KrakenD API Rate Limit
Expression: (http.host eq "api.krockysphere.com")
Action: Rate Limit
Rate: 100 requests per minute per IP
```

### With Access Control (Cloudflare Access)

Protect your dev environment:

```
Application name: KrakenD Dev API
Domain: api-dev.krockysphere.com
Policy:
  - Name: Developers Only
  - Action: Allow
  - Include: Email → your-team@domain.com
```

### With Caching Rules

Optimize API responses:

```
Cache Rule for KrakenD:
- If hostname equals api.krockysphere.com
- And URI Path starts with /api/
- Cache Level: Standard
- Edge TTL: 5 minutes
- Browser TTL: 1 minute
```

## Kubectl Commands to Apply

### Update cloudflared deployment to use new config

```bash
# Edit the cloudflared configmap
kubectl edit configmap cloudflared-config -n cloudflare-tunnel

# Restart cloudflared to pick up changes
kubectl rollout restart deployment/cloudflared -n cloudflare-tunnel

# Check status
kubectl rollout status deployment/cloudflared -n cloudflare-tunnel

# Check logs
kubectl logs -n cloudflare-tunnel -l app=cloudflared --tail=50
```

## Verification

### Test connectivity through tunnel

```bash
# Test production endpoint
curl https://api.krockysphere.com/__health

# Test dev endpoint
curl https://api-dev.krockysphere.com/__health

# Test an API route (example)
curl https://api.krockysphere.com/api/n8n/health

# Check headers
curl -I https://api.krockysphere.com/__health
```

### Debug tunnel issues

```bash
# Check cloudflared logs
kubectl logs -n cloudflare-tunnel deployment/cloudflared -f

# Check krakend logs
kubectl logs -n krakend-prod deployment/krakend -f
kubectl logs -n krakend-dev deployment/krakend -f

# Test internal service connectivity
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- sh
# Inside the pod:
curl http://krakend.krakend-prod.svc.cluster.local:8080/__health
```

## Security Recommendations

1. **Use Cloudflare Access** for dev environment
2. **Enable Bot Protection** on production API
3. **Set up Rate Limiting** at both Cloudflare and KrakenD levels
4. **Monitor metrics** via Grafana dashboard
5. **Enable WAF rules** for common API attacks
6. **Use API Shield** for additional protection

## Example: Full Cloudflared ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: cloudflare-tunnel
data:
  config.yaml: |
    tunnel: YOUR_TUNNEL_ID
    credentials-file: /etc/cloudflared/credentials.json
    metrics: 0.0.0.0:2000
    no-autoupdate: true

    ingress:
      # KrakenD Production - Main API Gateway
      - hostname: api.krockysphere.com
        service: http://krakend.krakend-prod.svc.cluster.local:8080
        originRequest:
          connectTimeout: 30s
          tlsTimeout: 10s
          noHappyEyeballs: false
          keepAliveTimeout: 90s
          keepAliveConnections: 100
          httpHostHeader: api.krockysphere.com
          originServerName: api.krockysphere.com

      # KrakenD Development - Dev API Gateway
      - hostname: api-dev.krockysphere.com
        service: http://krakend.krakend-dev.svc.cluster.local:8080
        originRequest:
          connectTimeout: 30s
          httpHostHeader: api-dev.krockysphere.com

      # Your other services (Grafana, n8n, etc.)
      # ...

      # Catch-all rule (MUST be last)
      - service: http_status:404
```

## Next Steps

1. ✅ Update cloudflared ConfigMap with KrakenD routes
2. ✅ Create DNS records in Cloudflare Dashboard
3. ✅ Restart cloudflared deployment
4. ✅ Test endpoints with curl
5. ✅ Set up Cloudflare Access for dev environment (optional)
6. ✅ Configure WAF rules (optional)
7. ✅ Monitor logs and metrics
