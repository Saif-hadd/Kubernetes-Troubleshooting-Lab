#!/usr/bin/env bash
# Show the resolv.conf ndots/search settings and observe the extra lookups.
# Usage: ./diagnose.sh [namespace]
set -euo pipefail
NS="${1:-ktslab}"

POD=$(kubectl -n "$NS" get pod -l app=resolver -o jsonpath='{.items[0].metadata.name}')
echo "pod: $POD"

echo "=== resolv.conf inside the Pod ==="
echo "    (note 'options ndots:5' and the three search domains)"
kubectl -n "$NS" exec "$POD" -- cat /etc/resolv.conf

echo "=== resolve an unqualified external name ==="
kubectl -n "$NS" exec "$POD" -- nslookup api.external.example.com 2>&1 | head -n 10 || true

echo "=== how many queries does one name cost? (dig +search) ==="
# busybox nslookup has no -debug; a netshoot Pod shows every attempt.
kubectl -n "$NS" run dnsdebug --rm -i --restart=Never \
  --image=nicolaka/netshoot -- \
  dig +search +noall +answer +comments api.external.example.com 2>&1 | head -n 30 || \
  echo "(netshoot image unavailable - rely on resolv.conf above)"

echo "=== CoreDNS request volume (from its logs) ==="
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=20 2>/dev/null | tail -n 20 || true
