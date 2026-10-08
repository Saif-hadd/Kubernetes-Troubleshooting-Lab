# 25 - Metrics server scrape failure

## Overview

A resource-based `HorizontalPodAutoscaler` reads CPU/memory from the
`metrics.k8s.io` API, which is served by **metrics-server**. metrics-server, in
turn, **scrapes the kubelet** on every node. If the scrape fails, the metrics
API returns no data and the HPA reports `TARGETS <unknown>` and never scales —
even though metrics-server is installed and "Running".

This is a distinct failure from scenario 12 (metrics-server *absent*): here the
component exists but cannot do its job. From an SRE perspective it is a
**break in the metrics pipeline between the kubelet and metrics-server** —
usually a TLS/certificate problem or an RBAC/network issue — and it silently
disables autoscaling.

## Symptoms

```bash
kubectl get hpa -n ktslab
```

```
NAME   REFERENCE        TARGETS        MINPODS   MAXPODS   REPLICAS
api    Deployment/api   <unknown>/80%  2        10       2
```

`metrics-server` is installed and Running, yet:

```bash
kubectl top nodes
```

```
error: Metrics API not available
```

## Root Cause

metrics-server aggregates metrics by calling each kubelet's Summary API over
HTTPS on port **10250**. The scrape fails when:

- **The kubelet's serving certificate is not trusted** by metrics-server
  (self-signed / not signed by the cluster CA). This is the #1 lab cause;
  `--kubelet-insecure-tls` is the standard lab workaround.
- **RBAC is missing**: metrics-server's ServiceAccount lacks
  `system:auth-delegator` (or the APIService registration lacks the right
  permissions), so the API aggregation fails.
- **Wrong kubelet address**: metrics-server cannot reach the node's kubelet IP
  (`--kubelet-preferred-address-types`, node address selection).
- **Network / firewall** blocks port 10250.
- **The node has not reported yet** (a freshly joined, NotReady node).
- **The APIService is unavailable**, so even successful scrapes are not served
  (`v1beta1.metrics.k8s.io` shows `False`).

## Diagnosis

### 1. Confirm the HPA is the symptom, not the cause

```bash
kubectl -n ktslab describe hpa api | sed -n '/Conditions:/,$p'
```

`ScalingActive=False` with `FailedGetResourceMetric` confirms it is the metrics
pipeline, not the HPA.

### 2. Check the metrics APIService and the component

```bash
./scenarios/25-metrics-scrape-failure/diagnose.sh ktslab
kubectl get apiservice v1beta1.metrics.k8s.io -o wide       # must be True
kubectl -n kube-system get pods -l k8s-app=metrics-server
```

### 3. Read the metrics-server logs — the critical step

```bash
kubectl -n kube-system logs -l k8s-app=metrics-server --tail=80
```

Look for `x509: cannot validate certificate`, `connection refused`,
`forbidden`, `unable to fully scrape metrics`, `node metrics not available`.
These messages name the failing node and the reason.

### 4. Query the API directly

```bash
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/ktslab/pods
```

An error here (or an empty list) confirms the scrape path.

### 5. Rule out a missing `requests.cpu`

```bash
kubectl -n ktslab get deployment api -o jsonpath='{.spec.template.spec.containers[*].resources}'
```

If `requests.cpu` is absent, that — not the scrape — is the cause (see
scenario 12). This scenario assumes the request is present.

## Resolution

### Fix A — Trust the kubelet certificate (or bypass it in labs)

Lab/short-lived:

```bash
kubectl -n kube-system patch deployment metrics-server --type=strategic -p \
'{"spec":{"template":{"spec":{"containers":[{"name":"metrics-server","args":["--cert-dir=/tmp","--secure-port=10250","--kubelet-preferred-address-types=InternalIP,Hostname","--kubelet-use-node-status-port","--metric-resolution=15s","--kubelet-insecure-tls"]}]}}}}'
```

Production: install the cluster CA into metrics-server's trust bundle instead of
disabling verification (the same patch, minus `--kubelet-insecure-tls`).

### Fix B — Fix RBAC / the APIService

Ensure metrics-server's ServiceAccount can delegate authentication and the
APIService is registered and `True`:

```bash
kubectl get clusterrolebinding | grep -i metrics
kubectl get apiservice v1beta1.metrics.k8s.io -o yaml | grep -A5 status
```

### Fix C — Fix the kubelet address / network

Set `--kubelet-preferred-address-types=InternalIP` and confirm port 10250 is
reachable from the metrics-server Pod.

### Fix D — Ensure the node has reported

A NotReady or freshly joined node has no metrics; wait for it to become Ready.

### Verify

```bash
kubectl top nodes
kubectl top pods -n ktslab
kubectl get hpa -n ktslab api        # TARGETS shows a number, not <unknown>
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes | head -c 200
```

## Best Practices

- **Alert on `TARGETS <unknown>` for more than ~5 minutes** — an autoscaler with
  no metrics is effectively off, and nothing else will tell you.
- **Do not rely on `--kubelet-insecure-tls` in production**; trust the real
  kubelet CA so the metrics path is authenticated.
- **Verify `v1beta1.metrics.k8s.io` is `True`** as part of cluster health; a
  `False` APIService breaks *every* resource HPA, cluster-wide.
- **Budget metrics-server resources.** Under many nodes it can be CPU-bound and
  its scrapes time out (which looks exactly like this failure).
- **Keep metrics-server compatible** with your Kubernetes version; the kubelet
  Summary API and flags evolve.

## Production Tips

- "HPA stopped scaling" with `metrics-server` Running is the scrape, not the
  HPA: always read the metrics-server logs before touching the HPA.
- `--kubelet-insecure-tls` is the fastest lab fix and the wrong production one;
  it hides a real trust problem and should never ship to a managed cluster.
- A `False (ServiceUnavailable)` APIService with a healthy metrics-server Pod
  usually means the API aggregation layer cannot reach it — check the Service,
  Endpoints, and the APIService's `spec.service`.
- metrics-server is point-in-time and not a monitoring system; if you need
  history/alerting, run Prometheus (cAdvisor/node-exporter) alongside it.
- If only *some* nodes are missing from `kubectl top nodes`, the scrape is
  failing per-node (address/TLS/firewall), not cluster-wide — compare the
  failing nodes' kubelet endpoints.
