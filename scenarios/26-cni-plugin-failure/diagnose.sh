#!/usr/bin/env bash
# Inspect the CNI plugin state: agent Pods, CNI config, routes and Pod reachability.
# Usage: ./diagnose.sh [minikube-profile]
set -euo pipefail
PROFILE="${1:-minikube}"

echo "=== CNI agent Pods ==="
kubectl -n kube-system get pods | grep -iE 'calico|cilium|flannel|weave|antrea|kindnet' || echo "(no known CNI pods)"

echo "=== CNI config on the node ==="
minikube ssh -p "$PROFILE" -- sudo ls /etc/cni/net.d/ 2>/dev/null || true

echo "=== Pod routes (sample the cilium/calico interface) ==="
minikube ssh -p "$PROFILE" -- sudo sh -c 'ip route 2>/dev/null | head -n 20' || true

echo "=== Pod-to-Pod reachability ==="
CLIENT=$(kubectl -n ktslab get pod -l app=client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
SERVER_IP=$(kubectl -n ktslab get pod -l app=server -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
if [ -n "$CLIENT" ] && [ -n "$SERVER_IP" ]; then
  echo "client=$CLIENT  serverIP=$SERVER_IP"
  kubectl -n ktslab exec "$CLIENT" -- ping -c2 -W2 "$SERVER_IP" 2>&1 | tail -n 5 || true
  kubectl -n ktslab exec "$CLIENT" -- wget -q -T2 -O /dev/null "http://$SERVER_IP:8080/" 2>&1 || true
else
  echo "(client or server Pod not found)"
fi
