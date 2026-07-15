# 10 - NetworkPolicy

## Overview

A `NetworkPolicy` controls which traffic is allowed to and from Pods. Once any
`NetworkPolicy` selects a Pod, that Pod becomes **isolated** for the direction
(ingress/egress) the policy covers — all traffic not explicitly allowed is
denied. From an SRE perspective this is a **default-deny** failure: a Pod is
`Running` and `Ready`, but connections to or from it silently drop because a
policy (often intended for another workload) is selecting it, or a policy is
too restrictive.

The trap: NetworkPolicy enforcement depends on the CNI. Calico/Cilium enforce
policies; the default Minikube/Kind bridge CNI often does **not**. So a policy
that works in production (EKS with VPC CNI + Calico) may silently be a no-op in
a lab — and vice versa, a policy that breaks production may look harmless in
the lab.

This scenario reproduces the classic shape: a default-deny ingress policy
isolates a database Pod, but the policy omits the rule that allows the
application namespace to reach it, so the app gets connection timeouts.

## Symptoms

```bash
kubectl get pods -n ktslab -o wide
```

```
NAME                         READY   STATUS    RESTARTS   AGE   NODE
api-7c9d4f6b8b-x1y2z        1/1     Running   0          3m    m02
db-7d8c5b9f6d-q3w4e         1/1     Running   0          3m    m03
```

Both Pods healthy. But the app cannot reach the DB:

```bash
kubectl exec -n ktslab api-7c9d4f6b8b-x1y2z -- \
  wget -T3 -qO- http://db.ktslab.svc.cluster.local:5432/
```

```
Connecting to db.ktslab.svc.cluster.local:5432 (10.96.x.x:5432)
wget: can't connect to host: Connection timed out
```

## Root Cause

A `NetworkPolicy` named `db-deny-ingress` selects the `db` Pod (via
`app: db`) and sets `podSelector: {}` under `policyTypes: [Ingress]` — a
**default-deny all ingress**. The policy does not include any `ingress` `from`
rule that permits the `api` Pod's namespace/Pod to reach it. Because any
policy selecting a Pod isolates it for that direction, the DB now accepts
traffic from **nothing**, and the app's connections time out.

The CNI enforces this in the dataplane (iptables/eBPF drops), so there are no
Pod-level events — the connection simply never completes.

## Diagnosis

### 1. Confirm Pods and Services are healthy, traffic fails

```bash
kubectl get pods -n ktslab -o wide
kubectl get svc -n ktslab db
kubectl get endpoints -n ktslab db
kubectl exec -n ktslab <api-pod> -- wget -T3 -qO- http://db.ktslab.svc.cluster.local:5432/
```

If Endpoints exist and a direct exec `nc`/`wget` to the Pod IP also times out,
suspect NetworkPolicy (or CNI). If Pod-IP works but Service-IP fails, suspect
Service/Endpoints, not NetworkPolicy.

### 2. List the NetworkPolicies selecting the Pod — the critical step

```bash
kubectl get networkpolicy -n ktslab -o wide
kubectl get networkpolicy -n ktslab --show-labels
```

Then check which policies actually select the target Pod:

```bash
kubectl get pod -n ktslab <db-pod> --show-labels
```

Compare the policy `podSelector` to the Pod's labels — any match means the
policy applies.

### 3. Read the policy in detail

```bash
kubectl describe networkpolicy -n ktslab db-deny-ingress
kubectl get networkpolicy -n ktslab db-deny-ingress -o yaml
```

Check `policyTypes`, `podSelector`, and the `ingress`/`egress` rules. An
empty `ingress: []` with `policyTypes: [Ingress]` = default deny all ingress.

### 4. Test with a temporary allow policy

Add a broad allow policy temporarily to confirm NetworkPolicy is the cause:

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: tmp-allow-all
  namespace: ktslab
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress: [{}]
  egress: [{}]
EOF
```

If traffic recovers, a policy was blocking it. Remove the temp policy and
narrow down which one.

### 5. Verify the CNI enforces policies

```bash
kubectl get pods -n kube-system | grep -iE 'calico|cilium|weave|antrea'
```

If no enforcing CNI is present (e.g. plain Kind), NetworkPolicies are no-ops
and the failure is something else. On EKS, VPC CNI does **not** enforce
NetworkPolicy by default — you must install Calico/Cilium in enforcement mode.

### 6. Check egress from the client side too

A client Pod can also be egress-isolated:

```bash
kubectl describe networkpolicy -n ktslab --field-selector …
# look for policyTypes: [Egress] selecting the api Pod
```

### 7. Use a CNI-specific debug tool

For Calico: `calicoctl get policy -o wide`. For Cilium: `cilium monitor` or
`hubble observe` to see the actual allow/deny decisions in the dataplane.

## Resolution

### Fix A — Add an ingress allow rule for the app

Extend the DB policy to allow ingress from the `api` Pod/namespace:

```yaml
policyTypes:
  - Ingress
ingress:
  - from:
      - podSelector:
          matchLabels:
            app: api
    ports:
      - protocol: TCP
        port: 5432
```

### Fix B — Narrow the policy's podSelector

If the default-deny was meant for a different workload, fix the
`podSelector` so it no longer selects the DB:

```yaml
podSelector:
  matchLabels:
    app: restricted-app   # not db
```

### Fix C — Remove the over-broad policy

If the default-deny was accidental, delete it:

```bash
kubectl delete networkpolicy -n ktslab db-deny-ingress
```

### Fix D — Install/enable an enforcing CNI

On a cluster where policies are no-ops, install Calico or Cilium in
enforcement mode so the intended isolation actually takes effect.

### Verify

```bash
kubectl exec -n ktslab <api-pod> -- wget -T3 -qO- http://db.ktslab.svc.cluster.local:5432/
kubectl get networkpolicy -n ktslab
```

## Best Practices

- **Default-deny is the right baseline**, but add explicit allow rules for
  every legitimate flow — and test them. A default-deny without allow rules
  is an outage waiting to happen.
- **Label Pods deliberately** (`app`, `tier`, `team`) so policies can target
  workloads by label rather than namespace-wide sweeps that over-select.
- **Scope policies with both `namespaceSelector` and `podSelector`** to avoid
  accidentally isolating workloads in other namespaces that share labels.
- **Test policies in a cluster with an enforcing CNI** — a no-op CNI gives
  false confidence that a policy is safe.
- **Keep an "allow all" debug policy as a manifest**, disabled by default, to
  toggle during incidents to confirm/deny NetworkPolicy as the cause.
- **Monitor CNI policy deny counters** (Calico/Cilium metrics) — a spike in
  denied packets often surfaces a misapplied policy before humans notice.

## Production Tips

- On EKS, VPC CNI does not enforce NetworkPolicy. Install Calico (in
  enforcement mode) or Cilium; without it, every `NetworkPolicy` is silently
  ignored, which is both a false sense of security and a debugging trap.
- Cilium Hubble gives live flow visibility (`hubble observe --from-pod …`):
  use it to see exactly which policy denied a flow, instead of guessing from
  manifests.
- A policy that selects `{}` (all Pods) for `Egress` with no `egress` rules
  breaks DNS for the entire namespace — CoreDNS runs in `kube-system`, and
  unless egress allows `kube-system` on port 53, every Pod loses name
  resolution. Always allow DNS in egress-restrictive policies.
- Order of policy evaluation: NetworkPolicies are **additive allow** — a flow
  is allowed if *any* selecting policy allows it. There is no priority; a
  single permissive policy can override an intended deny. Model this in reviews.
- When migrating from no policies to default-deny, do it namespace by
  namespace, with a broad allow policy in place first, then narrow — a
  big-bang default-deny across the cluster is a classic outage.
- For multi-tenant clusters, combine NetworkPolicy with per-namespace
  `namespaceSelector` admission and RBAC (scenario 11) for defense in depth.
