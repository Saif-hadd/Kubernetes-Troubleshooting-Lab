# 21 - Volume detach/attach stuck

## Overview

A PersistentVolume backed by an external disk (EBS, GCE PD, Azure Disk, Ceph,
...) must be **detached** from the old node and **attached** to the new one
when a Pod moves. This attach/detach is asynchronous and can get stuck: the old
node is gone or unresponsive, a stale `VolumeAttachment` lingers, or the cloud
API is slow. The Pod then sits in `ContainerCreating` (or `Pending`) with
errors like `Multi-Attach error` or `volume is already attached to another
node`, even though every node is healthy and the PVC is `Bound`.

From an SRE perspective this is a **storage control-plane** failure: the
workload and the disk are fine; the attach state machine between them is
wedged. It shows up most often right after a node drain, a node replacement, or
an availability-zone change.

> This scenario has a **single-node** flavour on Minikube: the manifests create
> a StatefulSet with a PVC, and the README describes the multi-node attach/detach
> failure you see on real clusters (which cannot be reproduced on one node).

## Symptoms

Pods stuck creating, with volume errors:

```
Warning  FailedAttachVolume   <pod>   Multi-Attach error for volume "pvc-..." :
        Volume is already exclusively attached to one node and can't be attached to another
```

or

```
Warning  FailedMount   <pod>   Unable to attach or mount volumes:
        unmounted volumes=[data], unattached volumes=[data]: timed out waiting for the condition
```

A `VolumeAttachment` can be stuck:

```bash
kubectl get volumeattachment
```

```
NAME            ATTACHER          PV        NODE    ATTACHED  AGE
csi-...-old     ebs.csi.aws.com   pvc-...   old     true      42m   # stale
```

## Root Cause

The attach/detach loop did not complete:

- **Old node unreachable** — the disk cannot be detached because the old node
  never acknowledges it (the node was terminated abruptly, or is NotReady).
- **Stale `VolumeAttachment`** — the controller's record of the attachment is
  left behind after a crash or a forced node deletion.
- **Multi-Attach** — a `ReadWriteOnce` (RWO) volume is requested on two nodes
  at once (common during a rolling restart where the old and new Pod overlap).
- **Zone mismatch** — the new node is in a different AZ than the volume; the
  attach is impossible (a classic `WaitForFirstConsumer`/node-selector issue).
- **Cloud API throttling / outage** — the CSI controller cannot call the cloud
  API to attach.

## Diagnosis

### 1. Confirm the Pod is waiting on a volume, not an image or config

```bash
kubectl describe pod -n ktslab db-0 | sed -n '/Volumes:/,/QoS Class:/p'
kubectl describe pod -n ktslab db-0 | sed -n '/Events:/,$p'
kubectl get pvc -n ktslab -o wide
```

A `Bound` PVC plus `FailedAttachVolume`/`FailedMount` events is the signature;
the PVC itself is healthy.

### 2. Inspect the attachment objects

```bash
./scenarios/21-volume-detach-stuck/diagnose.sh ktslab
kubectl get volumeattachment -o wide
kubectl describe volumeattachment <name>
```

### 3. Check the CSI controller

```bash
kubectl -n kube-system get pods | grep -i csi
kubectl -n kube-system logs -l app=ebs-csi-controller --tail=80
```

Look for `could not detach`, `attachment already exists`, `VolumeInUse`,
`throttling`.

### 4. Check the old node's state

```bash
kubectl get nodes
kubectl get node <old-node>
```

A `NotReady`/deleted old node that still "owns" the disk is the usual cause.

### 5. Confirm the zone

```bash
kubectl get node <new-node> -L topology.kubernetes.io/zone
kubectl get pv <pv> -o jsonpath='{.spec.nodeAffinity}'
```

A volume pinned to `us-east-1a` cannot attach to a node in `us-east-1b`.

## Resolution

### Fix A — Wait for the detach to complete

Attach/detach has its own timeout (often 5-15 minutes). If the old node is
merely slow, the mount resolves on its own; forcing it usually makes it worse.

### Fix B — Force-detach a stale attachment

If the old node is confirmed gone and the attachment is stale:

```bash
kubectl delete volumeattachment <name>
```

The CSI controller re-runs attach for the new node. (With in-tree drivers, use
the provider-specific force-detach path.)

### Fix C — Resolve the Multi-Attach overlap

Ensure only one Pod uses an RWO volume at a time: use a `StatefulSet`, reduce
`maxSurge` to `0` for the rollout, or use `ReadWriteMany` if multiple readers
are genuinely needed.

### Fix D — Fix the zone / node placement

Pin the Pod to the volume's zone (`nodeAffinity`) or provision the volume in
the node's zone (`volumeBindingMode: WaitForFirstConsumer`).

### Verify

```bash
kubectl get pods -n ktslab -w     # db-0 reaches Running
kubectl get volumeattachment      # one attachment, correct node, ATTACHED true
```

## Best Practices

- **Use `volumeBindingMode: WaitForFirstConsumer`** so a volume is provisioned
  in the zone of the node the Pod actually lands on — this removes the whole
  class of cross-zone attach failures.
- **One writer per RWO volume.** Design for it (StatefulSet), and keep rollouts
  from overlapping two writers.
- **Never delete a node's CRD/object while its volumes are attached** without
  confirming the detach; a deleted node leaves a stale attachment the
  controller has to clean up.
- **Give attach/detach timeouts real headroom** and alert on Pods stuck in
  `ContainerCreating` beyond a few minutes.
- **Run a CSI driver that supports the operations you rely on** (e.g. EBS CSI
  for snapshots, expansion) and keep it current with your Kubernetes version.

## Production Tips

- A Pod moving nodes during a maintenance window is the highest-risk moment for
  attach/detach; drain one node at a time and let each Pod's volume settle
  before draining the next.
- `Multi-Attach` almost always means two Pods are using the same RWO volume —
  check for a duplicated Deployment/StatefulSet or a rollout that started the
  new Pod before the old one terminated.
- A stale `VolumeAttachment` after a node termination is normal; the controller
  cleans it up, but if the node object was deleted by hand it can linger
  forever and must be removed.
- On spot/preemptible fleets, node termination is abrupt and detaches are
  common; prefer stateful workloads on on-demand nodes or ensure graceful node
  shutdown so the detach completes.
- If attach failures correlate with time of day, suspect cloud API throttling
  or a quota on the number of volumes per node/instance type.
