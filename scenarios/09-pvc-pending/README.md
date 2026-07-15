# 09 - PVC Pending

## Overview

A `PersistentVolumeClaim` (PVC) stuck in `Pending` means the storage request
has not been bound to a `PersistentVolume` (PV), so the Pod that references it
is stuck in `ContainerCreating` (or `Pending` if the scheduler waits for the
volume). From an SRE perspective this is a **storage provisioning** failure:
either no StorageClass is set, no dynamic provisioner is running, the
StorageClass is misconfigured, or a `WaitForFirstConsumer` binding is blocked
by an unsatisfiable node selector. The Pod cannot start until storage is
available.

This scenario reproduces the most common shape: a PVC that references a
StorageClass which does not exist in the cluster, so no provisioner ever
creates a PV and the PVC hangs forever.

## Symptoms

```bash
kubectl get pvc -n ktslab
```

```
NAME        STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS        AGE
data-claim  Pending                                      fast-ssd-bad        2m
```

```bash
kubectl get pods -n ktslab
```

```
NAME                         READY   STATUS              RESTARTS   AGE
db-7c9d4f6b8b-a1b2c          0/1     ContainerCreating   0          2m
```

The Pod is stuck in `ContainerCreating` because the kubelet is waiting for the
volume to attach — and it never will, because the PVC is unbound.

```bash
kubectl describe pvc -n ktslab data-claim
```

```
Events:
  Type     Reason         Age   From                         Message
  ----     ------         ----  ----                         -------
  Normal   WaitForFirstConsumer  2m   persistentvolume-controller  …
  Warning  ProvisioningFailed    2m   storageclass-controller      storageclass.storage.k8s.io "fast-ssd-bad" not found
```

## Root Cause

The PVC requests `storageClassName: fast-ssd-bad`, but no StorageClass with
that name exists in the cluster (typo, or it was never created, or it was
deleted). Without a StorageClass, the persistentvolume-controller cannot find
a matching provisioner, so no PV is dynamically created. The PVC remains
`Pending`, and the Pod that mounts it cannot proceed past
`ContainerCreating`.

Other common PVC-Pending root causes (same triage path):

- No default StorageClass set and the PVC omits `storageClassName`.
- A static PV exists but its capacity/access modes do not satisfy the PVC.
- `WaitForFirstConsumer` + a node selector that no node satisfies — the PVC
  waits forever for a compatible node.
- The CSI driver / provisioner Pod is down or not authorized.

## Diagnosis

### 1. List PVCs and their StorageClass

```bash
kubectl get pvc -n ktslab -o wide
kubectl get pvc -n ktslab data-claim -o jsonpath='{.spec.storageClassName}{"\n"}'
```

### 2. Read the PVC events — the critical step

```bash
kubectl describe pvc -n ktslab data-claim
kubectl get events -n ktslab --field-selector involvedObject.kind=PersistentVolumeClaim
```

The event message names the exact problem (`storageclass not found`,
`no volume plugin matched`, `no persistent volumes available`).

### 3. Verify the StorageClass exists

```bash
kubectl get storageclass
kubectl get sc fast-ssd-bad
```

If it is missing, that is the root cause. If it exists, check its provisioner
and parameters.

### 4. Check the default StorageClass

```bash
kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}'
```

A PVC with no `storageClassName` uses the default; if none is marked default,
the PVC hangs.

### 5. Confirm the CSI provisioner is running

```bash
kubectl get pods -n kube-system | grep -i provisioner
kubectl get pods -n kube-system | grep -i csi
kubectl logs -n kube-system <provisioner-pod> --tail=30
```

On EKS this is the `ebs-csi-controller` in `kube-system`.

### 6. Check for static PVs that might bind

```bash
kubectl get pv
```

If `pv.kubernetes.io/bind-completed` is absent and no PV matches the PVC's
access modes + capacity, dynamic provisioning is the only path — and it is
failing.

### 7. Check whether the Pod is waiting on the volume

```bash
kubectl describe pod -n ktslab <pod>
```

Look for `Volumes: data-claim … PersistentVolumeClaim (Pending)` and
`ContainerCreating` with `MountVolume.SetUp failed … volume not bound`.

## Resolution

### Fix A — Create or correct the StorageClass

Create the missing StorageClass (e.g. on a cluster with a CSI driver):

```bash
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
volumeBindingMode: WaitForFirstConsumer
EOF
```

Then update the PVC to reference the correct name:

```bash
kubectl patch pvc -n ktslab data-claim --type=json \
  -p='[{"op":"replace","path":"/spec/storageClassName","value":"fast-ssd"}]'
```

### Fix B — Set a default StorageClass

```bash
kubectl patch sc <name> -p='{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

PVCs that omit `storageClassName` now bind automatically.

### Fix C — Restart/redeploy the CSI provisioner

If the StorageClass is correct but no PV is created, the provisioner may be
down or unauthorized:

```bash
kubectl rollout restart deployment/ebs-csi-controller -n kube-system
```

### Fix D — For static PVs, align access modes and capacity

Ensure a static PV's `capacity.storage`, `accessModes`, and
`storageClassName` satisfy the PVC.

### Verify

```bash
kubectl get pvc -n ktslab
kubectl get pv
kubectl get pods -n ktslab
```

PVC `Bound`, PV created, Pod moves to `Running`.

## Best Practices

- **Always specify `storageClassName` explicitly** — relying on a default is
  fragile and varies across clusters.
- **Pin the StorageClass in IaC** (Terraform/CDK) alongside the workloads that
  use it, so cluster provisioning and PVC references cannot drift.
- **Use `WaitForFirstConsumer`** binding mode so volumes are provisioned in the
  right zone/topology for the Pod, avoiding cross-zone attach costs.
- **Monitor `kube_persistentvolumeclaim_status_phase{phase="Pending"}`** as a
  storage SLO — a Pending PVC is a blocked Pod.
- **Keep CSI driver versions current** with your Kubernetes version; stale
  drivers fail silently on newer APIs.
- **Prefer CSI over in-tree provisioners** — in-tree cloud provisioners are
  deprecated and being removed.

## Production Tips

- On EKS, the EBS CSI driver requires IRSA (IAM Roles for Service Accounts)
  permissions. A Pending PVC with `ProvisioningFailed: AccessDenied` in the
  provisioner logs is an IRSA/permission issue, not a StorageClass typo.
- Cross-zone EBS volume attachment is impossible — a Pod in us-east-1a cannot
  mount a volume provisioned in us-east-1b. `WaitForFirstConsumer` prevents
  this; an `Immediate` StorageClass + a node-bound selector can cause it.
- `ContainerCreating` for a long time with a bound PVC usually means the
  attach/detach is stuck on the node — check `kubectl describe pod` events for
  `Multi-Attach error` or `volume already attached to another node`.
- For stateful sets with `volumeClaimTemplates`, one bad StorageClass blocks
  the entire rollout. Validate the StorageClass on a single PVC before
  scaling a StatefulSet.
- Reserve a StorageClass per workload tier (e.g. `db-fast` gp3, `logs-bulk`
  st1) so a noisy log volume cannot consume the provisioner budget of a
  database.
- Snapshot/restore is a separate CSI operation; a `VolumeSnapshot` stuck in
  `Pending` has the same triage path but checks the snapshot controller, not
  the provisioner.
