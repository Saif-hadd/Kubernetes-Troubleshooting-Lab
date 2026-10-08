# 27 - kubelet PLEG issues

## Overview

The kubelet's **PLEG** (Pod Lifecycle Event Generator) watches the container
runtime and generates the events the kubelet uses to keep Pod status accurate.
When PLEG cannot keep up, the kubelet logs
`PLEG is not healthy: pleg was last seen active ... ago` and its health endpoint
fails. The node may flip to `NotReady`, Pod statuses become stale, and the
kubelet can stop honoring new Pod changes — while the containers themselves
keep running.

From an SRE perspective a PLEG problem is a **node-level runtime** failure: it
is not an application, scheduling, or networking bug. It is usually a symptom
of the node being starved (CPU/IO) or the container runtime being slow or
wedged.

> This scenario is documentation-driven. The manifests deploy a workload and
> the script reads the kubelet's PLEG health from the node.

## Symptoms

- `PLEG is not healthy: pleg was last seen active 3m0s ago; threshold is 3m0s`
  in the kubelet logs / `kubectl describe node` events.
- The node oscillates `Ready` ↔ `NotReady`.
- Pod statuses stop updating: a deleted Pod still shows, or a new Pod stays
  `ContainerCreating` although its container is actually running.
- `kubectl logs`/`exec` fail or hang for Pods on that node.
- Node conditions may show resource pressure (`MemoryPressure`, `PIDPressure`).

## Root Cause

PLEG relies on the container runtime (containerd/CRI-O) reporting events
promptly. It becomes unhealthy when:

- **The node is CPU-starved** — the kubelet does not get enough CPU to run its
  relist/event loop (often a noisy neighbour or an over-committed node).
- **The container runtime is slow/wedged** — containerd overloaded, IO-blocked,
  or buggy; the relist takes too long.
- **Disk/IO pressure** — the runtime's storage is slow, so relists stall.
- **Huge numbers of containers** on one node exceeding the runtime's capacity.
- **Runtime/host bugs** (e.g. a leaked `runc`/`containerd-shim`).

## Diagnosis

### 1. Confirm the PLEG message

```bash
./scenarios/27-kubelet-pleg/diagnose.sh lab
kubectl describe node <node> | grep -i -A3 pleg
```

`PLEG is not healthy` with a "last seen active" age above the threshold is the
signature.

### 2. Check node resource pressure

```bash
kubectl describe node <node> | sed -n '/Conditions:/,/Addresses:/p'
kubectl top node <node>
```

`MemoryPressure`/`PIDPressure` or a saturated CPU points at node starvation.

### 3. Check the container runtime

```bash
minikube ssh -p lab -- sudo systemctl status containerd
minikube ssh -p lab -- sudo journalctl -u containerd --no-pager | tail -n 50
minikube ssh -p lab -- sudo crictl info
```

A slow or erroring runtime is the usual root cause.

### 4. Count the containers on the node

```bash
minikube ssh -p lab -- sudo crictl ps -a | wc -l
minikube ssh -p lab -- sudo crictl stats | head
```

### 5. Look at IO / load

```bash
minikube ssh -p lab -- uptime
minikube ssh -p lab -- sudo iostat -x 1 3      # if available
```

## Resolution

### Fix A — Relieve node pressure

Remove noisy neighbours, raise the node's resources, or move workloads off the
node. A CPU-starved kubelet recovers as soon as it can run its loop.

### Fix B — Restart the container runtime (or the kubelet)

If the runtime is wedged:

```bash
minikube ssh -p lab -- sudo systemctl restart containerd
minikube ssh -p lab -- sudo systemctl restart kubelet
```

(Plan for a brief disruption to Pods on that node.)

### Fix C — Drain and repair

If the node does not recover, cordon and drain it, then investigate offline:

```bash
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
```

### Fix D — Fix the underlying host (disk/IO, kernel, runtime version)

Address slow storage, kernel/runtime bugs, or version skew between the runtime
and Kubernetes.

### Verify

```bash
kubectl get nodes                               # Ready and stable
./scenarios/27-kubelet-pleg/diagnose.sh lab     # no PLEG errors
kubectl get pods -A -o wide                     # statuses updating
```

## Best Practices

- **Do not over-commit nodes.** PLEG is the first thing to suffer when a node
  runs out of CPU; set sane `--kube-reserved`/`--system-reserved` and avoid
  packing nodes to 100%.
- **Alert on node `NotReady` flaps**, not just sustained `NotReady`; flapping is
  the classic PLEG/runtime symptom.
- **Monitor the container runtime's health and latency**, and keep it at a
  version compatible with Kubernetes.
- **Watch the container count per node**; very high density stresses the
  runtime's event loop.
- **Use `node-problem-detector`** to surface kernel/kubelet issues (hung tasks,
  PLEG stalls) as node conditions you can alert on.

## Production Tips

- A node that flaps `Ready ↔ NotReady` without a clean cause is usually PLEG or
  a flaky runtime/network, not a hardware failure. Capture kubelet logs *during*
  a flap; it will not reproduce on demand.
- `PLEG is not healthy` frequently accompanies an unresponsive runtime; check
  `containerd`/`crio` before assuming the kubelet itself is at fault.
- During a PLEG incident, Pod statuses are unreliable — do not make deletion or
  scaling decisions from `kubectl get pods` on that node.
- Replacing the node is often the fastest safe fix on the cloud (drain, then let
  the autoscaler replace it) rather than debugging a wedged runtime under
  pressure.
- CPU throttling of a *node's* system services (from an exhausted allocatable)
  can trigger PLEG stalls that look random — check the node's reserved budget.
