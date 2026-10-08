# 17 - Service mesh (Istio) misconfiguration

## Prerequisite

This scenario requires **Istio installed** on the cluster
(`istioctl install --set profile=demo -y`) to reproduce fully. Without it,
the `PeerAuthentication` manifest is rejected because the
`security.istio.io` CRDs are absent, which is itself a useful signal: a
cluster with mesh manifests but no mesh.

## Overview

A service mesh like Istio moves networking concerns — mTLS, retries, traffic
splitting, telemetry — into a **sidecar proxy** injected next to each
application container. Traffic between meshed Pods is intercepted by the
sidecar; when injection or the mesh policy is misconfigured, the failure is
subtle: Pods are `Running`, but requests fail with connection resets, `503 UH`
(upstream unhealthy) or mTLS handshake errors, and replicas show `1/1` instead
of the expected `2/2`.

From an SRE perspective mesh misconfiguration is a **networking control-plane**
problem: the app is fine, the mesh (injection, `PeerAuthentication`,
`DestinationRule`, `VirtualService`) is not.

This scenario reproduces the two most common shapes:

1. The namespace is labelled `istio-injection: enabled`, but the sidecar is
   **not injected** (`READY 1/1`) — usually because Istio is not installed, or
   the injection label does not match `istiod`'s revision/selector.
2. `PeerAuthentication` is set to `STRICT` mTLS, so any Pod **without** a
   sidecar (or with a broken cert) has its plaintext traffic refused.

> This scenario requires a cluster with Istio installed to reproduce fully. On
> Minikube/Kind without Istio, applying the manifests shows the *symptom* of
> shape 1: the label is a no-op and Pods run `1/1`.

## Symptoms

```bash
kubectl get pods -n ktslab
```

```
NAME                   READY   STATUS    RESTARTS   AGE
api-7c9d4f6b8b-1       1/1     Running   0          2m
```

`1/1` instead of `2/2` means **no sidecar** was injected.

With a meshed client, requests to the service fail:

```bash
kubectl exec -n ktslab deploy/api -c istio-proxy -- \
  curl -sS http://api.ktslab.svc.cluster.local:8080/
# curl: (56) Recv failure: Connection reset by peer
# or a 503 with response_flags UH / UF
```

`istioctl` reports the drift directly:

```bash
istioctl analyze -n ktslab
```

```
Error [IST0101] ... Pod is not part of the mesh (no sidecar)
Warning [IST0102] ... PeerAuthentication STRICT but Pod has no sidecar
```

## Root Cause

**Shape 1 — no injection.** The label `istio-injection: enabled` only works if
the Istio sidecar-injector webhook is installed and watching that label. If
Istio is not installed, the namespace is labelled but nothing injects the
sidecar; the pods run with a single container. If a revisioned install is used
(`istio.io/rev=1-20`), the `istio-injection` label is ignored entirely.

**Shape 2 — STRICT mTLS with un-meshed Pods.** `PeerAuthentication` with
`mtls.mode: STRICT` makes the mesh reject any non-mTLS connection. A Pod
without a sidecar (or a client outside the mesh) sends plaintext; the
destination sidecar refuses it, and the connection fails. `PERMISSIVE` mode
accepts both, which is the safe default during migration.

Other common mesh root causes:

- Ingress gateway not pointing at the right `VirtualService` / host.
- `DestinationRule` with `trafficPolicy.tls` mismatching the workload's mTLS.
- Sidecar resource limits too low → the proxy OOMs and the Pod flaps.
- Stale `istiod` after a control-plane upgrade (injector version skew).

## Diagnosis

### 1. Confirm whether a sidecar exists

```bash
kubectl get pods -n ktslab -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'
```

Look for `istio-proxy` next to your app container.

### 2. Check the namespace labels and the injector

```bash
kubectl get namespace ktslab --show-labels
kubectl get mutatingwebhookconfiguration | grep -i istio
kubectl get pods -n istio-system
```

If there is no `istio-sidecar-injector` webhook, nothing will inject.

### 3. Check mTLS policy

```bash
kubectl get peerauthentication -A
kubectl get destinationrule -A
```

A `STRICT` policy plus an un-meshed client is a guaranteed failure.

### 4. Inspect the proxy logs and config

```bash
kubectl logs -n ktslab <pod> -c istio-proxy --tail=50
istioctl proxy-config cluster <pod> -n ktslab
istioctl analyze -n ktslab
```

`istioctl analyze` is the fastest way to surface injection and policy drift.

## Resolution

### Fix A — Actually inject the sidecar

Install Istio and label the namespace correctly:

```bash
istioctl install --set profile=demo -y
kubectl label namespace ktslab istio-injection=enabled --overwrite
# ...or, for a revisioned install:
# kubectl label namespace ktslab istio.io/rev=<revision> --overwrite
kubectl rollout restart deployment -n ktslab
```

Pods must be recreated to get the sidecar (`2/2`).

### Fix B — Relax mTLS during migration

Use `PERMISSIVE` while un-meshed clients still exist, then move to `STRICT`:

```yaml
spec:
  mtls:
    mode: PERMISSIVE
```

### Fix C — Fix the routing object

Correct the `VirtualService`/`DestinationRule`/gateway host and port to match
the real Service.

### Verify

```bash
kubectl get pods -n ktslab            # READY 2/2
istioctl analyze -n ktslab            # no errors
kubectl exec -n ktslab deploy/api -c istio-proxy -- curl -sS http://api:8080/
```

## Best Practices

- **Enable mTLS with `PERMISSIVE` first**, then flip to `STRICT` once every
  workload in the namespace is meshed. A premature `STRICT` is a common outage.
- **Roll pods after changing injection labels.** The injector only acts at Pod
  creation; running Pods are untouched.
- **Keep revision labels consistent** (`istio.io/rev`) across the control plane
  and namespaces; `istio-injection` and revision labels do not mix.
- **Set proxy resources.** Give `istio-proxy` CPU/memory requests/limits so it
  is not evicted or throttled.
- **Run `istioctl analyze` in CI** against rendered manifests to catch policy
  drift before it reaches a cluster.

## Production Tips

- A namespace where only *some* Pods are meshed (`READY` mixed `1/1` and `2/2`)
  is the classic precursor to a `STRICT`-mTLS outage — the un-meshed Pods will
  silently start failing as soon as the policy is enforced.
- Sidecar injection adds a container to every Pod: account for the extra
  CPU/memory requests when sizing nodes and HPA targets, or you will hit
  scheduling pressure you did not expect.
- During an Istio upgrade, the injector and the proxies must be version-locked;
  an upgrade that restarts `istiod` mid-rollout can leave half the mesh on the
  old dataplane. Roll namespaces deliberately.
- A `503 UH` (upstream unhealthy) from the ingress gateway usually means the
  gateway has no healthy endpoint — check the workload's readiness and the
  mesh's endpoint discovery, not the app.
- When debugging mesh traffic, always decide first whether a Pod is *in* the
  mesh (`istio-proxy` present) before chasing routing rules.
