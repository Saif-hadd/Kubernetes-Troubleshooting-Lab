#!/usr/bin/env bash
# Show the volume attach state for the db Pod and the node's CSI/attach errors.
# Usage: ./diagnose.sh [namespace]
set -euo pipefail
NS="${1:-ktslab}"

echo "=== PVC ==="
kubectl -n "$NS" get pvc -o wide

echo "=== Pod volumes / events ==="
kubectl -n "$NS" describe pod "db-0" | sed -n '/Volumes:/,/QoS Class:/p'
kubectl -n "$NS" describe pod "db-0" | sed -n '/Events:/,$p'

echo "=== VolumeAttachment objects ==="
kubectl get volumeattachment 2>/dev/null || echo "(no VolumeAttachment objects — in-tree driver or none)"

echo "=== CSI controller logs (if present) ==="
kubectl get pods -A | grep -iE 'csi' || echo "(no CSI pods found)"
