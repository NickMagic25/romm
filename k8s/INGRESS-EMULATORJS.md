# Ingress Configuration for EmulatorJS

This document explains the required HTTP headers for EmulatorJS to work properly with different ingress controllers in Kubernetes.

## Background

EmulatorJS requires specific Cross-Origin headers to enable SharedArrayBuffer support for multi-threaded emulator cores. Without these headers, the emulator will show a black screen.

## Required Headers

### 1. Emulator Page (`/rom/.*/ejs`)
These headers must be set on the emulator player page:
- `Cross-Origin-Embedder-Policy: require-corp`
- `Cross-Origin-Opener-Policy: same-origin`

**Already configured** in `docker/nginx/templates/frontend.conf.template` using nginx map directives.

### 2. API Endpoints (`/api`)
All API endpoints must respond with:
- `Cross-Origin-Resource-Policy: cross-origin`

**Already configured** in `docker/nginx/templates/frontend.conf.template`:
```nginx
location /api {
    proxy_pass http://backend_server;
    proxy_request_buffering off;
    proxy_buffering off;
    # 'always' ensures header is added even for proxied responses
    add_header Cross-Origin-Resource-Policy cross-origin always;
}
```

**Note**: The `always` parameter is critical when behind an ingress/proxy to ensure headers pass through.

## Ingress Controller Configurations

### Traefik (k3d default)

Basic Ingress (already in `k8s/ingress.yaml`):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: romm-ingress
  namespace: romm
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: romm-frontend
            port:
              number: 80
```

**Note**: Traefik should pass headers through correctly with the `always` parameter on nginx's `add_header` directive.

### Cilium Gateway API

Cilium uses Envoy and supports the Gateway API. Use HTTPRoute with response header modifiers:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: romm-gateway
  namespace: romm
spec:
  gatewayClassName: cilium
  listeners:
  - name: http
    protocol: HTTP
    port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: romm-route
  namespace: romm
spec:
  parentRefs:
  - name: romm-gateway
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /api
    filters:
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        add:
        - name: Cross-Origin-Resource-Policy
          value: cross-origin
    backendRefs:
    - name: romm-frontend
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: romm-frontend
      port: 80
```

**Alternative**: Let nginx handle headers (preferred):
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: romm-route
  namespace: romm
spec:
  parentRefs:
  - name: romm-gateway
  rules:
  - backendRefs:
    - name: romm-frontend
      port: 80
```

### NGINX Ingress Controller

Basic approach (nginx in frontend handles headers):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: romm-ingress
  namespace: romm
  annotations:
    kubernetes.io/ingress.class: nginx
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: romm-frontend
            port:
              number: 80
```

**If headers aren't passing through**, add configuration snippet:
```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/configuration-snippet: |
      more_set_headers "Cross-Origin-Resource-Policy: cross-origin";
```

### Istio Service Mesh

When using Istio, create an EnvoyFilter to ensure headers pass through:

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: romm-headers
  namespace: romm
spec:
  workloadSelector:
    labels:
      app: romm-frontend
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: SIDECAR_OUTBOUND
    patch:
      operation: INSERT_BEFORE
      value:
        name: envoy.filters.http.cors
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.http.cors.v3.Cors
```

Or use VirtualService:
```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: romm
  namespace: romm
spec:
  hosts:
  - "*"
  gateways:
  - romm-gateway
  http:
  - route:
    - destination:
        host: romm-frontend
        port:
          number: 80
    headers:
      response:
        add:
          cross-origin-resource-policy: cross-origin
```

### HAProxy Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: romm-ingress
  namespace: romm
  annotations:
    haproxy.org/response-set-header: |
      Cross-Origin-Resource-Policy cross-origin
spec:
  ingressClassName: haproxy
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: romm-frontend
            port:
              number: 80
```

## Verification

### 1. Check Emulator Page Headers

```bash
curl -I http://localhost:8080/rom/1/ejs | grep -i cross-origin
```

**Expected output**:
```
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Opener-Policy: same-origin
```

### 2. Check API Headers

```bash
curl -I http://localhost:8080/api/config | grep -i cross-origin
```

**Expected output**:
```
Cross-Origin-Resource-Policy: cross-origin
```

### 3. Check ROM File Headers

```bash
# Login first to get auth cookie, then:
curl -I http://localhost:8080/api/roms/1 -H "Cookie: romm_csrftoken=YOUR_TOKEN" | grep -i cross-origin
```

**Expected output**:
```
Cross-Origin-Resource-Policy: cross-origin
```

## Troubleshooting

### Black Screen with No Console Errors

**Symptoms**: Emulator shows black screen, browser console has no red errors.

**Cause**: CORP header is missing or blocked by ingress controller.

**Solution**:
1. Verify headers using curl commands above
2. If headers are missing from API responses, your ingress is stripping them
3. Add ingress-specific header configuration (see sections above)
4. Ensure nginx has `always` parameter: `add_header Cross-Origin-Resource-Policy cross-origin always;`

### COOP Header Warning in Console

**Error**: "The Cross-Origin-Opener-Policy header has been ignored, because the URL's origin was untrustworthy..."

**Cause**: Using HTTP instead of HTTPS.

**Impact**: This is just a warning and doesn't break functionality on localhost/HTTP.

**Solution** (optional): Configure TLS/HTTPS in your ingress:
```yaml
spec:
  tls:
  - hosts:
    - romm.example.com
    secretName: romm-tls
```

### Headers Present but Emulator Still Black

**Check**:
1. Browser DevTools → Network tab → Find ROM file request
2. Check both Request and Response headers
3. Verify `Cross-Origin-Resource-Policy` is in Response headers

**If header is present** but still failing:
- Check browser compatibility (use modern Chrome/Firefox/Edge)
- Clear browser cache and cookies
- Try incognito/private browsing mode
- Check for browser extensions blocking content (uBlock, Privacy Badger, etc.)

### Service Mesh Interference

If using Istio, Linkerd, or similar:
- Sidecar proxies may inject their own headers
- Check proxy logs: `kubectl logs -n romm POD_NAME -c istio-proxy`
- May need mesh-specific configuration (see Istio section above)

## Cloud Provider Considerations

### AWS ALB Ingress Controller
```yaml
metadata:
  annotations:
    alb.ingress.kubernetes.io/target-type: ip
    # ALB should pass headers through
```

### GKE Ingress
```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: "gce"
    # GCE ingress should pass headers through
```

### Azure Application Gateway
```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
    # May need header rewrite rules via BackendSettingsPool
```

## HTTPS/TLS Notes

When using HTTPS (recommended for production):
- The COOP warning disappears
- Browsers enforce stricter CORS policies
- Ensure all headers pass through TLS termination

Example cert-manager Certificate:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: romm-tls
  namespace: romm
spec:
  secretName: romm-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - romm.example.com
```

## Testing Checklist

After deploying with a new ingress:

- [ ] Verify emulator page headers: `curl -I http://localhost:8080/rom/1/ejs | grep -i cross`
- [ ] Verify API headers: `curl -I http://localhost:8080/api/config | grep -i cross`
- [ ] Open browser DevTools → Network tab
- [ ] Navigate to emulator and click Play
- [ ] Check ROM file response headers include `Cross-Origin-Resource-Policy: cross-origin`
- [ ] Verify emulator displays game (not black screen)
- [ ] Test save/load state functionality
- [ ] Test fullscreen mode

## References

- [MDN: Cross-Origin-Embedder-Policy](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Cross-Origin-Embedder-Policy)
- [MDN: Cross-Origin-Opener-Policy](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Cross-Origin-Opener-Policy)
- [MDN: Cross-Origin-Resource-Policy](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Cross-Origin-Resource-Policy)
- [EmulatorJS Documentation](https://github.com/EmulatorJS/EmulatorJS)
- [SharedArrayBuffer Requirements](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/SharedArrayBuffer#security_requirements)
