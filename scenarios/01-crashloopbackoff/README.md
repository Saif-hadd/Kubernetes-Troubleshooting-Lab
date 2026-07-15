# 01 - CrashLoopBackOff

## Overview

`CrashLoopBackOff` is one of the most common Pod states in Kubernetes. It is
**not itself an error** — it is the kubelet's exponential-backoff state for a
container that keeps exiting and being restarted. The real failure is almost
always inside the container: a bad command, a missing config file, a failed
dependency check, or an application that throws on startup.

From an SRE perspective, `CrashLoopBackOff` means: **the workload cannot reach
a steady state on its own, and each restart is wasted compute and noise.** It
directly degrades the Service's ready endpoint count and, if a PodDisruptionBudget
or HPA is attached, can cascade into a capacity incident.

This scenario reproduces the classic shape of the problem: a container that
exits non-zero on startup because of a missing required environment variable.

## Symptoms

```bash
kubectl get pods -n ktslab
```

```
NAME                        READY   STATUS             RESTARTS      AGE
webapp-6b8d9f7c6d-x2k9p     0/1     CrashLoopBackOff   5 (2m ago)    4m
```

```bash
kubectl describe pod -n ktslab webapp-6b8d9f7c6d-x2k9p
```

Key sections of the output:

```
Containers:
  webapp:
    Container ID:   containerd://…
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      …
      Finished:     …
    Ready:          False
    Restart Count:  5
```

```
Events:
  Type     Reason     Age                  From     Message
  ----     ------     ----                 ----     -------
  Normal   Scheduled  4m                   …        Successfully assigned …
  Normal   Created    4m (x3 over 4m)      kubelet  Created container webapp
  Normal   Started    4m (x3 over 4m)      kubelet  Started container webapp
  Warning  BackOff    2m (x8 over 4m)      kubelet  Back-off restarting failed container
```

```bash
kubectl logs -n ktslab webapp-6b8d9f7c6d-x2k9p --previous
```

```
Error: DATABASE_URL environment variable is required.
Usage: webapp [--config path]
exit status 1
```

## Root Cause

The container's entrypoint validates required configuration on startup and
exits with code `1` when `DATABASE_URL` is unset. The kubelet restarts the
container according to the `restartPolicy: Always`, observes the repeated
failure, and transitions the Pod to `CrashLoopBackOff` with an exponential
backoff (10s, 20s, 40s … capped at 5 minutes).

The failure is **application-level**, not infrastructure-level: the scheduler
placed the Pod, the image pulled, the container started — it simply cannot
stay running because of missing configuration.

## Diagnosis

### 1. Confirm the Pod state and restart count

```bash
kubectl get pods -n ktslab -o wide
kubectl get pods -n ktslab \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'
```

A rising `RESTARTS` count with `CrashLoopBackOff` confirms a chronic restart
loop, not a one-off.

### 2. Inspect the last termination

```bash
kubectl describe pod -n ktslab <pod>
```

Look at `Containers → Last State`:

- `Reason: Error` + `Exit Code: 1` → application error (config, code, dependency).
- `Exit Code: 127` → command/binary not found.
- `Exit Code: 137` → OOMKilled or SIGKILL (see scenario 04).
- `Exit Code: 139` → SIGSEGV, a segfault in the binary.
- `Exit Code: 255` → generic, often a preStop hook or liveness probe exit.

### 3. Read the crashed container's logs

`kubectl logs` shows the current (restarting) container; you usually want the
**previous** instance:

```bash
kubectl logs -n ktslab <pod> --previous
kubectl logs -n ktslab <pod> --previous --tail=50
kubectl logs -n ktslab <pod> -c <container> --previous
```

If the logs are empty, the app may be writing to a file instead of stdout, or
crashing before the logger initializes. Try:

```bash
kubectl exec -n ktslab <pod> -- /bin/sh -c 'cat /var/log/app.log'
```

### 4. Check the events timeline

```bash
kubectl get events -n ktslab --sort-by=.lastTimestamp
kubectl get events -n ktslab --field-selector reason=BackOff
```

### 5. Verify the runtime config inside the Pod (if it stays up briefly)

```bash
kubectl exec -it -n ktslab <pod> -- env
kubectl exec -it -n ktslab <pod> -- /bin/sh
```

If the Pod crashes too fast for `exec`, use an ephemeral debug container:

```bash
kubectl debug -it -n ktslab <pod> --image=busybox --target=webapp
```

## Resolution

### Fix A — Provide the missing environment variable

The most direct fix: supply `DATABASE_URL` via a Secret or ConfigMap.

```yaml
env:
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: webapp-db
        key: url
```

```bash
kubectl create secret generic webapp-db -n ktslab \
  --from-literal=url='postgres://app:pass@db:5432/appdb'
kubectl rollout restart deployment/webapp -n ktslab
```

### Fix B — Correct the entrypoint arguments

If the crash is caused by a bad command/args, fix the `command`/`args` in the
container spec or the underlying image.

### Fix C — Fix the application code

If the error is an exception in the app itself, ship a new image and roll:

```bash
kubectl set image deployment/webapp webapp=registry/webapp:v2 -n ktslab
kubectl rollout status deployment/webapp -n ktslab
```

### Fix D — Temporarily relax the startup check

If a dependency (e.g. database) is not yet up, add a proper `startupProbe`
with `failureThreshold` high enough to wait for the dependency, rather than
relying on container restarts as a retry mechanism.

### Verify

```bash
kubectl rollout status deployment/webapp -n ktslab
kubectl get pods -n ktslab -l app=webapp
kubectl logs -n ktslab -l app=webapp --tail=20
```

## Best Practices

- **Never use container restarts as a retry mechanism.** Use `startupProbe`
  with an adequate `failureThreshold` for slow-to-start workloads.
- **Always read the previous container's logs** during triage; the current
  container may not have produced output yet.
- **Set `restartPolicy: Always` for Deployments** (required) but monitor
  restart count as a KPI — chronic restarts are a reliability smell.
- **Fail fast with clear messages.** Entrypoints should print *what* is
  missing (which env var, which file) before exiting.
- **Keep startup dependencies explicit** — use init containers or
  `startupProbe` rather than implicit ordering via crash loops.
- **Capture events early.** Events expire after ~1 hour; export them during
  an incident with `kubectl get events --sort-by=.lastTimestamp`.

## Production Tips

- Wire `RESTARTS` and `CrashLoopBackOff` counts into your alerting. A Pod
  restarting > 3 times in 10 minutes is a page, not a log.
- Correlate `CrashLoopBackOff` with a recent rollout: a spike right after a
  deploy points to the new image/config, not the node.
- Treat `Exit Code` as a first-class signal in your runbook. Mapping exit
  codes to causes (1=config, 127=missing binary, 137=OOM, 139=segfault)
  collapses triage time dramatically.
- In multi-replica Deployments, a single Pod in `CrashLoopBackOff` while
  siblings are Running often indicates a stale ReplicaSet during a rollout —
  check `kubectl get rs` and rollout status before deep-diving one Pod.
- For jobs that legitimately exit, use `Job`/`CronJob` with
  `restartPolicy: OnFailure` or `Never` and `backoffLimit` to avoid the
  kubelet retrying forever.
