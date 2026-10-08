# 24 - DNS ndots / search domain storms

## Overview

Every Pod's `/etc/resolv.conf` has a `search` list and an `options ndots:N`
(default **5**). A name with **fewer than N dots** is first tried against each
search domain before being resolved as an absolute name. So a single unqualified
external lookup like `api.example.com` (2 dots < 5) becomes up to **6** DNS
queries, and a fully-qualified name (or one with ≥ ndots) is tried once.

On a busy service — especially one that resolves external names in a hot path —
this multiplies DNS QPS and latency, and is a very common source of "external
API is slow from inside the cluster but fast from my laptop" reports.

From an SRE perspective it is a **configuration-driven latency** problem: no
component is broken; the default `ndots` is simply wrong for the workload.

## Symptoms

- External name resolution from Pods is **slow** (tens of milliseconds),
  internal Service names are fast.
- Elevated CoreDNS QPS and latency; sometimes CoreDNS CPU pressure (and then
  *everything* is slow — see scenario 07).
- A single request triggers several DNS queries visible in the CoreDNS logs or
  in a debug `nslookup`.
- Tail latency on services that call external APIs, without an obvious cause.

## Root Cause

The Pod uses the default DNS config:

```
search ktslab.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

An unqualified name `api.example.com` has 2 dots (`< ndots:5`), so the resolver
appends the search domains:

```
api.example.com.ktslab.svc.cluster.local   -> NXDOMAIN
api.example.com.svc.cluster.local          -> NXDOMAIN
api.example.com.cluster.local              -> NXDOMAIN
api.example.com.                           -> the real answer
```

Multiply this by the QPS of the calling service and you have a DNS storm.

## Diagnosis

### 1. Read the Pod's resolv.conf

```bash
POD=$(kubectl -n ktslab get pod -l app=resolver -o jsonpath='{.items[0].metadata.name}')
kubectl -n ktslab exec "$POD" -- cat /etc/resolv.conf
```

Note `ndots:5` and the three `search` entries.

### 2. Watch the extra lookups for one name

```bash
./scenarios/24-dns-ndots-storms/diagnose.sh ktslab
# busybox nslookup has no -debug; use a netshoot Pod to see every attempt:
kubectl -n ktslab run dnsdebug --rm -i --restart=Never --image=nicolaka/netshoot \
  -- dig +search +noall +answer +comments api.external.example.com
```

`dig +search` (or any debug-capable resolver) prints every query the resolver
issues — you will see the search domains tried before the real external name.

### 3. Measure the difference with a lower ndots (or an FQDN)

```bash
# Fully-qualified name -> a single query
kubectl -n ktslab exec "$POD" -- nslookup api.external.example.com.
```

### 4. Check CoreDNS load

```bash
kubectl -n kube-system top pods -l k8s-app=kube-dns 2>/dev/null || true
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50 | tail -n 20
```

## Resolution

### Fix A — Lower ndots for the workload

Add a `dnsConfig` to the Pod spec:

```yaml
spec:
  dnsConfig:
    options:
      - name: ndots
        value: "2"
```

This makes `api.example.com` (2 dots ≥ 2) resolve as absolute — one query.

### Fix B — Use fully-qualified names

End the name with a trailing dot (`api.example.com.`) or use an in-cluster FQDN
(`db.ktslab.svc.cluster.local.`) so the resolver skips the search list.

### Fix C — Prefer in-cluster names for in-cluster calls

Talk to Services by their cluster-local name (`db.ktslab.svc.cluster.local`)
rather than anything that triggers a search-list walk.

### Fix D — Reduce the search list / scale CoreDNS

Set a minimal `dnsConfig.searches`, and ensure CoreDNS has enough replicas and
CPU (scenario 07) to absorb the legitimate QPS.

### Verify

```bash
kubectl apply -f scenarios/24-dns-ndots-storms/deployment.yaml   # after uncommenting dnsConfig
kubectl -n ktslab exec "$POD" -- cat /etc/resolv.conf            # ndots:2
kubectl -n ktslab exec "$POD" -- cat /etc/resolv.conf     # ndots:2
kubectl -n ktslab run dnsdebug --rm -i --restart=Never --image=nicolaka/netshoot \
  -- dig +search +noall +answer +comments api.external.example.com
# Expect one external query, no search-domain attempts.
```

## Best Practices

- **Set `ndots` deliberately per workload.** The default of 5 is tuned for
  in-cluster lookups; external-heavy services should use `1`–`2`.
- **Use FQDNs for external dependencies.** A trailing dot removes the search
  walk entirely.
- **Deploy NodeLocal DNSCache** so Pods resolve through a node-local cache and
  do not hammer CoreDNS.
- **Monitor DNS QPS and latency** (`coredns_dns_request_duration_seconds`); a
  search-domain storm shows up as a QPS spike, and only then as app latency.
- **Keep the search list short**; every extra search domain multiplies the
  worst-case query count.

## Production Tips

- "External calls are slow from Pods but fine from my laptop" is almost always
  `ndots:5` + search domains, not the network. Confirm with `nslookup -debug`.
- A DNS storm often manifests first as **CoreDNS CPU throttling** (scenario 05)
  and then as cluster-wide latency — fix the `ndots` before scaling CoreDNS,
  or you scale a problem instead of solving it.
- `ndots` is also propagated to sidecars (service mesh); a misconfigured mesh
  client can multiply queries further. Set the option once, at the Pod template.
- FQDNs are the cheapest fix and the easiest to review; consider making them a
  lint rule for outbound endpoints.
- After changing `dnsConfig`, Pods must be recreated — an existing Pod keeps its
  current `/etc/resolv.conf`.
