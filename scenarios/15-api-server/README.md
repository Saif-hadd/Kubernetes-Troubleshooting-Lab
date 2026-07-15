# 15 - API Server

## Overview

The kube-apiserver is the front door of the cluster: every `kubectl` command,
controller, scheduler, kubelet, and admission webhook talks to it. When the
API server is degraded, the symptom is cluster-wide: commands hang, controllers
stop reconciling, kubelets cannot heartbeat, and nothing progresses — even
though individual Pods may keep running on cached state. From an SRE
perspective this is a **control-plane availability** incident with the widest
possible blast radius short of etcd failure.

This scenario is **control-plane focused** and documentation-driven on
managed clouds (where the provider runs the API server). The manifests deploy
a workload whose lifecycle depends on the API server, so you can observe the
*symptom* of API-server degradation while the README walks the server-side
triage.

## Symptoms

```bash
kubectl get pods -n ktslab
```

```
Unable to connect to the server: EOF
# or
I0715 ... Client.Timeout exceeded while awaiting headers
# or (slow but eventually returns after 20-30s)
NAME                         READY   STATUS    RESTARTS   AGE
webapp-7c9d4f6b8b-1          1/1     Running   0          3m
```

Other cluster-wide symptoms:

- New Pods stay `Pending`/`ContainerCreating` (scheduler cannot talk to API).
- Deployments do not roll out (controller-manager cannot reconcile).
- `kubectl get events` is empty or stale (events are not being persisted).
- Nodes flip `Ready` to `Unknown` (kubelet cannot heartbeat).

## Root Cause

The API server has several independent failure modes, each with a different
fix:

1. **Overload / authentication floods** — a misbehaving controller or a
  credential rotation storm hammers `authenticate`/`authorize`, inflating p99
  and timing out normal requests. The most common "slow API" cause.
2. **Webhook admission timeouts** — a `MutatingWebhook`/`ValidatingWebhook`
  points at a service that is down or slow; every Pod/Deployment create blocks
  on the webhook's timeout (default 10s), stalling all writes.
3. **etcd latency** — every API write is an etcd proposal; slow etcd = slow
  API server (see scenario 14).
4. **Cert expiry / rotation** — the apiserver serving cert or the
  client-ca bundle expired; clients fail TLS handshake (`x509: certificate
  has expired`).
5. **Network/control-plane endpoint issues** — the load balancer in front of
  the API server is unhealthy, or a firewall drops the control-plane endpoint.
6. **Resource exhaustion on the API server host** — CPU/memory limits on the
  apiserver Pod (self-managed) or provider-side throttling.

This scenario's example: a `ValidatingWebhook` configured with a 10s timeout
points at a service whose backing Pods are down. Every Pod creation blocks
for 10s then fails, so new workloads never start — the API server itself is
healthy, but the admission chain stalls all writes.

## Diagnosis

### 1. Confirm the API server is reachable and measure latency

```bash
time kubectl get nodes
kubectl get --raw='/readyz?verbose'
kubectl get --raw='/livez?verbose'
kubectl get --raw='/healthz'
```

`/readyz?verbose` lists each readiness check (`etcd`, `informer-sync`,
`webhook`). A failing check names the sub-component.

### 2. Check API server latency metrics

```bash
kubectl get --raw='/metrics' | grep -E 'apiserver_request_duration_seconds|apiserver_request_total|etcd_request_duration_seconds|workqueue_depth'
```

Key signals:

- `apiserver_request_duration_seconds` p99 rising → API server or etcd slow.
- `apiserver_request_total{code="5xx"}` rising → server errors.
- `workqueue_depth` high for a controller → a controller is stuck.

### 3. Inspect admission webhooks — the critical step for the example cause

```bash
kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations
kubectl describe validatingwebhookconfiguration <name>
kubectl get svc -n <ns> <webhook-service>
kubectl get endpoints -n <ns> <webhook-service>
```

If a webhook's backing Service has no Endpoints (or the webhook service is
down), every matched create/update blocks for the webhook's `timeoutSeconds`
then fails.

### 4. Check API server logs (self-managed)

```bash
kubectl logs -n kube-system -l component=kube-apiserver --tail=100
kubectl logs -n kube-system -l component=kube-apiserver | grep -iE 'timeout|failed|webhook|etcd|throttl'
```

Look for `failed to call webhook`, `context deadline exceeded`,
`etcdserver: request timed out`, `Too many requests`.

### 5. Verify the control-plane endpoint (LB)

```bash
kubectl cluster-info
# From a host with network access:
curl -k -v https://<api-server-endpoint>/healthz
```

A 5xx or timeout at the LB indicates a control-plane endpoint/LB issue.

### 6. Check certificate validity

```bash
openssl s_client -connect <api-server-endpoint>:443 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -dates
```

`notAfter` in the past = expired serving cert. On managed clouds the provider
rotates these; on self-managed clusters, `kubeadm certs check-expiration`.

### 7. Check controller-manager / scheduler health (downstream of API)

```bash
kubectl get --raw='/readyz' | grep -E 'controller-manager|scheduler'
kubectl get pods -n kube-system -l component=kube-controller-manager
kubectl get pods -n kube-system -l component=kube-scheduler
```

If these are not ready, reconciliation is stalled even if the API server
serves reads.

## Resolution

### Fix A — Remove or fix the failing admission webhook

If a webhook's backing service is down, either restore it or remove the
webhook configuration so writes are not blocked:

```bash
kubectl delete validatingwebhookconfiguration <broken-name>
```

Or fix the webhook service/Endpoints, or set `timeoutSeconds: 1` and
`failurePolicy: Ignore` so a down webhook does not stall all writes.

### Fix B — Reduce authentication/authorization load

Find and throttle the misbehaving client (a rogue controller, a token-rotation
storm). Rate-limit the API server with `--max-mutating-requests-inflight` and
`--max-requests-inflight` tuning, and fix the noisy client.

### Fix C — Fix etcd latency (scenario 14)

If `/readyz` shows etcd slow, follow the etcd scenario.

### Fix D — Renew expired certificates (self-managed)

```bash
kubeadm certs renew all
systemctl restart kube-apiserver kube-controller-manager kube-scheduler etcd
```

On managed clouds, open a provider ticket if serving certs are expired
(rare — the provider rotates them).

### Fix E — Fix the control-plane load balancer

On self-managed clusters, ensure the API server LB health check targets
`/healthz` and all control-plane nodes are healthy. On managed clouds, check
the provider status page.

### Verify

```bash
time kubectl get nodes
kubectl get --raw='/readyz?verbose'
kubectl get pods -n ktslab
```

API calls return in < 1s, all readiness checks pass, workloads progress.

## Best Practices

- **Keep admission webhooks fast and resilient.** Set `timeoutSeconds: 1-3`
  and `failurePolicy: Ignore` for non-critical webhooks so a down webhook does
  not stall all writes; only enforce (`Failure`) on webhooks you cannot ship
  without.
- **Monitor API server latency SLOs**: `apiserver_request_duration_seconds`
  p99 per verb/resource, and 5xx rate. A rising p99 is the earliest signal.
- **Budget in-flight requests** with `--max-mutating-requests-inflight` and
  `--max-requests-inflight` so a single noisy client cannot saturate the API.
- **Rotate certificates proactively.** On self-managed clusters, alert on
  cert expiry 30 days out; on managed clouds, trust the provider but know the
  rotation schedule.
- **Run multiple API server replicas** behind an LB for availability; a
  single apiserver is a cluster-wide SPOD.
- **Audit webhook configurations in PR review** — a new webhook with a broad
  `rules` match and a slow backing service can silently stall the cluster.

## Production Tips

- A "slow `kubectl`" with healthy Pods is almost always the API server (or
  etcd), not the workload. Always time `kubectl get nodes` early in a
  cluster-wide incident.
- On EKS, the API server is managed and scales with the cluster, but it has
  per-cluster request limits. A rogue controller doing LISTs on a large
  resource can trip `RequestTooLarge` and throttling. Use `ResourceVersion`
  / WATCHes / field selectors to limit LIST sizes.
- Admission webhooks are the #1 cause of mysterious "Pods won't create"
  incidents. When writes stall but reads are fine, check webhooks before etcd.
- `failurePolicy: Fail` on a webhook that points at a service with no
  Endpoints turns a single Pod failure into a cluster-wide write outage.
  Prefer `Ignore` for non-essential webhooks.
- The `--shutdown-delay-duration` and graceful shutdown of the API server
  matter during upgrades: in-flight requests need time to drain. Self-managed
  clusters that kill the apiserver hard drop connections mid-rollout.
- A kubelet that cannot reach the API server keeps Pods running on cached
  state but stops reporting status and honoring deletions. The node appears
  healthy while quietly diverging — always check API connectivity, not just
  node `Ready`, during a control-plane incident.
- During an API server outage, do not run destructive commands assuming
  cached state is accurate. Reads may serve stale data; wait for recovery and
  re-verify before deleting/scaling.
