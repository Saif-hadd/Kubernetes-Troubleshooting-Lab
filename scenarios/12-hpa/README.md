# 12 - HPA (Horizontal Pod Autoscaler)

## Overview

The `HorizontalPodAutoscaler` (HPA) automatically scales the number of Pod
replicas based on observed CPU/memory or custom metrics. When the HPA is not
scaling — or shows `TARGETS <unknown>` / `DESIRED 1` with load rising — the
failure is almost always in the **metrics pipeline**, not the HPA itself. From
an SRE perspective an HPA that does not react is a **hidden capacity
incident**: load climbs, the Service saturates, and the HPA never adds replicas
because it has no signal to scale on.

This scenario reproduces the most common shape: an HPA targeting CPU, but
metrics-server is absent (or the Pods have no `resources.requests`), so the
HPA cannot compute the target ratio and shows `<unknown>`.

## Symptoms

```bash
kubectl get hpa -n ktslab
```

```
NAME      REFERENCE              TARGETS        MINPODS   MAXPODS   REPLICAS   AGE
api       Deployment/api         <unknown>/80%  2         10        2          3m
```

`<unknown>` is the signature of a broken metrics source. Even under heavy load
the replica count stays at `MINPODS`.

```bash
kubectl describe hpa -n ktslab api
```

```
Conditions:
  Type            Status  Reason            Message
  ----            ------  ------            -------
  AbleToScale     True    ReadyForNewScale  …
  ScalingActive   False   FailedGetResourceMetric …
```

```
Events:
  Type     Reason                      Age   From                       Message
  ----     ------                      ----  ----                       -------
  Warning  FailedGetResourceMetric     3m    horizontal-pod-autoscaler  unable to get metrics for resource cpu: no metrics returned …
```

## Root Cause

The HPA computes `desiredReplicas = currentReplicas * (currentMetric / target)`.
To get `currentMetric` for CPU it queries the resource metrics API
(`metrics.k8s.io`), which is served by **metrics-server**. In this scenario
metrics-server is not installed, so the API returns no data and the HPA cannot
compute a ratio — it freezes at `MINPODS` and reports `<unknown>`.

A second, equally common root cause: the target Pods have **no
`resources.requests`** set. CPU-based HPA scales on *relative* CPU
(`usage / request`); with no request, the ratio is undefined and the HPA again
shows `<unknown>`.

## Diagnosis

### 1. Inspect the HPA target and state

```bash
kubectl get hpa -n ktslab -o wide
kubectl describe hpa -n ktslab api
```

Look at `TARGETS` and `Conditions`/`Events`:

- `<unknown>/80%` → metrics pipeline broken (this scenario).
- `0%/80%` with replicas frozen → Pods not generating load, or CPU limit
  throttling capping usage (see scenario 05).
- `10000%/80%` with replicas stuck at `MAXPODS` → load is real, cap reached.

### 2. Check that metrics-server is running

```bash
kubectl get apiservice | grep metrics
kubectl get pods -n kube-system | grep -i metrics-server
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes
```

If the `v1beta1.metrics.k8s.io` APIService is `False (ServiceUnavailable)` or
the raw call errors, metrics-server is missing or unhealthy — the root cause.

### 3. Verify the target Pods have resource requests

```bash
kubectl get deployment -n ktslab api -o jsonpath='{.spec.template.spec.containers[*].resources}'
```

CPU HPA requires `resources.requests.cpu` on every container; without it the
ratio is undefined.

### 4. Check the HPA's scale target reference

```bash
kubectl get hpa -n ktslab api -o jsonpath='{.spec.scaleTargetRef}'
```

`kind/name` must match a real Deployment/StatefulSet.

### 5. Confirm metrics-server can scrape the kubelet

```bash
kubectl logs -n kube-system <metrics-server-pod> --tail=30
```

Common errors: `x509: cannot validate certificate`, `connection refused`,
`node metrics not available`. metrics-server must reach the kubelet on
`10250` and often needs `--kubelet-insecure-tls` in lab clusters.

### 6. Test custom metrics (if the HPA uses them)

```bash
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/namespaces/ktslab/pods/*/cpu_usage
```

Custom-metric HPAs require a separate adapter (Prometheus Adapter). If this
errors, the adapter is missing or the metric name is wrong.

### 7. Generate real load and watch

```bash
kubectl run loadgen --rm -it --image=busybox --restart=Never -- \
  /bin/sh -c 'while true; do wget -qO- http://api.ktslab.svc.cluster.local/; done'
kubectl get hpa -n ktslab api -w
```

If `CURRENT` stays `unknown` under load, metrics are not flowing.

## Resolution

### Fix A — Install metrics-server

Minikube:

```bash
minikube addons enable metrics-server
```

Kind/any cluster:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

In lab clusters, add `--kubelet-insecure-tls` to the metrics-server args.

### Fix B — Add resource requests to the target Pods

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
```

Without `requests.cpu`, CPU-based HPA cannot compute a ratio.

### Fix C — Fix metrics-server scraping

Common fixes: allow metrics-server's ServiceAccount in
`system:auth-delegator`, ensure the kubelet serving cert is signed by the
cluster CA, or set `--kubelet-insecure-tls` for lab kubelets with self-signed
certs.

### Fix D — Use a custom metrics adapter for non-CPU scaling

For scaling on QPS/latency, install the Prometheus Adapter and configure it to
expose your custom metrics, then point the HPA at them.

### Verify

```bash
kubectl top pods -n ktslab
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/ktslab/pods/api
kubectl get hpa -n ktslab api -w
```

`TARGETS` should show numeric values and `REPLICAS` should rise under load.

## Best Practices

- **Always set `resources.requests`** on HPA-scaled workloads — CPU HPA is
  ratio-based and undefined without a request.
- **Deploy metrics-server in every cluster** that uses resource-metric HPAs;
  validate the `v1beta1.metrics.k8s.io` APIService is `True`.
- **Prefer custom/external metrics for service scaling** (QPS, queue depth,
  latency) — CPU is a lagging signal and correlates poorly with user-facing
  load.
- **Set sensible `minReplicas` and `maxReplicas`** bounds; an unbounded
  `maxReplicas` can drain a cluster, and `minReplicas: 0` requires
  scale-to-zero support.
- **Use a stabilization window** (`behavior.scaleDown.stabilizationWindowSeconds`)
  to avoid flapping under bursty traffic.
- **Monitor the HPA itself** — alert when `TARGETS` is `<unknown>` for > 5m;
  that is a silently broken autoscaler.

## Production Tips

- CPU throttling (scenario 05) breaks HPA: a throttled Pod reports usage
  pinned at its limit, so the HPA sees `100%` and scales, but the new Pods
  also throttle and the loop never converges. Remove CPU limits or raise them
  when using CPU-based HPA.
- The default scale-down stabilization is 5 minutes; for spiky services this
  causes oscillation. Tune `behavior` to a longer window and a percentile-based
  policy to scale down gently.
- metrics-server is point-in-time only and not a monitoring system. Use it for
  HPA; use Prometheus + cAdvisor/node-exporter for dashboards and alerting.
- An HPA with `TARGETS <unknown>` in production is a tier-1 alert — your
  autoscaler is effectively off. Wire it into alerting on
  `hpa_status_condition{condition="ScalingActive",status="false"}`.
- On EKS, metrics-server must reach the kubelet over the VPC; security groups
  and the `--kubelet-preferred-address-types=InternalIP` flag matter. A
  metrics-server that cannot scrape silently breaks every resource HPA.
- For scale-to-zero with KEDA or HPA v2 + idle, ensure the
  `scaleDown.stabilizationWindowSeconds` and `policies` are set so the service
  does not thrash between 0 and 1 replicas on a single request.
