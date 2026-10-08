#!/usr/bin/env bash
# Create the webapp-tls Secret from either an expired or a valid certificate.
#
#   ./make-tls-secret.sh expired   # reproduce the failure
#   ./make-tls-secret.sh valid     # apply the fix
#
# Usage: ./make-tls-secret.sh [expired|valid] [namespace]
set -euo pipefail

MODE="${1:-expired}"
NS="${2:-ktslab}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/certs"
mkdir -p "$DIR"

case "$MODE" in
  expired)
    # A certificate that expired in the past (notAfter < now).
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$DIR/tls.key" -out "$DIR/tls.crt" \
      -subj "/CN=webapp.ktslab.local" \
      -not_before 20200101000000Z -not_after 20200102000000Z >/dev/null 2>&1
    ;;
  valid)
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$DIR/tls.key" -out "$DIR/tls.crt" \
      -subj "/CN=webapp.ktslab.local" -days 365 >/dev/null 2>&1
    ;;
  *)
    echo "usage: $0 [expired|valid] [namespace]" >&2
    exit 2
    ;;
esac

echo "certificate ($MODE):"
openssl x509 -in "$DIR/tls.crt" -noout -subject -dates

kubectl create secret tls webapp-tls -n "$NS" \
  --cert="$DIR/tls.crt" --key="$DIR/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret webapp-tls ($MODE) applied in namespace $NS."
