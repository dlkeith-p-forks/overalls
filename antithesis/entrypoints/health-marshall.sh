#!/usr/bin/env bash
set -euo pipefail
case "${MARSHALL_INSTANCE_ID:-}" in marshall-a|marshall-b) ;; *) exit 1 ;; esac
exec curl --silent --show-error --fail --output /dev/null \
  --max-time 3 --cacert /run/overalls-secrets/ca.crt \
  --resolve "${MARSHALL_INSTANCE_ID}:443:127.0.0.1" \
  "https://${MARSHALL_INSTANCE_ID}/health/ready"
