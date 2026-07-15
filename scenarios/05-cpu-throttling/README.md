# 05 - CPU Throttling

## Overview

CPU throttling is **not** a Pod status — the Pod stays `Running` and `READY`
the whole time. Instead, the kernel's CFS bandwidth control prevents the
container from using more CPU than its `resources.limits.cpu` within each
quota period (default 100ms). When the container exhausts its quota mid-period,
the kernel suspends it until the next period. From an SRE perspective this is a
**latent latency bug**: throughput looks fine at low load, but tail latency
spikes and requests time out once the workload bursts.

This is one of the most misdiagnosed production issues because the Pod appears
completely healthy in `kubectl get` — the damage only shows up in latency SLOs
and in the throttling metric.

This scenario reproduces throttling with a CPU-bursting workload pinned to a
low CPU limit.

## Symptoms

```bash
kubectl get pods -n ktslab
```

```
NAME                          READY   STATUS    RESTARTS   AGE
api-burst-7c9d4f6b8b-x5y6z    1/1     Running   0          3m
```

Everything looks healthy. The symptom appears in application metrics and
latency, not in Pod status:

```bash
kubectl exec -n ktslab api-burst-7c9d4f6b8b-x5y6z -- \
  cat /sys/fs/cgroup/cpu.stat
```

```
nr_periods 12453
nr_throttled 8421
throttled_time 4123456789
```

`nr_throttled` climbing steadily and `throttled_time` growing = the container
is being repeatedly suspended by CFS.

The user-visible symptom is high tail latency:

```
curl: (28) Operation timed out after 30000 milliseconds
# or
GET /healthz  p99=2.4s  p50=40ms   # huge gap = throttling signature
```

## Root Cause

The container has `resources.limits.cpu: 50m` (5% of a core) but bursts to
~200m under load. CFS gives the container 5ms of CPU every 100ms period. Once
those 5ms are consumed, the container is frozen for the remaining 95ms. So
even on an idle node with plenty of free CPU, the container is artificially
capped at 50m and spends most of each period suspended — producing 20x tail
latency on bursty requests.

The key insight: **a CPU limit caps burst capacity even when the node is idle.**
Unlike memory limits (which protect neighbors), CPU limits purely shape
scheduling and rarely improve node stability in modern kernels.

## Diagnosis

### 1. Confirm the Pod is healthy but slow

```bash
kubectl get pods -n ktslab -l app=api-burst -o wide
kubectl exec -n ktslab <pod> -- wget -qO- http://localhost:8080/healthz
```

If the healthz is slow but the Pod is `Running`, suspect throttling.

### 2. Read cgroup throttling stats

On cgroup v2 (modern nodes):

```bash
kubectl exec -n ktslab <pod> -- cat /sys/fs/cgroup/cpu.stat
```

On cgroup v1:

```bash
kubectl exec -n ktslab <pod> -- cat /sys/fs/cgroup/cpu/cpu.stat
```

`nr_throttled` and `throttled_time` are the smoking gun. Compare
`nr_throttled / nr_periods` — a ratio above ~25% is significant.

### 3. Compare usage to the limit

```bash
kubectl top pods -n ktslab --sort-by=cpu
kubectl top pod -n ktslab <pod> --containers
```

If usage is pinned at the limit (e.g. `50m` on a `50m` limit) while latency
spikes, the limit is the bottleneck.

### 4. Inspect the limit

```bash
kubectl get pod -n ktslab <pod> -o yaml | grep -A6 resources
```

### 5. Correlate with latency metrics

In Prometheus, the canonical metric is:

```
container_cpu_cfs_throttled_periods_total /
container_cpu_cfs_periods_total
```

A ratio > 0.25 sustained is a throttling incident.

### 6. Rule out node-level CPU contention

```bash
kubectl top nodes
kubectl describe node <node>
```

If the node itself is not saturated, the throttle is purely the container's
own limit, not cluster pressure.

## Resolution

### Fix A — Raise or remove the CPU limit

```yaml
resources:
  requests:
    cpu: 250m
    memory: 128Mi
  # No CPU limit: allow bursting on idle node capacity.
  limits:
    memory: 256Mi
```

Removing the CPU limit lets the container burst into idle node CPU, which is
the modern best practice for latency-sensitive services. Keep the **request**
for scheduling.

### Fix B — Raise the limit if you must keep one

```yaml
limits:
  cpu: 1000m
```

For batch workloads where you want to bound CPU, set a generous limit aligned
to real burst needs.

### Fix C — Tune the CFS quota period (advanced, rarely needed)

Increasing `cpu.cfs_period_us` reduces throttle frequency but is rarely worth
the complexity; prefer removing the limit.

### Verify

```bash
kubectl top pod -n ktslab <pod>
kubectl exec -n ktslab <pod> -- cat /sys/fs/cgroup/cpu.stat
```

`nr_throttled` should stop growing, and tail latency should drop.

## Best Practices

- **Do not set CPU limits on latency-sensitive services.** Set a `request`
  for scheduling and let the container burst into idle node CPU. This is the
  single most impactful change for tail latency in Kubernetes.
- **Always set CPU `requests`** so the scheduler places Pods honestly and the
  Pod gets a fair CFS share under contention.
- **Keep memory limits** (they protect neighbors), but treat CPU limits as
  optional and workload-specific.
- **Monitor `container_cpu_cfs_throttled_periods_total`** as a primary SLO
  signal. Throttling directly inflates p99 latency.
- **Profile burst needs** before setting any limit. A limit below peak burst
  guarantees throttling on an idle node.
- **Batch workloads may keep CPU limits** to bound cost, but accept the
  throughput tradeoff.

## Production Tips

- The "throttling on an idle node" trap surprises most teams. A service can
  be p99-500ms on a 16-core idle node purely because of a `100m` limit. Remove
  the limit and p99 drops to 40ms with no other change.
- Google's GKE workload throttling recommendations and the wider community
  converge on: **set CPU requests, omit CPU limits** for services. Measure
  before and after.
- If you keep CPU limits for cost control on multi-tenant clusters, set them
  generously (2-4x request) and alert on throttle ratio, not just usage.
- Throttling interacts badly with HPA: the HPA scales on average usage, but
  throttled containers report usage near the limit, which can cause the HPA
  to either stall (capped) or overshoot. See scenario 12.
- JVM/Go warmup and GC bursts commonly trip tight CPU limits. If a service
  is slow *only* during startup or GC, suspect throttling rather than the app.
- Use `kubectl top` only as a quick check. Its 1-minute window hides
  sub-second throttle bursts — use cAdvisor/Prometheus at 15-30s resolution.
