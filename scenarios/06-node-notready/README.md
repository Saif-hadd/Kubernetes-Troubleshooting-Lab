# 06 - Node NotReady

## Overview

A `NotReady` node is one whose kubelet has stopped reporting `Ready=True` to
the control plane within the node lease timeout (default 40s). The node is
still in the cluster, but the scheduler will no longer place new Pods on it,
and the node controller will eventually evict Pods from it. From an SRE
perspective this is a **failure-domain** event: every Pod on that node is now
at risk, and the blast radius is everything scheduled to that host.

`NotReady` has many root causes — kubelet crash, disk pressure, memory
pressure, PID exhaustion, network partition, kernel panic, or the underlying
VM being stopped/terminated. The skill is rapidly classifying *which* pressure
condition is active, because the fix differs sharply.

This scenario reproduces the *symptom and triage path*: a Deployment whose
Pods land on a node, followed by simulating NotReady by cordoning the node and
filling disk to trigger `DiskPressure`. The manifests schedule the workload;
the README walks the node-side diagnosis you would run against any NotReady
node.

## Symptoms

```bash
kubectl get nodes
```

```
NAME           STATUS                     ROLES           AGE   VERSION
minikube-m02   Ready                      <none>          20m   v1.29.0
minikube-m03   Ready,SchedulingDisabled   <none>          20m   v1.29.0
```

Or, more seriously:

```
NAME           STATUS      ROLES    AGE   VERSION
minikube-m03   NotReady    <none>   20m   v1.29.0
```

```bash
kubectl get pods -n ktslab -o wide
```

```
NAME                         READY   STATUS        RESTARTS   AGE   NODE
worker-7c9d4f6b8b-1          1/1     Running       0          3m    minikube-m02
worker-7c9d4f6b8b-2          1/1     NodeLost      0          3m    minikube-m03
```

`NodeLost` appears on Pods whose node went `NotReady` and passed the
`pod-eviction-timeout`.

```bash
kubectl describe node minikube-m03
```

```
Conditions:
  Type              Status  LastHeartbeatTime  Reason                Message
  ----              ------  -----------------  ------                -------
  MemoryPressure    False   …                 KubeletHasSufficientMemory …
  DiskPressure      True    …                 KubeletHasDiskPressure …
  PIDPressure       False   …                 KubeletHasNoPIDPressure …
  Ready             False   …                 KubeletNotReady       …
```

## Root Cause

The kubelet periodically reports node conditions to the control plane via a
lease. When a condition turns `True` (e.g. `DiskPressure` because the node's
image filesystem or container filesystem crossed the kubelet's
`--eviction-hard` threshold), the kubelet:

1. Sets `Ready=False`.
2. Begins evicting Pods to reclaim the pressured resource.
3. Stops reporting `Ready`.

The scheduler then marks the node unschedulable. If the kubelet stops
*entirely* (crash, network partition, VM stopped), the lease simply expires
after 40s and the node controller flips `Ready` to `Unknown`.

In this scenario the trigger is **DiskPressure**: the node's filesystem crossed
the eviction threshold, so the kubelet set `Ready=False` and started evicting.

## Diagnosis

### 1. Get the node status at a glance

```bash
kubectl get nodes -o wide
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.conditions[?(@.type=="DiskPressure")].status}{"\n"}{end}'
```

### 2. Inspect the node conditions — this is the key step

```bash
kubectl describe node <node>
```

Map each condition to a cause:

| Condition | Meaning | Likely cause |
|-----------|---------|--------------|
| `Ready=False` | Kubelet not healthy | Any of the below, or kubelet crash/partition |
| `DiskPressure=True` | Node filesystem low | Logs, images, emptyDir, container layers filling disk |
| `MemoryPressure=True` | Node memory low | Overcommit, runaway Pod, host processes |
| `PIDPressure=True` | PID exhaustion | Fork bombs, too many processes |
| `Ready=Unknown` | Lease expired | Kubelet stopped, network partition, VM gone |

### 3. Check node events

```bash
kubectl get events --field-selector involvedObject.kind=Node --sort-by=.lastTimestamp
```

### 4. Check the kubelet on the node

```bash
kubectl debug node/<node> -it --image=busybox
# Inside the node shell:
# chroot /host journalctl -u kubelet --no-pager | tail -50
```

Look for ` kubelet is not ready`, `eviction manager`, `failed to garbage
collect`, or `PLEG is not healthy`.

### 5. Check the node's disk/memory from inside

```bash
kubectl debug node/<node> -it --image=busybox
# chroot /host df -h
# chroot /host free -m
# chroot /host ps aux --sort=-%mem | head
```

### 6. Identify which Pods are affected

```bash
kubectl get pods -A --field-selector spec.nodeName=<node> -o wide
```

### 7. Distinguish cordon from NotReady

```bash
kubectl get node <node> -o jsonpath='{.spec.unschedulable}'
```

`true` with `Ready=True` means a human cordoned it (maintenance); `NotReady`
with `unschedulable` auto-set means a condition triggered it.

## Resolution

### Fix A — Relieve the pressure condition

For `DiskPressure`: clear the offending data.

```bash
# On the node:
crictl rmi --prune          # remove unused images
journalctl --vacuum-size=100M
# find and remove large emptyDir/log fills
```

The kubelet will reset `DiskPressure=False` and `Ready=True` automatically once
usage drops below the threshold.

### Fix B — Restart the kubelet

If the kubelet itself is wedged (e.g. `PLEG is not healthy`):

```bash
# On the node:
systemctl restart kubelet
```

### Fix C — Recover a partitioned or stopped node

If the VM was stopped/partitioned:

- On a cloud provider, check the instance state (e.g. `aws ec2 describe-instances`).
- If terminated, let the cluster autoscaler replace it; if stopped, start it.
- If the node is unrecoverable, drain and delete it so a replacement joins.

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --force
kubectl delete node <node>
```

### Fix D — Evict and reschedule Pods off the bad node

If the node will be down for a while, force-evict so Pods reschedule:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=60s
```

### Verify

```bash
kubectl get nodes
kubectl describe node <node> | grep -A8 Conditions
kubectl get pods -n ktslab -o wide
```

`Ready=True` and the affected Pods rescheduled to healthy nodes.

## Best Practices

- **Alert on `Ready=False`/`Unknown` within 1 minute** — a silent NotReady
  node degrades capacity and can violate PodDisruptionBudgets.
- **Set `--eviction-hard` thresholds deliberately** on the kubelet so
  pressure conditions trip before a hard node OOM or disk-full.
- **Use `PodDisruptionBudgets`** so that when nodes drain, a minimum number of
  replicas stay available.
- **Spread Pods with `topologySpreadConstraints` or
  `podAntiAffinity`** so a single NotReady node does not take down an entire
  service tier.
- **Monitor node pressure metrics** (`node_memory_MemAvailable`,
  `node_filesystem_avail`, `node_context_switches`) — catch pressure before
  the kubelet flips `Ready`.
- **Run `node-problem-detector`** to surface kernel/kubelet issues that the
  kubelet itself cannot report (e.g. kernel panic, hung tasks).

## Production Tips

- On EKS, an unhealthy node is often better replaced than repaired. With
  Karpenter or Cluster Autoscaler, drain and delete; a fresh node joins with
  the latest AMI and clean state. See scenario 13.
- `Ready=Unknown` after a network partition self-heals when connectivity
  returns, but Pods may have been evicted already — check
  `--pod-eviction-timeout` (default 5m on managed clouds) to know the window.
- A node that flaps `Ready -> NotReady -> Ready` usually indicates
  `PLEG is not healthy` or intermittent kubelet/network issues; capture
  `journalctl -u kubelet` during a flap, it will not reproduce on demand.
- DiskPressure is frequently caused by verbose container logs or large
  `emptyDir` volumes. Configure log rotation and use ephemeral-storage limits
  to prevent a single Pod from filling a node.
- Do not uncordon a node that went NotReady due to pressure without fixing the
  root cause — it will fill again and evict more Pods. Always relieve the
  resource first.
- In spot/preemptible fleets, `NotReady` on a node often precedes termination.
  Wire the spot interruption notice (e.g. AWS Node Termination Handler) to
  drain gracefully before the node disappears.
