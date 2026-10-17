#!/usr/bin/env bash
set -euo pipefail
status=$(timeout 3 socat - UNIX-CONNECT:/run/lilly-release/status.sock </dev/null)
# Hosted controlled capacity intentionally has ready=false because physical
# execution is unavailable. Control-core health only claims an authenticated
# v4 Control connection and its terminal stream authority; the workload checks
# a fresh committed host report independently before setup completion.
jq -e '.version == 1 and .phase == "connected" and .protocol_version == 4 and .terminal_ready == true' <<<"$status" >/dev/null
