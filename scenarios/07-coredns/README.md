# 07 - CoreDNS

## Overview

CoreDNS is the default cluster DNS server. Every Pod that uses the
`clusterDNS` setting (i.e. virtually all of them) resolves service names
through the `kube-dns` Service, which load-balances to CoreDNS Pods. When
CoreDNS is broken, the failure is **cluster-wide and silent at the Pod level**:
Pods are `Running` and `Ready`, but any name resolution — `db.svc.cluster.local`,
`api.default.svc`, even external names — fails or stalls. From an SRE
perspective this is a **shared dependency outage** with a very large blast
radius.

This scenario reproduces the most common production shape: CoreDNS Pods
themselves are healthy, but the `kube-dns` Service has a broken/empty
Endpoints set (selector mismatch), so DNS queries go nowhere. The CoreDNS
binary is fine; the routing to it is broken.

## Symptoms

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

```
NAME                       READY   STATUS    RESTARTS   AGE
coredns-6d4b8c9f7d-a1b2c   1/1     Running   0          10m
coredns-6d4b8c9f7d-x3y4z   1/1     Running   0          10m
```

CoreDNS looks healthy. But a workload Pod fails DNS:

```bash
kubectl exec -n ktslab webapp-7c9d -- nslookup db.ktslab.svc.cluster.local
```

```
;; connection timed out; no servers could be reached
```

or

```
;; SERVFAIL
```

or partial failures (external names fail, internal names work — a classic
`forward plugin` / `ndots` signature).

## Root Cause

The `kube-dns` Service is meant to select CoreDNS Pods via a label selector.
In this scenario the Service's selector does **not** match the CoreDNS Pods'
labels (a misconfigured selector), so the Service has **zero Endpoints**. Every
DNS query from every Pod is sent to a Service with no backing Pods and is
dropped. The CoreDNS Pods are perfectly healthy — they just never receive
traffic.

Other common CoreDNS root causes (same triage path):

- CoreDNS Pods CrashLoopBackOff (bad `Corefile` plugin config).
- `ndots:5` causing every external lookup to try 5 search domains first,
  multiplying latency and hitting external resolvers via the cluster DNS.
- Node-local DNS not configured; every Pod crosses the node for DNS and
  saturates CoreDNS under load.
- `forward .` pointing at a stale upstream that is unreachable.

## Diagnosis

### 1. Check CoreDNS Pods

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
kubectl logs -n kube-system <coredns-pod> --tail=50
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=20
```

If the Pods are `CrashLoopBackOff`, the `Corefile` or an upstream is the
problem — read the logs.

### 2. Check the kube-dns Service and its Endpoints — the critical step

```bash
kubectl get svc -n kube-system kube-dns -o wide
kubectl get endpoints -n kube-system kube-dns
kubectl get endpointslice -n kube-system -l kubernetes.io/service-name=kube-dns
```

If `ENDPOINTS` is `<none>` while CoreDNS Pods are Running, the Service
selector is broken — exactly this scenario. If Endpoints exist, DNS traffic is
reaching CoreDNS and the problem is upstream (Corefile, ndots, forward).

### 3. Compare the Service selector to the Pod labels

```bash
kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.selector}'
kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].metadata.labels}'
```

A mismatch here is the root cause.

### 4. Test DNS from inside a Pod

```bash
kubectl exec -n ktslab <pod> -- nslookup kubernetes.default.svc.cluster.local
kubectl exec -n ktslab <pod> -- nslookup db.ktslab.svc.cluster.local
kubectl exec -n ktslab <pod> -- nslookup www.example.com
```

Distinguish:

- Internal fail + external fail → CoreDNS unreachable (this scenario).
- Internal works + external fails → `forward` upstream broken.
- External works + internal fails → CoreDNS not reaching the API for service
  discovery.

### 5. Inspect the Corefile

```bash
kubectl get configmap -n kube-system coredns -o yaml
```

Look for the `.:53` block, `kubernetes cluster.local` plugin, and `forward .`
upstream.

### 6. Check the Pod's DNS config

```bash
kubectl exec -n ktslab <pod> -- cat /etc/resolv.conf
```

High `ndots` (default 5) + `search` list can cause a storm of lookups for
single-label names; this is a latency issue more than a hard failure.

### 7. Confirm with a direct query to a CoreDNS Pod (bypass the Service)

```bash
COREDNS_IP=$(kubectl get pod -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}')
kubectl exec -n ktslab <pod> -- nslookup kubernetes.default.svc.cluster.local $COREDNS_IP
```

If direct-to-Pod works but via-Service fails, the Service/Endpoints layer is
the problem (this scenario). If both fail, CoreDNS itself is the problem.

## Resolution

### Fix A — Correct the Service selector

```bash
kubectl patch svc -n kube-system kube-dns --type=json \
  -p='[{"op":"replace","path":"/spec/selector","value":{"k8s-app":"kube-dns"}}]'
```

Endpoints populate within seconds and DNS recovers.

### Fix B — Fix a crashing CoreDNS Pod

Edit the `Corefile` ConfigMap to remove the offending plugin/misconfig, then:

```bash
kubectl rollout restart deployment/coredns -n kube-system
```

### Fix C — Fix the upstream forward

In the `Corefile`, set `forward . <reachable-upstream>` (e.g. a known-good
resolver or the node's `/etc/resolv.conf`).

### Fix D — Reduce ndots latency

For workloads doing many external lookups, set `dnsConfig` with a lower
`ndots`:

```yaml
spec:
  dnsConfig:
    options:
      - name: ndots
        value: "2"
```

### Verify

```bash
kubectl get endpoints -n kube-system kube-dns
kubectl exec -n ktslab <pod> -- nslookup db.ktslab.svc.cluster.local
```

## Best Practices

- **Always check Endpoints, not just Pods.** A healthy CoreDNS with an empty
  Endpoints set is the most easily missed DNS outage.
- **Deploy NodeLocal DNSCache** in production to cut per-Pod DNS latency and
  protect CoreDNS from QPS spikes.
- **Keep the Corefile minimal and version-pinned.** Plugins like `autopath`
  or experimental plugins have caused production outages.
- **Set realistic `resources` for CoreDNS** — under high QPS it can CPU-throttle
  (see scenario 05) and every Pod in the cluster feels it.
- **Monitor DNS latency and error rate** (`coredns_dns_request_duration_seconds`,
  `coredns_dns_response_rcode_count_total`) as a tier-1 SLO.
- **Prefer fully-qualified names** (`db.ktslab.svc.cluster.local.`) or lower
  `ndots` for external-heavy workloads to avoid search-list storms.

## Production Tips

- A CoreDNS outage looks like "everything is flaky" — connections to services
  time out intermittently as DNS fails then succeeds on retry. Always include
  DNS in the first triage step of a broad-latency incident.
- `ndots:5` is the default and is the cause of many "external API is slow from
  Pods but fast from my laptop" reports. Each single-label name triggers up to
  6 lookups. NodeLocal DNS + explicit FQDNs largely fixes this.
- Scale CoreDNS horizontally (HPA on QPS) and run at least 2 replicas on
  different nodes with `podAntiAffinity` — a single CoreDNS on one node is a
  cluster-wide single point of failure.
- If CoreDNS Pods keep restarting with `EOF` in logs, suspect the upstream
  resolver dropping UDP; configure `forward` with `max_concurrent 1000` and a
  reachable upstream, or switch to TCP fallback.
- During a DNS outage, set a Pod-level `dnsPolicy: None` with an explicit
  external resolver only as a last-resort workaround — it breaks in-cluster
  service discovery.
