#!/usr/bin/env bash
# Inspect leader-election churn for the controller-manager and scheduler.
# Usage: ./diagnose.sh
set -euo pipefail

echo "=== control-plane Pods ==="
kubectl -n kube-system get pods -l tier=control-plane -o wide
kubectl -n kube-system get pods -l component=kube-controller-manager
kubectl -n kube-system get pods -l component=kube-scheduler

echo "=== leader-election leases ==="
kubectl -n kube-system get lease kube-controller-manager kube-scheduler -o wide 2>/dev/null || \
  kubectl -n kube-system get lease | grep -E 'controller-manager|scheduler'

echo "=== leader-transition counters (from the components' /metrics) ==="
echo "--- controller-manager ---"
kubectl -n kube-system logs -l component=kube-controller-manager --tail=50 2>/dev/null \
  | grep -iE 'leader|election|acquired|lost' | tail -n 20 || true
echo "--- scheduler ---"
kubectl -n kube-system logs -l component=kube-scheduler --tail=50 2>/dev/null \
  | grep -iE 'leader|election|acquired|lost' | tail -n 20 || true

echo "=== events ==="
kubectl -n kube-system get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 20
