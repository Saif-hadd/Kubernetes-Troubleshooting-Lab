# 13 - Karpenter

## Overview

Karpenter is a flexible, high-performance Kubernetes cluster autoscaler built
by AWS. Instead of node groups, it watches for Pending Pods and provisions
right-sized nodes from a `NodePool`/`NodeClaim` based on the Pods' requirements.
When Karpenter is not provisioning — or Pods stay `Pending` despite it being
installed — the failure is usually in **the NodePool selectors/constraints,
permissions, or capacity/quota**. From an SRE perspective this is a **capacity
supply** failure: the demand (Pending Pods) is real, but the supply (nodes)
never materializes.

This scenario reproduces the most common shape: a workload requests a label
or resource that no `NodePool` will satisfy (e.g. a GPU label or an instance
type constraint that the NodePool excludes), so Karpenter sees the Pending Pod
but has no compatible pool to provision from — the Pod stays Pending.

> Karpenter runs on EKS. On Minikube/Kind this scenario is documentation-only:
> apply the manifests to an EKS cluster with Karpenter installed to reproduce.

## Symptoms

```bash
kubectl get pods -n ktslab
```

```
NAME                         READY   STATUS    RESTARTS   AGE
gpu-worker-7c9d4f6b8b-1      0/1     Pending   0          4m
```

```bash
kubectl describe pod -n ktslab gpu-worker-7c9d4f6b8b-1
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  4m    default-scheduler  0/3 nodes are available: 3 Insufficient gpu. preemption: 0/3 nodes are available: 3 No preemption victims found for incoming pod.
```

No node is being provisioned despite Karpenter being installed.

```bash
kubectl get nodepools
```

```
NAME             READY
default-pool     True
gpu-pool         True
```

```bash
kubectl get nodeclaims
```

No new NodeClaim appears for the Pending Pod, or a NodeClaim appears and is
stuck `NotReady`/`Waiting`.

## Root Cause

The `gpu-worker` Pod requests a node with `nvidia.com/gpu: 1` and is
constrained to an availability zone / instance type that the existing
`gpu-pool` NodePool explicitly **disallows** (the NodePool's
`requirements` exclude the needed instance family or zone, or the
`gpu-pool` was never created). Karpenter evaluates the Pod against each
NodePool's requirements; finding no compatible pool, it does not provision a
node. The Pod stays `Pending` with `FailedScheduling` and no NodeClaim is
created.

Other common Karpenter root causes:

- The Karpenter controller Pod is down or its IAM role (IRSA) lacks
  `ec2:RunInstances` / `iam:PassRole`.
- All NodePools are at `limits` (max nodes/cpu/memory).
- The AWS account hit a vCPU/GPU quota for the requested instance family.
- A required label/taint on the Pod is not matched by any NodePool's
  `requirements`/`tolerations`.
- NodeClaims are created but fail health checks (AMI not found, subnet
  misconfigured, security group missing).

## Diagnosis

### 1. Confirm the Pod is Pending and why the scheduler cannot place it

```bash
kubectl get pods -n ktslab --field-selector status.phase=Pending
kubectl describe pod -n ktslab <pod>
kubectl get events -n ktslab --field-selector reason=FailedScheduling
```

Note the failing predicate (`Insufficient gpu`, `Insufficient memory`,
node affinity mismatch).

### 2. Check Karpenter is running and healthy

```bash
kubectl get pods -n karpenter
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=50
```

Look for `discovered pending pods`, `provisioning`, or errors like
`AccessDenied`, `InstanceTypeOffering not found`.

### 3. Inspect NodePools and their requirements

```bash
kubectl get nodepools -o wide
kubectl describe nodepool <name>
```

Map each NodePool's `spec.template.spec.requirements` (e.g. allowed instance
types, zones, and labels like `karpenter.sh/nodepool`) against the Pod's
requests + node selectors + tolerations. If no NodePool's requirements
satisfy the Pod, that is the root cause.

### 4. Check NodeClaims

```bash
kubectl get nodeclaims -o wide
kubectl describe nodeclaim <name>
```

A NodeClaim stuck in `Waiting` or `NotReady` with events like
`InstanceTypeOfferingNotFound` or `SubnetNotFound` points at AWS-side
misconfiguration.

### 5. Check Karpenter events

```bash
kubectl get events -A --field-selector reason=Provisioned --sort-by=.lastTimestamp
kubectl get events -A --field-selector reason=Unconsolidatable
```

### 6. Verify Karpenter's IAM permissions (IRSA)

```bash
kubectl get deployment -n karpenter karpenter -o jsonpath='{.spec.template.spec.containers[0].env}'
```

Confirm the `AWS_ROLE_ARN` / `AWS_WEB_IDENTITY_TOKEN_FILE` env vars are set
(IRSA). In AWS, the role must have the KarpenterNodeControllerPolicy and
`iam:PassRole` for the node role.

### 7. Check AWS-side quotas and capacity

```bash
# From a host with AWS access:
aws service-quotas get-service-quota --service-code ec2 --quota-code L-123 ...
```

GPU and some accelerated instance families have tight account quotas; a
`Pending` Pod with no NodeClaim often maps to a quota rejection in Karpenter
logs (`Unsupported`/`CapacityExceeded`).

## Resolution

### Fix A — Add or correct a NodePool that satisfies the Pod

Create or patch a NodePool whose `requirements` allow the needed instance
family, zone, and labels, and whose `tolerations` accept the Pod's taints:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-pool
spec:
  template:
    metadata:
      labels:
        workload: gpu
    spec:
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule
      requirements:
        - key: karpenter.k8s.aws/instance-gpu-count
          operator: Gt
          values: ["0"]
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["us-east-1a", "us-east-1b"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: gpu-profile
  limits:
    cpu: 1000
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
```

### Fix B — Remove the over-constraining selector from the Pod

If the Pod's `nodeSelector`/resources are aspirational, relax them so an
existing NodePool can satisfy them.

### Fix C — Fix Karpenter permissions

Attach the correct IAM policies to the Karpenter IRSA role
(`ec2:RunInstances`, `ec2:CreateFleet`, `iam:PassRole`, etc.) and restart
Karpenter.

### Fix D — Raise AWS quotas / switch instance families

Request a quota increase for the GPU family, or broaden the NodePool
requirements to fall back to available instance types.

### Verify

```bash
kubectl get nodeclaims -w
kubectl get nodes -w
kubectl get pods -n ktslab
```

A new NodeClaim → a new `Ready` node → the Pod schedules.

## Best Practices

- **Align NodePool requirements with workload selectors** in IaC; a Pod that
  requests a label no NodePool provides will Pending forever.
- **Keep NodePools broad, not narrow.** Karpenter picks the best instance per
  Pod; over-constraining instance types defeats its purpose and causes
  Pending under quota pressure.
- **Set realistic `limits`** on each NodePool so a runaway workload does not
  drain your AWS account, but high enough to serve real demand.
- **Use disruption budgets** (`disruption.budgets`) so consolidation does not
  evict too many Pods at once during a node pool churn.
- **Monitor `karpenter_pods_pending` and NodeClaim creation latency** as SLOs.
- **Pin the EC2NodeClass AMI family** (e.g. AL2023) and keep it current; stale
  AMIs fail NodeClaim health checks.

## Production Tips

- Karpenter consolidates aggressively by default. A Pod that Pending-loops
  right after consolidation may be the trigger for a scale-up that a
  consolidation just caused — check `consolidateAfter` and disruption budgets.
- Prefer `consolidationPolicy: WhenEmptyOrUnderutilized` with a modest
  `consolidateAfter` (e.g. 30-60s) to balance cost and churn; too aggressive
  and you thrash nodes, too conservative and you waste spend.
- On-spot-only NodePools save cost but require the AWS Node Termination
  Handler / Karpenter's own interruption handling so Pods drain before the
  instance is reclaimed. A spot interruption without graceful drain = evicted
  Pods and potential data loss for stateful workloads.
- GPU NodePools need the NVIDIA device plugin / GPU operator installed, or the
  node joins `Ready` but `nvidia.com/gpu` is never advertised and Pods stay
  Pending with `Insufficient gpu`.
- A NodeClaim stuck `NotReady` with `CredentialNotfound`/`AccessDenied` is an
  IRSA issue on the *node* role (the instance profile), not Karpenter's role.
  Two different IAM roles — debug the right one.
- Keep Karpenter version aligned with your Kubernetes version; NodePool/EC2NodeClass
  APIs changed between v0.37 and v1. Using a stale CRD shape is a silent
  no-provision failure.
