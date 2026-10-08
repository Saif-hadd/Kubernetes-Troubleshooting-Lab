#!/usr/bin/env bash
# Diagnose why a resource-metric HPA reports <unknown>: is metrics-server
# installed and, more importantly, can it actually scrape the kubelet?
# Usage: ./diagnose.sh [namespace]
set -euo pipefail
NS="${1:-ktslab}"

echo "=== HPA state ==="
kubectl -n "$NS" get hpa
kubectl -n "$NS" describe hpa api | sed -n '/Conditions:/,$p' | head -n 20

echo "=== metrics APIService ==="
kubectl get apiservice v1beta1.metrics.k8s.io -o wide 2>/dev/null || echo "(metrics APIService missing)"

echo "=== metrics-server pods ==="
kubectl -n kube-system get pods -l k8s-app=metrics-server -o wide 2>/dev/null || \
  kubectl -n kube-system get pods | grep -i metrics-server || echo "(no metrics-server pods)"

echo "=== can the metrics API answer? ==="
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes 2>&1 | head -c 300; echo
kubectl top nodes 2>&1 | head -n 10 || true

echo "=== metrics-server logs (scrape errors) ==="
kubectl -n kube-system logs -l k8s-app=metrics-server --tail=60 2>/dev/null \
  | grep -iE 'x509|tls|unable to|forbidden|refused|not available|timeout' | tail -n 30 || \
  kubectl -n kube-system logs -l k8s-app=metrics-server --tail=30 2>/dev/null || true
