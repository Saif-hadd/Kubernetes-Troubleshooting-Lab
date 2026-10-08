#!/usr/bin/env bash
# Inspect the node's conntrack table from the minikube node.
# Usage: ./diagnose.sh [minikube-profile]
set -euo pipefail
PROFILE="${1:-minikube}"

echo "=== conntrack count / max ==="
minikube ssh -p "$PROFILE" -- sudo sh -c \
  'cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null; cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null'

echo "=== table-full / drop messages in the kernel ring buffer ==="
minikube ssh -p "$PROFILE" -- sudo dmesg 2>/dev/null | grep -i "nf_conntrack\|table full" | tail -n 20 || true

echo "=== conntrack summary (if the tool is present) ==="
minikube ssh -p "$PROFILE" -- sudo sh -c 'command -v conntrack >/dev/null && conntrack -S || echo "(conntrack tool not installed)"'
