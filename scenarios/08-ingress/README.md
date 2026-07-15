# 08 - Ingress

## Overview

An Ingress exposes HTTP/HTTPS routes from outside the cluster to Services
inside it. It is a layered resource: the Ingress object defines rules, an
IngressClass and its controller (NGINX, ALB, Traefik) realize them, and a
Service + Endpoints carry the actual traffic. When traffic does not flow,
the failure can be at **any** of these layers — and `kubectl get ingress`
showing the rule is not proof that traffic works. From an SRE perspective
Ingress debugging is a **layered OSI-style triage**: rule → controller →
Service → Endpoints → Pod.

This scenario reproduces the most common shape: the Ingress object and the
Service both look fine, but the Service selector does not match any Pod, so
the Endpoints set is empty and the Ingress controller has nowhere to forward
traffic — returning 503/502.

## Symptoms

```bash
kubectl get ingress -n ktslab
```

```
NAME      CLASS    HOSTS                  ADDRESS        PORTS   AGE
webapp    nginx    webapp.ktslab.local    192.168.49.2   80      5m
```

The Ingress looks healthy. But external requests fail:

```bash
curl -H 'Host: webapp.ktslab.local' http://<ingress-address>
```

```
<html><head><title>503 Service Temporarily Unavailable</title></head>
<body>
<center><h1>503 Service Temporarily Unavailable</h1></center>
</body></html>
```

## Root Cause

The Ingress routes `webapp.ktslab.local /` to the `webapp` Service on port
`8080`. The Service's selector is `app: webapp`, but the Deployment's Pods are
labeled `app: web-frontend` (a mismatch). So:

1. The Service has **zero Endpoints** — no Pod matches its selector.
2. The Ingress controller reads the Service and finds no Endpoints.
3. The controller returns `503` for every request because there is no upstream.

The Ingress object, the controller, and the Service are all "up"; the broken
link is the Service-to-Pod selection. This is why `kubectl get ingress` alone
is misleading.

## Diagnosis

### 1. Check the Ingress object and its class

```bash
kubectl get ingress -n ktslab -o wide
kubectl describe ingress -n ktslab webapp
kubectl get ingressclass
```

Confirm the Ingress references a real IngressClass and the controller for that
class is running:

```bash
kubectl get pods -n ingress-nginx
```

### 2. Check the Service and its Endpoints — the critical step

```bash
kubectl get svc -n ktslab webapp -o wide
kubectl get endpoints -n ktslab webapp
```

`ENDPOINTS: <none>` is the smoking gun. The Ingress controller can route to the
Service, but the Service has no backing Pods.

### 3. Compare the Service selector to the Pod labels

```bash
kubectl get svc -n ktslab webapp -o jsonpath='{.spec.selector}'
kubectl get pods -n ktslab --show-labels
```

A mismatch between `spec.selector` and the Pod labels is the root cause.

### 4. Confirm the Service targetPort matches the container port

```bash
kubectl get svc -n ktslab webapp -o jsonpath='{.spec.ports}'
kubectl get pod -n ktslab <pod> -o jsonpath='{.spec.containers[0].ports}'
```

A Service pointing at `targetPort: 8080` while the container listens on `80`
gives a 503/connection-refused even with correct selectors.

### 5. Test the Service directly (bypass Ingress)

```bash
kubectl port-forward svc/webapp -n ktslab 8080:8080
curl http://localhost:8080
```

If port-forward also fails (no endpoints), the problem is below the Ingress.

### 6. Check the Ingress controller logs

```bash
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=50
```

Look for `no upstream available`, `service does not have any active endpoints`,
or `error loading configuration`.

### 7. Resolve the host and reach the controller

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
curl -H 'Host: webapp.ktslab.local' http://<controller-external-ip>/
```

## Resolution

### Fix A — Correct the Service selector to match the Pod labels

```bash
kubectl patch svc -n ktslab webapp --type=json \
  -p='[{"op":"replace","path":"/spec/selector","value":{"app":"web-frontend"}}]'
```

Or fix the Deployment labels to match the Service selector — whichever is
canonical. Endpoints populate within seconds.

### Fix B — Fix the Service targetPort

```yaml
ports:
  - port: 8080
    targetPort: 80   # must match container port
```

### Fix C — Fix the Ingress path/backend

If the Ingress points at the wrong Service name or port:

```yaml
backend:
  service:
    name: webapp            # must match a real Service
    port:
      number: 8080          # must match a Service port
```

### Fix D — Ensure the IngressClass controller is running

If `kubectl get ingressclass` is empty or the controller Pods are down,
reinstall/restart the Ingress controller for that class.

### Verify

```bash
kubectl get endpoints -n ktslab webapp
curl -H 'Host: webapp.ktslab.local' http://<ingress-address>/
```

## Best Practices

- **Always check Endpoints, not just the Service and Ingress.** An empty
  Endpoints set is the #1 cause of Ingress 503s with healthy-looking objects.
- **Use a single canonical `app` label** for selection across Deployment,
  Service, HPA, and PDB — selector drift is the most common Ingress bug.
- **Name the Service port** and reference it by name in the Ingress to avoid
  numeric port mismatches.
- **Define a default backend** on the Ingress controller so unmatched hosts
  return a controlled 404 instead of a raw 503.
- **Set `readinessProbe` on the workload** so Endpoints only populate when the
  Pod can actually serve — a Pod that is `Ready` but cannot answer is worse
  than a 503.
- **Pin the IngressClass** and ensure only one controller reconciles a given
  Ingress to avoid dual-controller conflicts.

## Production Tips

- On EKS, the AWS Load Balancer Controller realizes `IngressClass: alb`
  resources into an ALB. A 503 there often means the target group has no
  healthy targets — check the ALB target group health in AWS, not just
  `kubectl get ingress`. The ADDRESS field is the ALB DNS.
- Use `kubectl describe ingress` `Events` to confirm the controller reconciled
  the object — a stale Ingress with no events means no controller picked it up.
- For NGINX Ingress, enable `--enable-ssl-passthrough` only if needed; it
  changes the data path and breaks some LoadBalancer integrations.
- A 504 (gateway timeout) vs 503 (no upstream) vs 502 (bad upstream) tells you
  different things: 503 = no endpoints, 502 = endpoint refused connection
  (wrong port/crashed), 504 = endpoint too slow (probe/timeout tuning).
- Annotate Ingresses with `nginx.ingress.kubernetes.io/proxy-body-size`,
  `proxy-read-timeout`, etc. at the service level — cluster-wide defaults
  cause cross-team config drift.
- When a host works in one namespace and not another, check
  `kubectl get endpoints` in each — selectors are per-namespace and easy to
  copy-paste incorrectly.
