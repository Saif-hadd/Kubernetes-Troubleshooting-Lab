# 23 - Leader election churn

## Overview

High-availability control planes run multiple replicas of
`kube-controller-manager` and `kube-scheduler`, but only **one** of each is
active at a time: they elect a leader via a `Lease` object in
`kube-system`, and the others stand by. When the leader keeps changing —
flapping — every leadership transition briefly **pauses all reconciliation**:
Deployments stop rolling out, Node/Job controllers stall, and the scheduler
stops binding Pods.

From an SRE perspective this is a **control-plane stability** failure that
looks like flakiness ("sometimes it reconciles, sometimes it doesn't") rather
than a clean outage. It is common on clusters whose control-plane nodes are
under resource pressure or cannot reliably reach the API server.

This scenario is documentation-driven; the script inspects the leader-election
leases and the components' logs on your cluster.

## Symptoms

- Reconcilers **intermittently** stop working: a Deployment rolled out "most
  of the way" and then stalled.
- `kube-scheduler` stops assigning Pods for periods of time (Pods `Pending`
  with no recent scheduling attempt).
- Repeated log lines in `kube-controller-manager` / `kube-scheduler`:
  ```
  attempting to acquire leader lease kube-system/kube-scheduler...
  successfully acquired lease kube-system/kube-scheduler
  ```
  appearing many times, not once.
- Metrics `leader_election_master_status` flipping to `0`/`1`, or
  `leader_election_slowpath_total` climbing.

## Root Cause

Leader election has a **lease duration** and a **renew deadline**. If the
leader cannot renew in time (API server too slow, node CPU-starved, clock
skew, or a network partition), the lease expires and another replica takes
over. Flapping causes:

- **API server latency / etcd pressure** — renewals time out (see scenarios 14
  and 15).
- **Noisy neighbours on control-plane nodes** — a CPU-hog Pod starves the
  controller-manager/scheduler.
- **Clock skew** between control-plane nodes — lease arithmetic goes wrong.
- **Network instability** between control-plane nodes and the API server.
- **Too many leaders with identical identity** — a misconfiguration (e.g.
  duplicate replicas with the same `id`) causing constant takeovers.

## Diagnosis

### 1. Look at the leases and the logs

```bash
./scenarios/23-leader-election-churn/diagnose.sh
kubectl -n kube-system get lease kube-controller-manager kube-scheduler -o yaml
```

`renewTime` should advance steadily. A `leaseDurationSeconds`/`renewTime`
pattern that keeps resetting, or many "acquired lease" lines, is churn.

### 2. Correlate with API/etcd latency

```bash
time kubectl get nodes
kubectl get --raw='/readyz?verbose'
kubectl -n kube-system logs -l component=kube-apiserver --tail=100 | grep -iE 'timeout|etcd'
```

If the API server is slow, leader election suffers first — it is a canary for
control-plane latency.

### 3. Check control-plane resource pressure

```bash
kubectl top pods -n kube-system | grep -E 'controller-manager|scheduler|etcd|apiserver'
kubectl describe node <control-plane-node> | grep -A5 -i 'Allocated resources'
```

### 4. Check the clocks

```bash
# on each control-plane node
timedatectl status | grep -i 'synchronized\|NTP'
```

Unsynchronised clocks cause unpredictable lease behaviour.

### 5. Check the components agree on identity

```bash
kubectl -n kube-system get pods -l component=kube-controller-manager -o jsonpath='{range .items[*]}{.metadata.name}{" hostname="}{.spec.hostname}{"\n"}{end}'
```

Each replica needs a distinct `--leader-elect-id`/hostname.

## Resolution

### Fix A — Remove control-plane pressure

Stop co-locating workloads on control-plane nodes; give
controller-manager/scheduler/etcd/apiserver CPU and memory headroom
(`--kube-reserved`/`--system-reserved`). Most churn disappears when the API
server responds promptly.

### Fix B — Fix API server / etcd latency

If renewals are timing out because the API is slow, follow the etcd (14) and
API server (15) scenarios.

### Fix C — Fix clock synchronisation

Ensure NTP/chrony is running and synchronised on every control-plane node.

### Fix D — Tune the election parameters (last resort)

Increase `--leader-elect-lease-duration` and `--leader-elect-renew-deadline`
(or the equivalent flags) on slow-but-otherwise-healthy clusters — but prefer
fixing the underlying latency.

### Verify

```bash
kubectl -n kube-system logs -l component=kube-scheduler --tail=20 | grep -i leader
# Expect a single "successfully acquired lease" and no further churn.
```

## Best Practices

- **Keep control-plane nodes dedicated and well-resourced.** Leader election
  is the first thing to suffer when the API server is slow.
- **Monitor leader-election metrics**: `leader_election_master_status`,
  `leader_election_slowpath_total`, and the count of leader transitions.
  Alert on any transition on a healthy cluster.
- **Run 3 control-plane replicas** for real HA; two replicas give no
  meaningful quorum advantage and still flap together under shared pressure.
- **Keep clocks synchronised** (NTP/chrony) on every node.
- **Distinct identities per replica** — do not clone a control-plane node
  without changing the election identity.

## Production Tips

- "Reconciliation sometimes works" is the signature of leader churn; if a
  rollout stalls and then resumes without intervention, look at leases before
  anything else.
- Leader-election churn is often the **first symptom** of etcd/API slowness —
  treat it as an early warning, not a standalone bug.
- On managed clouds you do not run the control plane, so leader-election churn
  is invisible; provider-side control-plane degradation shows up as API
  throttling/latency instead (scenario 15).
- A control-plane node that is CPU-throttled (its own CPU limit, or a noisy
  neighbour) will drop and re-acquire leadership repeatedly — check the node's
  CPU before touching election flags.
- Do not "fix" churn by lengthening the lease without addressing latency; you
  trade fast failure for two leaders briefly coexisting, which is worse.
