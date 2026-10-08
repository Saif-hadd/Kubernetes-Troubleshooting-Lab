# 16 - InitContainer failure

## Overview

An **init container** runs to completion before any of the Pod's app
containers start. If it fails, the Pod never reaches the app container: you
see `Init:Error`, `Init:CrashLoopBackOff` or `Init:0/N` and the `STATUS` of the
main container is invisible because it has not started at all. This is a
distinct failure mode from a `CrashLoopBackOff` of the app container, and it
trips up operators because the Pod status looks "almost running".

From an SRE perspective an init container that fails is either a **broken
prerequisite** (a dependency that is not up, a config that is missing, a
permission that is denied) or a **broken init script** — a `command`/`args`
that exits non-zero instead of waiting.

This scenario reproduces the classic shape: an init container that checks a
dependency and exits `1` on the first failure instead of retrying, so the Pod
never starts.

## Symptoms

```bash
kubectl get pods -n ktslab
```

```
NAME                     READY   STATUS                  RESTARTS      AGE
webapp-7c9d4f6b8b-1      0/1     Init:CrashLoopBackOff   4 (30s ago)   2m
```

Note that `RESTARTS` refers to the *init* container here. The main container
has never run.

```bash
kubectl describe pod -n ktslab webapp-7c9d4f6b8b-1
```

```
Init Containers:
  wait-for-db:
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
    Ready:          False
    Restart Count:  4
```

Events:

```
Warning  BackOff  kubelet  Back-off restarting failed container wait-for-db
```

## Root Cause

The init container runs a check and exits `1` as soon as it fails:

```sh
if ! nslookup migrate-db.ktslab.svc.cluster.local; then
  exit 1
fi
```

The dependency does not exist yet, so the check fails on every attempt. Because
the init container exits non-zero, the kubelet restarts it with exponential
backoff, the Pod never gets past `Init:*`, and the app container is never
created.

The scenario's lesson: **an init container should wait, not fail fast.** It is
the correct mechanism to block startup on a dependency — it just has to loop
until the dependency is ready, rather than exiting on the first attempt.

Other common init-container root causes:

- A missing ConfigMap/Secret referenced by the init container → `CreateContainerConfigError`.
- A command/binary that does not exist → exit `127`.
- A migration job that genuinely fails (bad SQL, missing permission).
- A `runAsUser`/fsGroup mismatch so the init container cannot write its volume.

## Diagnosis

### 1. Confirm it is the *init* container, not the app container

```bash
kubectl get pods -n ktslab
kubectl describe pod -n ktslab <pod> | sed -n '/Init Containers:/,/Containers:/p'
```

`Init:` in the `STATUS` column and an `Init Containers:` block with a non-zero
`Exit Code` are the tell. The main container shows no state.

### 2. Read the init container's logs

```bash
kubectl logs -n ktslab <pod> -c wait-for-db --previous
```

This shows exactly why the init script failed (the dependency message, a
permission error, a missing file).

### 3. Check the events

```bash
kubectl get events -n ktslab --field-selector involvedObject.name=<pod> --sort-by=.lastTimestamp
```

### 4. Identify the dependency the init container is waiting for

```bash
kubectl get svc,endpointslice -n ktslab
```

If the init container waits for a Service that does not exist (or has no
Endpoints), the dependency — not the init container — is the real problem.

## Resolution

### Fix A — Make the init container retry instead of exiting

Loop until the dependency is ready:

```sh
until nslookup migrate-db.ktslab.svc.cluster.local; do
  echo "dependency not ready, retrying in 2s"
  sleep 2
done
```

See [`deployment-fixed.yaml`](deployment-fixed.yaml).

### Fix B — Fix the real dependency

If the init container is waiting for a Service/Secret/ConfigMap that should
exist, create or fix that object. The init container is doing its job.

### Fix C — Fix a genuinely failing init task

If the init container runs a migration or a data load that fails, fix the task
itself (the SQL, the credentials, the permissions), not the retry behaviour.

### Verify

```bash
kubectl apply -f scenarios/16-initcontainer-failure/deployment-fixed.yaml
kubectl get pods -n ktslab -w
```

With the fix, the Pod no longer crash-loops: it sits in `Init:0/1` while it
**waits**. Create the dependency to see it complete, then watch the Pod move to
`Running` with `READY 1/1`:

```bash
kubectl -n ktslab create deployment migrate-db --image=busybox:1.36 -- sleep 3600
kubectl -n ktslab expose deployment migrate-db --port=5432 --name=migrate-db
kubectl get pods -n ktslab -w
```

## Best Practices

- **Init containers should wait, not fail fast.** A dependency check that exits
  on the first miss turns a slow start into a permanent crash loop.
- **Bound the wait.** An unbounded `until true; do sleep; done` hides a
  dependency that will never come up — add a maximum retry count and a clear
  error, or use a `startupProbe` with a generous `failureThreshold` instead.
- **Keep init containers small and single-purpose.** One dependency per init
  container makes the failure obvious in `kubectl describe`.
- **Give init containers resource requests/limits** too; they are scheduled
  with the Pod and their requests count toward node capacity.
- **Prefer a per-attempt timeout** (`wget -T3`, `nc -w 3`) so a hung check does
  not block the init phase forever.

## Production Tips

- `Init:CrashLoopBackOff` and `CrashLoopBackOff` have the same backoff
  behaviour but a completely different triage path: check the `Init Containers`
  block first, and remember the app container's `RESTARTS` stays `0`.
- A Pod stuck at `Init:0/N` for a long time (not crash-looping) is usually
  waiting on a slow dependency, not failing — it will start once the
  dependency is up. Distinguish "waiting" from "failing".
- If many Pods across a namespace stall in `Init:*` at the same time, suspect a
  shared dependency (CoreDNS, an external database, a shared ConfigMap) rather
  than the workloads themselves.
- For schema migrations, prefer a dedicated `Job` (with `backoffLimit`) over an
  init container when the migration is long-running or must run once per
  rollout, and gate the rollout on the Job's success in CI/CD.
