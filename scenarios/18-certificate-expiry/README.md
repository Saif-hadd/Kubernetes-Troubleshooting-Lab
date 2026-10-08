# 18 - Certificate / TLS expiry

## Overview

An expired certificate is one of the few failures that produces a **hard TLS
handshake error** rather than a slow or partial degradation: clients refuse to
connect outright (`x509: certificate has expired`). It is also one of the most
predictable outages in existence — the expiry date is known in advance — and
yet it still takes down production because nothing alerts on it.

Two classes of certificate expire in a Kubernetes cluster:

1. **Workload / ingress TLS** — the certificate a Service or Ingress presents
   to clients (often managed by cert-manager).
2. **Control-plane certificates** — the API server serving cert, the kubelet
   serving cert, etcd peer/client certs, and the client-CA bundle (self-managed
   clusters; on managed clouds the provider rotates them).

From an SRE perspective this is a **time-bomb** failure: everything is healthy
until a specific instant, then every new TLS connection fails.

This scenario reproduces the application case: an Ingress that terminates TLS
with an **expired** certificate, so every HTTPS request fails the handshake.

## Symptoms

```bash
kubectl get ingress -n ktslab
```

```
NAME     CLASS   HOSTS                 ADDRESS        PORTS     AGE
webapp   nginx   webapp.ktslab.local   192.168.49.2   80, 443   2m
```

The Ingress looks healthy, but the client fails:

```bash
curl -v https://$(minikube ip) -H 'Host: webapp.ktslab.local'
```

```
* SSL certificate problem: certificate has expired
curl: (60) SSL certificate problem: certificate has expired
```

For control-plane certs, `kubectl` itself fails:

```
Unable to connect to the server: x509: certificate has expired or is not yet valid
```

## Root Cause

The Ingress references a Secret (`webapp-tls`) whose `tls.crt` is expired.
Kubernetes does not validate certificate dates when the Secret is created or
when the Ingress uses it, so the misconfiguration is invisible on the server
side — it only manifests at the TLS handshake, on the client. `curl -k` hides
it; a browser or a strict client does not.

The same shape applies to:

- A cert-manager `Certificate` whose renewal is broken (bad solver, rate limit,
  DNS challenge failing), so the Secret keeps an expired cert.
- A manually-managed cert that was never renewed.
- A self-signed cert generated once "temporarily" and forgotten.
- Control-plane certs on a self-managed cluster (`kubeadm`) past their 1-year
  expiry.

## Diagnosis

### 1. Read the certificate the endpoint actually serves

```bash
echo | openssl s_client -connect $(minikube ip):443 -servername webapp.ktslab.local 2>/dev/null \
  | openssl x509 -noout -subject -dates -issuer
```

`notAfter` in the past is the root cause.

### 2. Inspect the Secret in the cluster

```bash
kubectl get secret webapp-tls -n ktslab -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -dates
```

This is the certificate the Ingress is serving — compare its `notAfter` to now.

### 3. Find who owns the certificate

```bash
kubectl get certificate,issuer,clusterissuer -A        # cert-manager
kubectl describe certificate <name> -n ktslab
kubectl get events -A --field-selector reason=Issuing
```

If an `Order`/`Challenge` is failing, cert-manager cannot renew and the Secret
will go (or stay) expired.

### 4. Check control-plane certificate expiry (self-managed only)

```bash
kubeadm certs check-expiration
kubectl -n kube-system get pods   # if the API server is unreachable, use the host
```

## Resolution

### Fix A — Serve a valid (renewed) certificate

```bash
# Reproduce first:
./scenarios/18-certificate-expiry/make-tls-secret.sh expired

# Then fix it with a valid certificate:
./scenarios/18-certificate-expiry/make-tls-secret.sh valid
```

The nginx Ingress controller picks up the renewed Secret within seconds; no
Pod restart is needed. See [`make-tls-secret.sh`](make-tls-secret.sh).

### Fix A+ — Let cert-manager own the certificate

For anything long-lived, stop managing certs by hand:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: webapp-tls
  namespace: ktslab
spec:
  secretName: webapp-tls
  dnsNames:
    - webapp.ktslab.local
  issuerRef:
    name: letsencrypt
    kind: ClusterIssuer
```

cert-manager renews before expiry and rewrites the Secret.

### Fix B — Renew control-plane certificates (self-managed)

```bash
kubeadm certs renew all
# then restart the control-plane components (or the static Pods):
systemctl restart kubelet
```

### Verify

```bash
echo | openssl s_client -connect $(minikube ip):443 -servername webapp.ktslab.local 2>/dev/null \
  | openssl x509 -noout -enddate
curl -sS https://$(minikube ip) -H 'Host: webapp.ktslab.local'   # no -k
```

## Best Practices

- **Never manage long-lived certs by hand.** Use cert-manager (or the
  provider's certificate manager) so renewal is automatic.
- **Alert 30 days before expiry**, not on the day. A metric/alarm on
  `certmanager_certificate_expiration_timestamp_seconds` (or an
  `openssl s_client` probe per endpoint) is cheap insurance.
- **Pin `renewBefore`** on cert-manager `Certificate`s so renewal happens well
  ahead of `notAfter`.
- **Use short-lived, auto-rotated certs** for internal traffic (the mesh, the
  kubelet) rather than long-lived self-signed ones.
- **Monitor the control plane's own certs** on self-managed clusters
  (`kubeadm certs check-expiration` on a schedule); a full control-plane TLS
  outage has the widest blast radius.

## Production Tips

- A TLS failure that starts at a precise timestamp across the whole fleet is an
  expiry, not a network problem — check `notAfter` before anything else.
- `curl -k` (insecure) masks the problem in a runbook; always verify with a
  strict client, and add an external synthetic probe that does the same.
- During a cert-manager incident, the ACORD (Order/Challenge) objects are the
  source of truth for *why* renewal failed — a stale `notAfter` is the symptom,
  a failing `Challenge` is the cause.
- On managed clouds (EKS/GKE/AKS) the control-plane certs are rotated for you;
  the risk shifts entirely to your *workload* certs and to the kubelet's
  serving cert, which is also managed.
- Restart nothing when a workload cert is renewed: the ingress controller (or
  the app) reloads the Secret. Forcing Pod restarts on every renewal is churn
  with no benefit — unless the app reads the cert only at boot, which is itself
  a bug worth fixing.
