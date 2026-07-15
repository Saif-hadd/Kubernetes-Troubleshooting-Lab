# 14 - etcd

## Overview

etcd is the consistent, distributed key-value store that holds the entire
Kubernetes cluster state. The API server is its only client. When etcd is
unhealthy — lost quorum, high latency, disk pressure, or corruption — the
**entire control plane degrades**: `kubectl` commands hang, writes time out,
leader election fails, and the scheduler/controller-manager stop reconciling.
From an SRE perspective this is the **highest-blast-radius** failure in
Kubernetes: a single unhealthy etcd member can stall a whole cluster without
any Pod being at fault.

This scenario is **control-plane only** and is documentation-driven: on
managed clouds (EKS/GKE/AKS) etcd is invisible to you and operated by the
provider; on self-managed clusters (kubeadm, RKE, EKS Anywhere) you operate
it directly. The manifests deploy a workload whose scheduling depends on a
healthy control plane, so you can observe the *symptom* of etcd degradation
(cluster-wide slowness/timeout) while the README walks the etcd-side triage.

## Symptoms

The first sign is usually cluster-wide API slowness, not a Pod status:

```bash
kubectl get pods -n ktslab
```

```
Unable to connect to the server: EOF
# or
I0715 ... unable to fetch nodes: etcdserver: request timed out
# or (after a long pause):
NAME                         READY   STATUS    RESTARTS   AGE
webapp-7c9d4f6b8b-1          1/1     Running   0          3m
```

A successful `kubectl get` that takes 10-30s to return is a classic etcd
latency signal. Pod creation may also stall: a new Deployment shows
`ContainerCreating` for a long time even though the node is healthy.

On self-managed clusters, `etcdctl` gives the definitive view:

```bash
ETCDCTL_API=3 etcdctl endpoint health --cluster \
  --cacert=/etc/etcd/pki/ca.crt \
  --cert=/etc/etcd/pki/server.crt \
  --key=/etc/etcd/pki/server.key
```

```
https://10.0.0.1:2379 is healthy: successfully committed proposal …
https://10.0.0.2:2379 is unhealthy: etcdserver: request timed out
https://10.0.0.3:2379 is healthy: successfully committed proposal …
```

## Root Cause

etcd requires a quorum (majority) of members to agree on every write. In a
3-member cluster the quorum is 2. The common root causes:

1. **Quorum loss** — 2 of 3 members down → no quorum → the API server rejects
   all writes (reads may still serve from cache briefly). This is a total
   control-plane outage.
2. **Disk latency / fsync stalls** — etcd must fsync every write to disk. If
   the disk is slow (>10ms) or saturated, every proposal is slow and the API
   server times out. This is the most common *degraded* (not down) etcd
   failure.
3. **Memory/CPU pressure on the etcd host** — etcd is latency-sensitive; a
   noisy neighbor (or co-located workload) inflates p99 proposal latency.
4. **Database size limit (`--quota-backend-bytes`, default 2/8GB)** — when the
   DB hits the quota, etcd goes read-only and the API server rejects writes
   with `mvcc: database space exceeded`.
5. **Network partition between members** — members cannot reach each other,
   quorum is lost even though each member is individually up.

This scenario's example: a 3-member etcd where one member's disk became slow
(`fsync` p99 > 50ms), inflating proposal latency cluster-wide. Quorum is not
lost, but every API write is slow — `kubectl` hangs and Pod creation stalls.

## Diagnosis

### 1. Confirm the control plane is the bottleneck

```bash
time kubectl get nodes
kubectl get --raw='/readyz?verbose'
kubectl get --raw='/healthz'
```

`/readyz` shows each control-plane component's readiness; an `etcd` line of
`[-]etcd failed: …` points directly at etcd.

### 2. Check etcd endpoint health (self-managed clusters)

```bash
ETCDCTL_API=3 etcdctl endpoint health --cluster --cacert=… --cert=… --key=…
ETCDCTL_API=3 etcdctl endpoint status --cluster --write-out=table --cacert=… --cert=… --key=…
```

`status` shows each member's `db size`, `is leader`, `raft term`, and
`raft index` — useful for spotting a member that is behind or oversized.

### 3. Measure etcd latency

```bash
ETCDCTL_API=3 etcdctl check perf --load=s --prefix=/lab --cacert=… --cert=… --key=…
```

This runs a load test; a slow disk shows a low `total` and high p99.

### 4. Inspect the etcd member logs

```bash
# On the etcd host:
journalctl -u etcd --no-pager | tail -100
```

Look for: `apply entries took too long`, `slow fdatasync`, `etcdserver:
request timed out`, `failed to send out heartbeat on time`, `leader changed`,
`database space exceeded`.

### 5. Check the etcd host's disk

```bash
# On the etcd host:
iostat -x 1 5
df -h /var/lib/etcd
```

A disk with `%util` near 100 or high `await` is starving etcd's fsync.

### 6. Check etcd DB size vs quota

```bash
ETCDCTL_API=3 etcdctl endpoint status --cluster --write-out=table …
```

Compare `DB_SIZE` to `--quota-backend-bytes`. Near the quota, writes start
failing with `mvcc: database space exceeded`.

### 7. Check the API server logs for etcd errors

```bash
kubectl logs -n kube-system -l component=kube-apiserver --tail=50 | grep -i etcd
```

`etcdserver: request timed out`, `rpc error: code = Unavailable`, and
`leader changed` all trace back to etcd.

## Resolution

### Fix A — Revive or replace a down member (quorum loss)

If a member is down and cannot be revived, remove it and add a replacement:

```bash
ETCDCTL_API=3 etcdctl member remove <member-id> …
ETCDCTL_API=3 etcdctl member add etcd-3 --peerURLs=https://10.0.0.4:2380 …
```

Then start etcd on the new host with `--initial-cluster-state existing`.

### Fix B — Fix disk latency (degraded, not down)

- Move etcd to a faster disk (SSD/NVMe; on AWS use io2/gp3 with provisioned
  IOPS).
- Stop co-locating other I/O-heavy workloads on the etcd host.
- Ensure the etcd data dir is on a dedicated disk.

### Fix C — Compact and defrag to reclaim space (DB near quota)

```bash
ETCDCTL_API=3 etcdctl compact <rev> …
ETCDCTL_API=3 etcdctl defrag --cluster …
```

Then raise `--quota-backend-bytes` and investigate what is writing bloat
(events not being garbage-collected, large objects in `configmaps`/`secrets`).

### Fix D — Stop noisy neighbors

On self-managed clusters, do not run user workloads on control-plane nodes.
A CPU-hogging Pod co-located with etcd inflates proposal latency.

### Verify

```bash
ETCDCTL_API=3 etcdctl endpoint health --cluster …
time kubectl get nodes
kubectl get --raw='/readyz'
```

Proposal latency back to single-digit ms and `kubectl` returns instantly.

## Best Practices

- **Run 3 or 5 etcd members** for quorum; never 2 (no failure tolerance) and
  never an even number (split-brain risk).
- **Dedicate a fast disk to etcd** — NVMe/SSD with provisioned IOPS; fsync
  latency is the #1 etcd performance killer.
- **Never co-locate user workloads on control-plane nodes.** etcd is
  latency-sensitive and a noisy neighbor degrades the whole cluster.
- **Back up etcd regularly** with `etcdctl snapshot save`; test restores. On
  managed clouds, the provider handles this — know your RPO/RTO anyway.
- **Monitor etcd metrics**: `etcd_disk_wal_fsync_duration_seconds`,
  `etcd_server_proposals_failed_total`, `etcd_mvcc_db_total_size_in_bytes`,
  `etcd_server_leader_changes_seen_total`. Alert on fsync p99 > 10ms and any
  leader change.
- **Set `--quota-backend-bytes`** with headroom and alarm on DB size > 80%.

## Production Tips

- On EKS/GKE/AKS etcd is managed and invisible. The symptom of provider-side
  etcd degradation is API throttling/latency with no Pod at fault — check the
  provider status page and open a support ticket; you cannot `etcdctl` it.
- `etcdserver: leader changed` in the API server logs is a strong signal of
  member flapping. Each leader change briefly blocks all writes; a cluster
  doing this repeatedly is effectively down even if `kubectl get` sometimes
  works.
- A full etcd DB (`database space exceeded`) makes the cluster read-only. The
  most common cause is objects with very large `metadata.annotations` (e.g.
  huge Helm release secrets). Audit and compact; do not just raise the quota.
- During an etcd outage, `kubectl get` from cache may still return stale data
  — do not trust statuses during the outage; re-verify after recovery.
- Snapshots are your restore path. Practice restoring into a fresh cluster
  quarterly; an untested backup is not a backup. On self-managed clusters,
  automate `etcdctl snapshot save` to S3 and alert on failure.
- etcd member clocks must be in sync (NTP/chrony). Clock skew causes
  unpredictable leader election and "false" member failures that are hard to
  reproduce.
