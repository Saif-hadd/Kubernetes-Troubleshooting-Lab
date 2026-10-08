# 26 - CNI plugin failure

## Overview

The **CNI plugin** (Calico, Cilium, Flannel, Weave, the AWS VPC CNI, ...) is
what assigns Pod IPs and programs the dataplane so Pods can reach each other
and Services. When the CNI's agent or configuration breaks, the failure is
**network-wide and low-level**: Pods may be `Running` but unable to talk to
each other, or stuck in `ContainerCreating` because the sandbox cannot be set
up. CoreDNS degrades, and eventually everything looks broken.

From an SRE perspective a CNI failure is a **cluster networking** incident with
a very large blast radius — comparable to a DNS outage (scenario 07), because
almost every workload depends on Pod-to-Pod connectivity.

> This scenario is documentation-driven: it deploys two Pods that should be able
> to reach each other, and the script inspects the CNI's health on the node.
> Reproducing an actual CNI failure is cluster-destructive and environment
> specific.

## Symptoms

- Pods `Running` but **cannot reach each other** (ping/curl by Pod IP fails).
- New Pods stuck in `ContainerCreating` with sandbox errors:
  ```
  failed to setup network for sandbox ...: plugin type="calico" failed (add):
  ...
  ```
- Cluster-wide Service/DNS failures (CoreDNS Pods themselves may be unreachable).
- `kubelet` logs `network plugin is not ready` or `cni config uninitialized`.
- CNI agent DaemonSet Pods `CrashLoopBackOff` or missing on some nodes.

## Root Cause

The CNI is a DaemonSet plus node-level configuration. Common failures:

- **Agent down** on a node — that node's Pods lose connectivity (or fail to
  start). A single-node cluster loses all networking.
- **IPAM exhaustion** — the Pod CIDR is full, so new Pods cannot get an IP and
  stay `ContainerCreating`.
- **Missing/corrupt CNI config** (`/etc/cni/net.d/*.conflist`) after an upgrade
  or a bad rollout.
- **Missing routes** — routes between nodes are not programmed (routing mode
  misconfiguration, BGP down for Calico, VPC route tables wrong for the AWS
  CNI).
- **Version/CRD skew** — the CNI's CRDs or the agent image are out of step
  after a Kubernetes upgrade.
- **A NetworkPolicy dataplane bug** taking down flows (see scenario 10).

## Diagnosis

### 1. Confirm it is networking, not the app

```bash
./scenarios/26-cni-plugin-failure/diagnose.sh lab
kubectl get pods -n ktslab -o wide      # Pod IPs assigned?
```

If Pods have IPs but cannot reach each other, it is the dataplane; if they have
**no** IP (`<none>`), it is IPAM/sandbox setup.

### 2. Check the CNI agent Pods across nodes

```bash
kubectl -n kube-system get pods -o wide | grep -iE 'calico|cilium|flannel|weave|antrea|kindnet'
kubectl -n kube-system logs <cni-agent-pod> --tail=80
```

A missing or crashing agent on a node explains that node's failures.

### 3. Inspect the node's CNI config and routes

```bash
minikube ssh -p lab -- sudo ls /etc/cni/net.d/
minikube ssh -p lab -- sudo cat /etc/cni/net.d/*.conflist
minikube ssh -p lab -- sudo ip route
```

### 4. Check kubelet logs for sandbox errors

```bash
minikube ssh -p lab -- sudo journalctl -u kubelet --no-pager | grep -iE 'cni|sandbox|network plugin' | tail -n 30
```

### 5. Check IPAM usage (Calico/Cilium)

```bash
kubectl get ippools.crd.projectcalico.org 2>/dev/null
kubectl get ciliumnodes 2>/dev/null
```

## Resolution

### Fix A — Restore the CNI agent

Restart the agent DaemonSet (or the specific node's agent Pod):

```bash
kubectl -n kube-system rollout restart daemonset/calico-node    # or cilium, etc.
kubectl -n kube-system rollout status daemonset/calico-node
```

### Fix B — Reinstall / reapply the CNI

If the config is corrupt or the CRDs are skewed, reapply the CNI's manifest at
the version matching your Kubernetes release:

```bash
kubectl apply -f <cni-version>/manifest.yaml
```

### Fix C — Fix IPAM exhaustion

Enlarge the Pod CIDR / IP pool, or reclaim leaked IPs:

```bash
kubectl get ippools.crd.projectcalico.org -o yaml | grep -A3 'blockSize\|cidr'
```

### Fix D — Fix routing

For Calico, check BGP sessions (`calicoctl node status`); for the AWS VPC CNI,
check the VPC route tables and the `aws-node` DaemonSet.

### Verify

```bash
./scenarios/26-cni-plugin-failure/diagnose.sh lab
# client can ping / curl server by Pod IP and by Service name
```

## Best Practices

- **Treat the CNI as critical infrastructure**: monitor its DaemonSet for
  `Available != desired`, and alert on any node missing its agent.
- **Alert on Pods stuck in `ContainerCreating`** beyond a few minutes; a sandbox
  failure is usually a CNI/IPAM problem.
- **Size the Pod CIDR generously** — IPAM exhaustion is a slow-burn incident
  that appears all at once.
- **Pin the CNI version to the Kubernetes version** and upgrade them together;
  a skew is a common post-upgrade failure.
- **Test connectivity, not just Pod status**, in your smoke tests: `Running` ≠
  reachable.

## Production Tips

- "Everything is broken but every Pods says Running" is the CNI signature — ping
  between Pod IPs before touching applications.
- A single node missing its CNI agent is easy to miss but takes down every Pod
  on that node (and, on a single-node cluster, everything). Check the DaemonSet
  per node.
- After a Kubernetes upgrade, the CNI is the most common thing left behind:
  verify the agent version and CRDs match the new API before trusting the
  cluster.
- CoreDNS failures often trail CNI failures: if DNS breaks cluster-wide, check
  Pod-to-Pod connectivity *before* the CoreDNS scenario.
- During a CNI incident, avoid destructive recovery (deleting the DaemonSet,
  wiping CNI state) until you have read the agent's logs — the cause is usually
  visible there.
