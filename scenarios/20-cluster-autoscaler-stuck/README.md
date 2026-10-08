# 20 - Cluster autoscaler stuck

## Overview

A **cluster autoscaler** (the upstream `cluster-autoscaler`, Karpenter, or a
managed equivalent) adds nodes when Pods cannot be scheduled. When the demand
is real — Pods are `Pending` with `Insufficient cpu`/`memory` — but the cluster
never grows, the failure is a **capacity supply** problem, not a scheduling
one. From an SRE perspective this is the same class as scenario 13: demand
exists, supply does not materialise.

The classic shape: a Pod requests more (or a different instance size) than any
existing node provides, and the autoscaler is stuck — at its maximum node
count, missing IAM/cloud permissions, without a matching node group, or simply
not installing a node because the Pod's request does not fit *any* configured
instance type.

> This scenario is **documentation-driven** on Minikube/Kind: it reproduces the
> *Pending* symptom, and the README walks the autoscaler-side triage you would
> run on a real (EKS/GKE/AKS) cluster.

## Symptoms

```bash
kubectl get pods -n ktslab
```

```
NAME                          READY   STATUS    RESTARTS   AGE
big-worker-7c9d4f6b8b-1       0/1     Pending   0          6m
```

```bash
kubectl describe pod -n ktslab big-worker-7c9d4f6b8b-1
```

```
Events:
  Warning  FailedScheduling  6m  default-scheduler  0/3 nodes are available:
  3 Insufficient cpu, 3 Insufficient memory.
```

No new node appears:

```bash
kubectl get nodes -w
```

## Root Cause

The Pod's request (`cpu: 8`, `memory: 16Gi`) exceeds the capacity of every
existing node **and** of the node templates the autoscaler may add. The
autoscaler evaluates the Pod against its node groups / `NodePool` and finds
nothing it can provision, so it does nothing and the Pod stays `Pending`.

Common causes:

- **At the node-count / size limit** — the autoscaler (or the node group) has
  hit its maximum size.
- **No matching node group** — the Pod needs a different instance type, zone,
  label, or taint/toleration than any group provides.
- **Missing cloud permissions** — the autoscaler's IAM role cannot create
  instances (`ec2:RunInstances`, `autoscaling:SetDesiredCapacity`).
- **Below the scale-up threshold** — the autoscaler's `--scale-up-threshold` /
  `scale-up-unneeded-time` has not been met, or the Pod has not been Pending
  long enough.
- **Cloud quota** — the account's vCPU quota blocks the new instance.
- **Template misconfiguration** — the launch template/AMI/subnet is invalid, so
  the node group cannot scale out.

## Diagnosis

### 1. Confirm the Pod is genuinely unschedulable for capacity

```bash
kubectl get pods -n ktslab --field-selector status.phase=Pending
kubectl describe pod -n ktslab <pod> | sed -n '/Events:/,$p'
kubectl describe node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') | grep -A5 -i allocatable
```

`Insufficient cpu` / `Insufficient memory` (not a selector/taint mismatch) is
the capacity signature.

### 2. Inspect the autoscaler's view

```bash
# upstream cluster-autoscaler
kubectl -n kube-system get pods -l app=cluster-autoscaler
kubectl -n kube-system logs -l app=cluster-autoscaler --tail=80
kubectl -n kube-system get configmap cluster-autoscaler-status -o yaml

# Karpenter
kubectl get nodepools,nodeclaims -o wide
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --tail=80
```

Look for `no node group with matching ...`, `max size reached`,
`AccessDenied`, `would exceed ... limit`, `ScaleUp` vs `NoExpansionOptions`.

### 3. Check the autoscaler's limits

```bash
kubectl -n kube-system get configmap cluster-autoscaler-status -o yaml | grep -i max
```

`Max nodes` / node group `maxSize` reached is a common, quiet cause.

### 4. Check cloud-side quotas (EKS example)

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A   # vCPUs (Standard)
```

### 5. Verify the autoscaler's identity/permissions

```bash
kubectl -n kube-system get deployment cluster-autoscaler -o jsonpath='{.spec.template.spec.containers[0].env}'
```

Confirm the IRSA/instance-role intended is present and has create-instance
permissions.

## Resolution

### Fix A — Let the Pod fit an existing/available node

Right-size the request so an existing (or auto-provisionable) node can host it:

```yaml
resources:
  requests:
    cpu: 500m
    memory: 1Gi
```

### Fix B — Give the autoscaler a node group that matches

Add or widen the node group / `NodePool` (instance types, zones, labels,
tolerations) so it can satisfy the Pod, and raise its `maxSize` if it is capped.

### Fix C — Fix permissions

Attach the correct IAM policy to the autoscaler's role (and, for Karpenter, the
node instance profile), then restart the autoscaler.

### Fix D — Raise cloud quotas

Request a vCPU/instance quota increase in the cloud account.

### Verify

```bash
kubectl get nodes -w            # a new node joins
kubectl get pods -n ktslab      # the Pod schedules
kubectl -n kube-system logs -l app=cluster-autoscaler | grep -i 'scale.up\|scale.up.triggered'
```

## Best Practices

- **Align workload requests with provisionable node sizes.** A Pod that fits no
  node template will never be provisioned, no matter how long it waits.
- **Set sensible node-group `min`/`max`** and alert when a group is at `max` —
  a silently saturated group is a capacity incident.
- **Monitor Pending-Pod duration and scale-up latency** as SLOs; a Pod Pending
  for more than a few minutes with a working autoscaler is an alert.
- **Keep node templates valid** (AMI, subnet, security group, instance types);
  a broken template turns every scale-up into a no-op.
- **Give the autoscaler least-privilege permissions** and test them in
  non-production; an autoscaler that cannot create instances is a silent single
  point of failure.

## Production Tips

- A Pending Pod with **insufficient capacity** and a healthy autoscaler should
  resolve in minutes. If it does not, the problem is the autoscaler's view of
  the world (limits, templates, permissions), not the Pod.
- `cluster-autoscaler-status` ConfigMap is the fastest "why didn't it scale"
  signal on upstream CA: it lists per-group health, last scale-up time and
  reasons.
- Scale-up that never happens because a node **cannot fit the Pod** is a design
  bug: check that the pod's requests are smaller than the largest instance
  type in at least one group (with its daemonsets' overhead subtracted).
- During an incident, remember that a scale-up takes time (instance boot +
  kubelet register + image pull). A Pod Pending for 90 seconds under load may
  simply be waiting for a node that is already coming.
- Do not "fix" capacity by pinning huge requests down — fix the node group, or
  the next workload will hit the same wall.
