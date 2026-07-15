# 11 - RBAC

## Overview

Kubernetes RBAC (Role-Based Access Control) decides whether a user or
ServiceAccount can perform a verb on a resource. When a workload or a CI
pipeline gets `403 Forbidden` / `is forbidden: User … cannot …`, the request
is being denied by RBAC. From an SRE perspective RBAC failures are
**permission boundary** problems: the API server, the Pod, and the network are
all fine — the identity simply lacks the grant.

RBAC failures are noisy in CI/CD (a deploy step that cannot list Pods) and
silent-dangerous in production (overbroad cluster-admin bindings). This
scenario reproduces the most common shape: a ServiceAccount used by a CI
pipeline that needs to list/get Pods in a namespace but has no RoleBinding, so
every `kubectl get pods` returns `Forbidden`.

## Symptoms

A pipeline or Pod using a ServiceAccount token runs:

```bash
kubectl get pods -n ktslab --as=system:serviceaccount:ktslab:ci-deployer
```

```
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:ktslab:ci-deployer" cannot list resource "pods" in API group "" in the namespace "ktslab"
```

In a Pod's logs this surfaces as an HTTP `403` from the API or an SDK error
like `Unauthorized` / `Forbidden`.

## Root Cause

The ServiceAccount `ci-deployer` exists in the `ktslab` namespace, but no
`Role` grants `list/get` on Pods to that namespace, and no `RoleBinding`
binds such a Role to the ServiceAccount. With RBAC enabled (the default), the
API server denies the request with `403`.

Common RBAC root causes (same triage path):

- Missing Role or RoleBinding for the ServiceAccount.
- RoleBinding bound to the wrong subject (wrong namespace or name).
- A ClusterRole referenced in a RoleBinding that does not exist.
- Overbroad `cluster-admin` grants used to "make it work," masking a missing
  narrow grant.
- A ServiceAccount used by a Pod that was deleted and recreated (tokens rotate).

## Diagnosis

### 1. Reproduce the exact denial

```bash
kubectl auth can-i list pods --as=system:serviceaccount:ktslab:ci-deployer -n ktslab
```

```
no
```

```bash
kubectl auth can-i --list --as=system:serviceaccount:ktslab:ci-deployer -n ktslab
```

This lists everything the identity *can* do — if `list pods` is absent, the
grant is missing.

### 2. Inspect the Roles and RoleBindings in the namespace

```bash
kubectl get roles,rolebindings -n ktslab -o wide
kubectl describe rolebinding -n ktslab
kubectl describe role -n ktslab
```

Check the RoleBinding's `subjects` — the `kind: ServiceAccount`, `name`, and
`namespace` must match the identity exactly.

### 3. Inspect ClusterRoleBindings that may apply

```bash
kubectl get clusterrolebindings -o wide | grep ci-deployer
kubectl describe clusterrolebinding <name>
```

A broad binding (e.g. `system:serviceaccounts` → `cluster-admin`) can mask a
missing narrow grant — a security smell.

### 4. Verify the ServiceAccount exists and has a token

```bash
kubectl get sa -n ktslab ci-deployer -o yaml
kubectl get secret -n ktslab | grep ci-deployer
```

### 5. Read the API server audit / impersonate the exact request

```bash
kubectl get pods -n ktslab --as=system:serviceaccount:ktslab:ci-deployer -v=6
```

The `-v=6` output shows the `403` response and the exact user/groups the API
server saw — confirm the identity string matches.

### 6. Check the Pod's mounted token (if the caller is a Pod)

```bash
kubectl exec -n ktslab <pod> -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
kubectl exec -n ktslab <pod> -- cat /var/run/secrets/kubernetes.io/serviceaccount/namespace
```

## Resolution

### Fix A — Grant the needed permission with a Role + RoleBinding

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: ktslab
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-deployer-pod-reader
  namespace: ktslab
subjects:
  - kind: ServiceAccount
    name: ci-deployer
    namespace: ktslab
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

### Fix B — Fix the RoleBinding subject

If the binding exists but points at the wrong subject, correct `name`/`namespace`.

### Fix C — Use a ClusterRole (reusable) bound by a RoleBinding (namespace-scoped)

Define a `ClusterRole` once, bind it per-namespace with `RoleBinding` — this
is the idiomatic pattern for reusable permission templates.

### Fix D — Avoid the `cluster-admin` shortcut

Never grant `cluster-admin` to "make it work." Narrow the grant to the least
verbs/resources the workload needs.

### Verify

```bash
kubectl auth can-i list pods --as=system:serviceaccount:ktslab:ci-deployer -n ktslab
kubectl get pods -n ktslab --as=system:serviceaccount:ktslab:ci-deployer
```

## Best Practices

- **Follow least privilege.** Grant only the verbs and resources a workload
  needs; prefer `Role`/`RoleBinding` over `ClusterRoleBinding`.
- **Use named ServiceAccounts per workload**, not the `default` SA — it makes
  grants explicit and auditable.
- **Bind reusable ClusterRoles with namespace-scoped RoleBindings** so a
  single ClusterRole serves many namespaces without cluster-wide access.
- **Audit RBAC periodically** with `kubectl auth can-i --list` for critical
  identities and with tools like `rbac-lookup` / `rakkess`.
- **Prefer token projection over legacy long-lived secrets** for Pod auth;
  projected tokens rotate and bind to the Pod lifecycle.
- **Review ClusterRoleBindings in PR review** — a single new
  ClusterRoleBinding to `system:authenticated` can elevate every user.

## Production Tips

- A `403` in a Pod's logs that says `cannot list resource "secrets"` usually
  means a controller/operator is missing a grant — fix the Role, do not mount
  the secret into the Pod to work around it.
- `kubectl auth can-i --as=…` is the fastest RBAC triage tool. Use it in CI
  smoke tests to assert a deployer can do its job before a real deploy runs.
- Overbroad bindings (`system:serviceaccounts` → `cluster-admin`) are a
  serious security finding. Scan for them with:
  `kubectl get clusterrolebindings -o json | jq '.items[] | select(.roleRef.name=="cluster-admin")'`
- On EKS, IRSA maps an IAM role to a ServiceAccount. A Pod getting `403` may
  actually be an IAM trust-policy mismatch, not a Kubernetes RBAC issue —
  check the annotation `eks.amazonaws.com/role-arn` and the IAM trust policy.
- For break-glass access, use time-bound impersonation
  (`--as=<user> --as-group=<group>`) with audit logging rather than permanent
  cluster-admin grants.
- When a ServiceAccount is deleted and recreated (e.g. namespace recreated),
  all RoleBindings referencing the old one become dangling — re-bind them.
