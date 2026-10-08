#!/usr/bin/env bash
# Inspect kubelet PLEG health and node conditions.
# Usage: ./diagnose.sh [minikube-profile]
set -euo pipefail
PROFILE="${1:-minikube}"

echo "=== node conditions ==="
kubectl get nodes
kubectl describe node "$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')" \
  | sed -n '/Conditions:/,/Addresses:/p'

echo "=== kubelet: PLEG / runtime errors ==="
minikube ssh -p "$PROFILE" -- sudo journalctl -u kubelet --no-pager -n 400 2>/dev/null \
  | grep -iE 'pleg|not healthy|runtime|deadline|sync loop' | tail -n 30 || true

echo "=== container runtime health ==="
minikube ssh -p "$PROFILE" -- sudo systemctl is-active containerd 2>/dev/null || true
minikube ssh -p "$PROFILE" -- sudo crictl info 2>/dev/null | head -n 20 || true

echo "=== node resource pressure (a common PLEG trigger) ==="
minikube ssh -p "$PROFILE" -- sudo sh -c 'uptime; free -m | head -2' 2>/dev/null || true
