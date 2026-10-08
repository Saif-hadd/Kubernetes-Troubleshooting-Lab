# 22 - PodSecurity admission violation

## Overview

**Pod Security Admission (PSA)** enforces the Pod Security Standards
(`privileged`, `baseline`, `restricted`) per namespace, using the labels
`pod-security.kubernetes.io/enforce`. When a namespace enforces `restricted`,
any Pod that does not meet the standard is **rejected at creation** — the
Deployment is accepted, but the Pod is never created, and the ReplicaSet logs a
`FailedCreate` event.

From an SRE perspective this is an **admission** failure: the workload is
fine, but the cluster's security policy refuses to run it. It is also one of
the highest-value *preventive* controls — it stops privileged Pods before they
exist — which is exactly why it surprises teams during a migration.

This scenario reproduces the most common shape: a namespace enforcing
`restricted`, and a Deployment whose Pod runs as root with privileged
capabilities, so every Pod creation is denied.

## Symptoms

```bash
kubectl get pods -n ktslab-restricted
```

```
No resources found in ktslab-restricted namespace.
```

The ReplicaSet reports the denial:

```bash
kubectl -n ktslab-restricted get events --field-selector reason=FailedCreate
```

```
Error creating: pods "privileged-..." is forbidden: violates PodSecurity
"restricted:latest": privileged (container "root" must not set
securityContext.privileged=true), allowPrivilegeEscalation != false,
unrestricted capabilities (container "root" must not include "NET_ADMIN"),
runAsNonRoot != true (pod or container must set securityContext.runAsNonRoot=true),
seccompProfile (pod must set securityContext.seccompProfile.type ...
```

A direct `kubectl apply` is rejected outright:

```
Error from server (Forbidden): error when creating "...": pods "privileged" is
forbidden: violates PodSecurity "restricted:latest": ...
```

## Root Cause

The namespace enforces the `restricted` standard, and the Pod violates one or
more of its requirements:

- `runAsNonRoot: true` is not set (the container may run as root).
- `allowPrivilegeEscalation` is not `false`.
- Capabilities are not dropped to `ALL`.
- `seccompProfile.type` is not set (`RuntimeDefault` or `Localhost`).
- `privileged: true`, host namespaces, or hostPath volumes are used.

PSA rejects **at admission time**, so the Pod object never exists — you will not
find it in `kubectl get pods`, only in the owner's events.

## Diagnosis

### 1. Confirm the namespace's policy

```bash
kubectl get namespace ktslab-restricted -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep pod-security
```

`enforce: restricted` is the policy that is rejecting the Pod.

### 2. Read the exact violation

```bash
kubectl -n ktslab-restricted get events --field-selector reason=FailedCreate --sort-by=.lastTimestamp
kubectl -n ktslab-restricted describe replicaset -l app=privileged | sed -n '/Events:/,$p'
```

The event names every failing field — fix them one by one.

### 3. Test a dry-run before applying

```bash
kubectl apply -f scenarios/22-podsecurity-violation/privileged-pod.yaml --dry-run=server
```

`--dry-run=server` runs admission and returns the violation without creating
anything.

### 4. Check whether a *different* policy is at play

```bash
kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations | grep -i -E 'policy|gatekeeper|kyverno'
```

PSA is built in; some clusters also run OPA/Gatekeeper or Kyverno, which can
reject for separate reasons.

## Resolution

### Fix A — Make the Pod comply with `restricted`

Set the required security context:

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
```

See [`compliant-pod.yaml`](compliant-pod.yaml).

### Fix B — Relax the namespace policy (if the workload genuinely needs it)

Use `baseline` (allows some capabilities, still blocks privileged) or
`privileged` — but do this deliberately and documented, not as a blanket
workaround:

```bash
kubectl label namespace ktslab-restricted \
  pod-security.kubernetes.io/enforce=baseline --overwrite
```

A **better middle ground** is `enforce-version` pinned to the minor you have
tested, plus `warn`/`audit` set to `restricted`, so you see violations without
blocking.

### Fix C — Split privileged workloads into their own namespace

Keep the `restricted` policy for application namespaces and put genuinely
privileged system components (CNI, CSI, node agents) in their own namespace
with a relaxed policy — never the other way around.

### Verify

```bash
kubectl apply -f scenarios/22-podsecurity-violation/compliant-pod.yaml
kubectl get pod -n ktslab-restricted restricted   # Running
kubectl apply -f scenarios/22-podsecurity-violation/privileged-pod.yaml    # Forbidden
```

## Best Practices

- **Adopt PSA in `warn`/`audit` mode first**, fix the violations, then flip to
  `enforce`. A big-bang `enforce: restricted` across a live cluster breaks
  workloads that were running happily.
- **Separate privileged from unprivileged workloads** by namespace; system
  components that need capabilities get their own namespace and policy.
- **Pin `enforce-version`** so a Kubernetes upgrade does not silently tighten
  the policy under you.
- **Set sane security contexts by default** in every Deployment template
  (`runAsNonRoot`, `allowPrivilegeEscalation: false`, drop `ALL`,
  `seccompProfile: RuntimeDefault`); it costs nothing and satisfies `restricted`.
- **Gate on admission in CI** (`--dry-run=server`) so violations are caught
  before deploy.

## Production Tips

- A Deployment that shows **zero Pods** while the ReplicaSet is healthy-looking
  is an admission rejection, not a scheduling problem — always read the
  ReplicaSet's `FailedCreate` events, which the Deployment status does not show.
- `kubectl apply --dry-run=server` is the fastest way to test a manifest
  against every admission controller (PSA, Gatekeeper, Kyverno, webhooks)
  without creating anything.
- PSA errors are precise: the message lists each violated rule. Fix the
  `securityContext` rather than disabling the policy.
- In multi-tenant clusters, pair PSA with ResourceQuota and NetworkPolicy for
  defence in depth (see scenarios 10 and 11).
- When migrating, expect `runAsNonRoot` to break images that default to root
  (many databases and older base images). Build non-root images, or set an
  explicit `runAsUser` the image supports.
