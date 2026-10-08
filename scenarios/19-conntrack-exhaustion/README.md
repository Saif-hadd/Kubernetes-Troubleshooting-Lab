# 19 - kube-proxy conntrack exhaustion

## Overview

Linux tracks every connection in the **conntrack** table (`nf_conntrack`), and
`kube-proxy` programs iptables/IPVS rules that rely on it for Services, NAT and
NodePort. When the table fills, the kernel logs
`nf_conntrack: table full, dropping packet` and **new connections are silently
dropped** — existing ones keep working. The result is a bizarre failure mode:
some requests succeed, new connections to Services time out, and nothing in
Kubernetes reports an error.

From an SRE perspective this is a **node dataplane exhaustion** failure. It is
cluster-adjacent: the symptom looks like a network outage, the cause is a node
kernel limit, and the trigger is often a traffic pattern (DNS storms, a retry
storm, a high-churn client) rather than a misconfiguration.

This scenario provides a workload that opens a high rate of short-lived
connections and a script to read the node's conntrack table so you can observe
the counters and the kernel warnings.

> Reproducing a genuine table-full condition is environment-specific (it depends
> on RAM and the current `nf_conntrack_max`). The manifests and the diagnosis
> below describe exactly what to look for.

## Symptoms

- **Intermittent** connection timeouts to Services/NodePorts; some requests
  succeed, new ones fail.
- `nf_conntrack: table full, dropping packet` in `dmesg`/journal.
- `conntrack -S` shows `insert_failed` and `drop` climbing.
- DNS resolution stalls (`ndots`/search storms amplify the churn — see
  scenario 24).
- No Kubernetes object reports anything wrong: Pods `Running`, Services fine,
  Endpoints populated.

## Root Cause

The node's `nf_conntrack_max` was reached. Every new flow needs a table entry;
when the table is full the kernel drops the packet before any Kubernetes layer
sees it. Common drivers:

- A **DNS/ndots storm**: each single-label lookup generates up to 6 queries
  (see scenario 24), multiplying short-lived UDP/TCP flows.
- A **retry storm**: a client or sidecar retrying aggressively against a
  Service, each retry a new flow.
- A **high-churn workload** (short-lived HTTP connections, no keep-alive).
- **kube-proxy in iptables mode** on a busy node with a low `nf_conntrack_max`.
- NAT with a short timeout churning entries unnecessarily.

## Diagnosis

### 1. Read the table counters on the node

```bash
./scenarios/19-conntrack-exhaustion/diagnose.sh lab
```

Or directly:

```bash
minikube ssh -p lab -- sudo cat /proc/sys/net/netfilter/nf_conntrack_count
minikube ssh -p lab -- sudo cat /proc/sys/net/netfilter/nf_conntrack_max
minikube ssh -p lab -- sudo dmesg | grep -i conntrack
```

`count` approaching `max` is the root cause. `dmesg` shows the drop message.

### 2. Confirm it is dataplane-wide, not one Service

If new connections to *several* different Services/ports time out on the same
node, it is conntrack/iptables, not a single app.

### 3. Check what is churning

```bash
minikube ssh -p lab -- sudo conntrack -S            # per-CPU stats
minikube ssh -p lab -- sudo conntrack -L | head     # current flows
kubectl top pods -A --sort-by=cpu                   # noisy clients
```

### 4. Rule out the alternatives

```bash
kubectl get pods -A -o wide       # Pods healthy
kubectl get endpointslice -A      # Endpoints present
```

If Pods and Endpoints are healthy but new connections drop, suspect the node
dataplane.

## Resolution

### Fix A — Raise the conntrack limit

On the node (persist it via sysctl):

```bash
minikube ssh -p lab -- sudo sysctl -w net.netfilter.nf_conntrack_max=262144
```

### Fix B — Reduce the churn

- Enable HTTP **keep-alive** in clients (persistent connections = fewer flows).
- Fix DNS churn by lowering `ndots` (scenario 24) so lookups stop multiplying.
- Add/limit retries with backoff and jitter so a retry storm cannot happen.
- Use connection pooling (`maxIdleConns`, `idleTimeout`) in the app.

### Fix C — Tune the timeouts / mode

- Lower `nf_conntrack_tcp_timeout_time_wait` (and UDP timeout) so idle entries
  are reclaimed faster.
- Consider **IPVS** mode for `kube-proxy` on high-throughput nodes, or an eBPF
  dataplane (Cilium) that does not depend on the conntrack table the same way.

### Fix D — Size the node / spread the churn

Give busy nodes more memory (the table scales with RAM), or spread the
high-churn workload across more nodes.

### Verify

```bash
./scenarios/19-conntrack-exhaustion/diagnose.sh lab   # count well below max
minikube ssh -p lab -- sudo dmesg | grep -i conntrack # no new drops
```

## Best Practices

- **Treat conntrack as a finite resource.** Size `nf_conntrack_max` for the
  node's workload and monitor `nf_conntrack_count / nf_conntrack_max`.
- **Alert on `insert_failed` / `drop`** in `conntrack -S`, not just on
  application errors — by the time apps notice, the node has been dropping for
  a while.
- **Design for fewer flows:** keep-alive, connection pools, and sane DNS
  (`ndots`) reduce conntrack pressure more than any tuning.
- **Be careful with conntrack-dependent features** (Service NAT, NodePort) on
  nodes that also run high-churn workloads.
- **Prefer an eBPF dataplane** (Cilium) where conntrack exhaustion is a
  recurring problem; it moves much of the state out of the kernel table.

## Production Tips

- "Some requests work, new ones hang" on a node that is otherwise healthy is
  the conntrack signature. Reproduce it in `conntrack -S` before blaming the
  app.
- A single misbehaving client (a tight retry loop) can fill a node's table and
  take down *every* Service on that node — find the churn source with
  `conntrack -L` and `kubectl top`.
- DNS is the most common silent amplifier: `ndots:5` turns one lookup into six
  flows. Fix the DNS before raising the table (scenario 24).
- `nf_conntrack_max` scales with node memory by default; on small nodes it is
  low enough that a modest burst exhausts it. Check the default before
  assuming it is generous.
- Raise the limit *and* reduce the churn; raising alone defers the incident to
  the next traffic spike.
