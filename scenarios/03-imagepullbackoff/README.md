# 03 - ImagePullBackOff

## Overview

`ImagePullBackOff` is the kubelet's backoff state for a container whose image
cannot be pulled from its registry. It is the successor state to `ErrImagePull`
— once the kubelet determines the pull is failing, it stops retrying
aggressively and applies an exponential backoff, just like `CrashLoopBackOff`
but for the **image pull** phase rather than the container runtime phase.

From an SRE perspective this is a **supply-chain / registry** failure: the
scheduler did its job and the kubelet is ready to run the container, but the
artifact is unreachable, mistagged, missing, or unauthorized. It is one of the
few failures that can affect an entire fleet simultaneously (e.g. a registry
outage or a rotated pull credential).

This scenario reproduces the most common shape: a typo'd / non-existent image
reference.

## Symptoms

```bash
kubectl get pods -n ktslab
```

```
NAME                          READY   STATUS              RESTARTS   AGE
api-6d4b8c9f7d-q1w2e          0/1     ImagePullBackOff    0          2m
```

Note `RESTARTS: 0` — the container never started, so there is nothing to
restart. This distinguishes it from `CrashLoopBackOff`.

```bash
kubectl describe pod -n ktslab api-6d4b8c9f7d-q1w2e
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Normal   Scheduled         2m    default-scheduler  Successfully assigned …
  Normal   Pulling           2m    kubelet            Pulling "nginx:1.27.notreal"
  Warning  Failed            2m    kubelet            Error: ErrImagePull
  Warning  Failed            2m    kubelet            Failed to pull image "nginx:1.27.notreal": tag not found
  Normal   BackOff           1m    kubelet            Back-off pulling image "nginx:1.27.notreal"
  Warning  BackOff           30s   kubelet            Back-off pulling image "nginx:1.27.notreal"
```

## Root Cause

The image reference `nginx:1.27.notreal` does not exist in Docker Hub. The
container runtime returns a `manifest unknown` / `tag not found` error, the
kubelet records `ErrImagePull`, and after repeated failures transitions to
`ImagePullBackOff`.

In production the same state is caused by any of:

- A typo'd image name or tag.
- A tag that was deleted or overwritten (mutable tag drift).
- A private registry requiring `imagePullSecrets` that are missing or expired.
- A network policy or egress restriction blocking the registry.
- A registry outage or rate limit (e.g. Docker Hub pull limits).
- A wrong `imagePullPolicy` pulling a tag that no longer matches.

## Diagnosis

### 1. Confirm the state and that there are no restarts

```bash
kubectl get pods -n ktslab --field-selector=status.phase=Pending
kubectl describe pod -n ktslab <pod>
```

### 2. Read the pull error in events

```bash
kubectl get events -n ktslab --sort-by=.lastTimestamp
kubectl get events -n ktslab --field-selector reason=Failed
```

Key error strings and their meaning:

| Error fragment | Likely cause |
|----------------|--------------|
| `manifest unknown` / `tag not found` | Image or tag does not exist |
| `unauthorized` / `required authentication` | Missing/invalid `imagePullSecrets` |
| `rate limit exceeded` | Docker Hub / registry pull quota |
| `i/o timeout` / `context deadline exceeded` | Network/egress blocked |
| `name resolution failed` | DNS to registry failing |

### 3. Inspect the image reference

```bash
kubectl get pod -n ktslab <pod> -o jsonpath='{.spec.containers[*].image}'
```

Check for typos, missing registry prefix, or a wrong tag.

### 4. Check for imagePullSecrets

```bash
kubectl get pod -n ktslab <pod> -o jsonpath='{.spec.imagePullSecrets}'
kubectl get secret -n ktslab
```

If the registry is private and no secret is attached, that is the cause.

### 5. Verify the image exists from a node (or a debug pod)

```bash
kubectl debug node/<node> -it --image=busybox
# inside the node shell:
crictl pull nginx:1.27.notreal
```

Or from a debug Pod with egress:

```bash
kubectl run tmp --rm -it --image=nicolaka/netshoot --restart=Never -- \
  curl -v https://registry-1.docker.io/v2/
```

### 6. Check the kubelet / runtime logs on the node

```bash
kubectl debug node/<node> -it --image=busybox
# journalctl -u kubelet | grep -i pull
```

## Resolution

### Fix A — Correct the image tag

```bash
kubectl set image deployment/api api=nginx:1.27 -n ktslab
kubectl rollout status deployment/api -n ktslab
```

### Fix B — Attach an imagePullSecret for a private registry

```bash
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=ci \
  --docker-password='********' \
  --docker-email=ci@example.com \
  -n ktslab
```

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: regcred
```

### Fix C — Fix egress / network policy

If a NetworkPolicy or node egress firewall blocks the registry, add an
egress rule to the registry IPs/FQDN. See scenario 10.

### Fix D — Use an immutable digest instead of a mutable tag

Pin images by digest to avoid tag drift:

```yaml
image: nginx@sha256:<digest>
```

### Verify

```bash
kubectl rollout status deployment/api -n ktslab
kubectl get pods -n ktslab -l app=api
kubectl describe pod -n ktslab <pod>
```

Events should show `Successfully pulled image` then `Started container`.

## Best Practices

- **Pin images by digest, not mutable tag.** A tag like `:latest` or `:v1`
  can be re-pushed and silently change behavior. Digests are immutable.
- **Set `imagePullPolicy: IfNotPresent`** when pinning by digest or a specific
  tag, to avoid re-pulling on every Pod start and to dodge registry rate limits.
- **Store registry credentials in a Kubernetes Secret** referenced via
  `imagePullSecrets`, never baked into the image or node config.
- **Use an internal registry mirror / cache** (e.g. Harbor, ECR Pull Through
  Cache) to remove a hard dependency on an external registry and its rate
  limits.
- **Tag images immutably in CI** (e.g. `git-sha`) and promote by digest;
  never overwrite a published tag.
- **Monitor `ImagePullBackOff`** cluster-wide — a sudden burst across many
  namespaces usually means a registry outage or credential rotation, not a
  single bad deploy.

## Production Tips

- Docker Hub rate limits (~100 pulls/6h anonymously, 200 authenticated) bite
  large fleets. Mirror to ECR/Harbor and set `imagePullPolicy: IfNotPresent`.
- On EKS, prefer ECR for workloads in the same account: IAM-to-ECR auth is
  automatic via the kubelet's instance role — no `imagePullSecrets` needed.
- Keep a registry credential rotation runbook. Expired pull tokens manifest as
  `unauthorized` across *all* new Pods, which looks like a platform outage.
- Add a liveness/readiness probe only *after* the image is known-good; an
  `ImagePullBackOff` Pod with probes just generates extra noise.
- In multi-cluster setups, run a pull-through cache per region. Cross-region
  pulls add latency and cost and fail when the region's egress is impaired.
- Treat `ImagePullBackOff` during a rollout as a deploy blocker: pause and
  fix before it saturates the ReplicaSet, especially if a PDB is in play.
