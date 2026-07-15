# 02 - Pending

## Overview

A Pod stuck in `Pending` has been accepted by the API server but **has not been
scheduled to a node**. The kubelet has never seen it, so there are no container
logs and no restarts — the failure lives entirely in the scheduler. From an SRE
perspective, `Pending` is a **capacity or constraint** problem: the cluster
cannot satisfy the Pod's resource requests, node selectors, taints/tolerations,
or affinity rules.

This is one of the most common production incidents because it scales with
fleet utilization — as a cluster fills up, any new Pod becomes unschedulable.

This scenario reproduces `Pending` via an unsatisfiable combination of
`resources.requests` and a `nodeSelector` that no node in the cluster matches.

## Symptoms

```bash
kubectl get pods -n ktslab
```

```
NAME                         READY   STATUS    RESTARTS   AGE
batch-worker-7c9d4f6b8b-1   0/1     Pending   0          3m
```

Note: `RESTARTS` is `0` — the container never ran.

```bash
kubectl describe pod -n ktslab batch-worker-7c9d4f6b8b-1
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  3m    default-scheduler  0/1 nodes are available: 1 node(s) node(s) didn't match Pod's node affinity/selector, 1 Insufficient memory. preemption: 0/1 nodes are available: 1 No preemption victims found for incoming pod.
```

## Root Cause

Two distinct constraints are unsatisfiable:

1. **`nodeSelector: disktype: ssd`** — no node in the cluster carries the
   `disktype=ssd` label, so the affinity filter rejects every node.
2. **`resources.requests.memory: 16Gi`** — even if the label matched, the
   node does not have 16Gi of allocatable memory, so the resource filter
   rejects it too.

The scheduler's `FailedScheduling` event aggregates all failing predicates into
one message, which is why both reasons appear. Neither preemption nor a
pending scale-up can help here — there is simply no node that satisfies the Pod.

## Diagnosis

### 1. Confirm the Pod is Pending and not just starting

```bash
kubectl get pods -n ktslab --field-selector=status.phase=Pending
```

### 2. Read the FailedScheduling event

```bash
kubectl describe pod -n ktslab <pod>
kubectl get events -n ktslab --field-selector reason=FailedScheduling
```

The event message is the single most important signal. Parse it carefully —
it lists *every* failing predicate:

- `Insufficient cpu` / `Insufficient memory` → capacity shortfall.
- `node(s) didn't match Pod's node affinity/selector` → label mismatch.
- `node(s) had taints that the pod didn't tolerate` → taint blocking.
- `node(s) unschedulable` → node is cordoned.

### 3. Inspect what the cluster actually offers

```bash
kubectl get nodes -o wide
kubectl describe node <node>
```

Look at:

- `Allocatable` — the memory/CPU available to Pods.
- `Conditions` — is the node `Ready`?
- `Taints` — any `NoSchedule` / `NoExecute` taints?
- `Labels` — does any node carry the label the selector expects?

### 4. Check node labels

```bash
kubectl get nodes --show-labels
```

Confirm whether the `nodeSelector` label exists anywhere.

### 5. Check what resources are already consumed

```bash
kubectl describe node <node> | grep -A5 -i allocated
kubectl top nodes
```

### 6. Verify the Pod's own requests

```bash
kubectl get pod -n ktslab <pod> -o yaml | grep -A10 resources
```

## Resolution

### Fix A — Remove or correct the nodeSelector

If the `disktype=ssd` label was aspirational, either label a node or drop the
selector:

```bash
kubectl label node <node> disktype=ssd
```

Or remove the `nodeSelector` from the manifest and redeploy.

### Fix B — Lower the resource request

`16Gi` is too large for a lab node. Set a realistic request:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
```

### Fix C — Add a toleration for a taint

If the node is tainted (e.g. `dedicated=bigmem:NoSchedule`), add a matching
toleration:

```yaml
tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "bigmem"
    effect: "NoSchedule"
```

### Fix D — Add capacity (autoscaling)

On EKS with Cluster Autoscaler or Karpenter, a Pending Pod with only a capacity
shortfall (no affinity mismatch) triggers a node scale-up. If the Pending is due
to a selector/taint, autoscaling will not help unless node groups are labeled
to match. See scenario 13 for Karpenter provisioning.

### Verify

```bash
kubectl get pods -n ktslab -o wide
kubectl describe pod -n ktslab <pod>
```

The Pod should move to `ContainerCreating` then `Running`.

## Best Practices

- **Right-size resource requests.** A Pod that requests 16Gi will not pack
  onto a 8Gi node, no matter how little it actually uses.
- **Prefer `nodeAffinity` with `preferredDuringScheduling`** over hard
  `nodeSelector` for non-strict placement — it avoids total unschedulability.
- **Label nodes deliberately** and document the labeling scheme; selectors
  against unlabeled nodes are a top cause of Pending.
- **Use `kubectl describe node` Allocatable**, not the node's total memory,
  when reasoning about capacity — the kubelet reserves resources.
- **Set cluster autoscaler / Karpenter budgets** so capacity shortfalls
  resolve themselves within minutes rather than paging humans.
- **Monitor Pending Pods** as a capacity KPI. A rising count means your fleet
  is full or your selectors are drifting.

## Production Tips

- On EKS, validate that node group labels match your workload selectors in
  IaC (Terraform/CDK) — not just in-cluster. Drift between IaC and live labels
  is a common cause of Friday-night Pending incidents.
- Combine `PodTopologySpread` constraints with adequate node groups; a
  topology constraint on a single-AZ node group is silently unsatisfiable.
- Distinguish `Pending` from `ContainerCreating`: the latter means the Pod
  *was* scheduled and is now pulling images / mounting volumes — a different
  failure path.
- Treat `FailedScheduling` events as structured alerting input. Many teams
  parse the reason string to route capacity vs. affinity incidents differently.
- For batch workloads, consider a dedicated node pool with
  `karpenter.sh/disruption` budgets so Pending batch Pods do not compete with
  service Pods for the same capacity.
