# 04 - OOMKilled

## Overview

`OOMKilled` is the kernel-level termination of a container that exceeded its
memory limit. Unlike a crash, the container never gets a chance to handle the
condition — the cgroup OOM killer sends `SIGKILL` (exit code `137`) and the
container dies instantly. From an SRE perspective this is a **hard resource
boundary** failure: the limit was correct (or too low) and the workload's
memory footprint breached it.

The crucial subtlety: there are two distinct OOM killers in play:

1. **cgroup OOM killer** — kills the container when it exceeds its own
   `resources.limits.memory`. Pod shows `Reason: OOMKilled`, exit `137`.
   This is the common case.
2. **System (node) OOM killer** — kills a process when the *node* runs out of
   memory. Node shows `MemoryPressure`, and the kubelet may evict Pods. This
   is a node-level incident (see scenario 06).

This scenario reproduces the cgroup case: a workload that allocates memory in a
loop until it crosses the limit.

## Symptoms

```bash
kubectl get pods -n ktslab
```

```
NAME                          READY   STATUS      RESTARTS   AGE
memory-hog-7d8c5b9f6d-a3b2c   0/1     OOMKilled   3 (1m ago) 5m
```

`STATUS` may alternate between `Running` and `OOMKilled` on each restart.

```bash
kubectl describe pod -n ktslab memory-hog-7d8c5b9f6d-a3b2c
```

```
Containers:
  memory-hog:
    State:          Terminated
      Reason:       OOMKilled
      Exit Code:    137
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      …
      Finished:     …
    Ready:          False
    Restart Count:  3
```

```
Events:
  Type     Reason      Age   From     Message
  ----     ------      ----  ----     -------
  Warning  BackOff     1m    kubelet  Back-off restarting failed container
```

Note: `kubectl logs --previous` is usually **empty** for an OOMKilled
container — the process was killed before it could flush.

## Root Cause

The container allocates memory in a loop without releasing it (a simulated
leak). Once the resident set exceeds the `resources.limits.memory` (here
`128Mi`), the kernel cgroup OOM killer sends `SIGKILL`. Exit code `137`
= `128 + 9` (SIGKILL). The kubelet restarts the container per
`restartPolicy: Always`, and the leak repeats — a `CrashLoopBackOff`-like
cycle but with `OOMKilled` as the reason.

## Diagnosis

### 1. Confirm OOMKilled and the exit code

```bash
kubectl describe pod -n ktslab <pod>
kubectl get pod -n ktslab <pod> -o jsonpath='{.status.containerStatuses[0].lastState}'
```

Look for `reason: OOMKilled`, `exitCode: 137`.

### 2. Distinguish container OOM from node OOM

```bash
kubectl describe node <node>
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="MemoryPressure")].status}{"\n"}{end}'
```

If the node shows `MemoryPressure=True`, it is a node-level OOM/eviction — a
different fix path (see scenario 06). If the node is fine and only the Pod is
OOMKilled, it is a container-limit issue.

### 3. Compare actual usage against the limit

```bash
kubectl top pods -n ktslab --sort-by=memory
kubectl top pod -n ktslab <pod> --containers
```

If `kubectl top` shows usage near the limit right before each death, the limit
is too low or the workload genuinely leaks.

### 4. Check whether the limit is realistic

```bash
kubectl get pod -n ktslab <pod> -o yaml | grep -A6 resources
```

### 5. Profile the container's memory (if it stays up long enough)

```bash
kubectl exec -n ktslab <pod> -- cat /proc/1/status | grep -i vmsize
kubectl exec -n ktslab <pod> -- cat /proc/meminfo | head
```

For a deeper view, use a debug container or node-level `crictl stats`.

### 6. Check for a leak over time

Collect `kubectl top pod` samples over minutes; a monotonic climb toward the
limit indicates a leak, not a fixed under-provisioning.

## Resolution

### Fix A — Raise the memory limit (if the workload is legitimately larger)

```yaml
resources:
  requests:
    memory: 256Mi
  limits:
    memory: 512Mi
```

This is the right fix when the limit was simply too low. Confirm the node can
actually satisfy the new request.

### Fix B — Fix the memory leak (if usage climbs unbounded)

If `kubectl top` shows a monotonic climb, the application is leaking. Raise
the limit as a stopgap, but the real fix is in the application (GC tuning,
fixing retained references, profiling).

### Fix C — Set requests == limits for Guaranteed QoS

For latency-sensitive or stateful workloads, set `requests == limits` to get
Guaranteed QoS — these Pods are last to be evicted under node pressure and
get predictable memory.

### Fix D — Add a liveness or restart strategy that bounds impact

If the leak is known and slow, accept periodic restarts but bound the blast
radius with a PDB and multiple replicas so rolling restarts stay available.

### Verify

```bash
kubectl rollout status deployment/memory-hog -n ktslab
kubectl top pods -n ktslab -l app=memory-hog
kubectl get pods -n ktslab -l app=memory-hog
```

`RESTARTS` should stop climbing and usage should stabilize under the limit.

## Best Practices

- **Always set memory requests and limits.** Without a limit, a single
  container can OOM the entire node and take down neighbors.
- **Set requests == limits (Guaranteed QoS)** for anything you care about —
  these Pods are killed last under node memory pressure.
- **Monitor `container_oom_events_total` and `RSS` trends**, not just
  current usage. A slow climb is a leak even before the first OOM.
- **Never set `limits.memory` lower than the app's steady-state RSS** — you
  are guaranteeing an OOM. Profile first, then set.
- **Use `kubectl top` with metrics-server** for point-in-time; use a real
  metrics pipeline (Prometheus + node-exporter/cAdvisor) for trends.
- **Treat exit code 137 as OOM until proven otherwise** — it can also be a
  deliberate `SIGKILL` from a preStop hook or an eviction, so check the reason
  field, not just the code.

## Production Tips

- Memory leaks are the #1 cause of chronic OOMKilled loops in JVM/Go/Python
  services. Establish a baseline RSS per service and alert on deviation, not
  on hitting the limit.
- For JVM workloads, set `-XX:MaxRAMPercentage` so the heap respects the
  cgroup limit; the JVM ignoring cgroup limits is a classic OOM trap.
- Overcommitting memory (sum of limits > node memory) is fine for Burstable
  workloads but guarantees evictions under pressure. Track the
  `memory_request/limit to capacity` ratio per node pool.
- Node-level OOM (eviction) and container-level OOM have different runbooks.
  Always check `kubectl describe node` conditions before changing a Pod's
  limit — raising a limit during node pressure makes things worse.
- When a Pod is OOMKilled but `kubectl top` never showed high usage, suspect
  a spike (e.g. loading a large file, fork+exec) that crossed the limit
  between metric scrapes. A higher limit or fixing the spike path is needed;
  metrics alone will not show it.
- Keep `requests.memory` close to actual steady-state usage so the scheduler
  packs honestly; a low request + high limit leads to node overcommit and
  evictions that look mysterious.
