#!/usr/bin/env bash
set -euo pipefail
curl --silent --show-error --fail --unix-socket /run/enrico/status.sock \
  http://enrico/health/ready 2>/dev/null |
  jq -e '.version == 1 and .ready == true and .role == "enrico"' >/dev/null
