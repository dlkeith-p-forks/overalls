#!/usr/bin/env bash
set -euo pipefail
role=${1:-}
case "$role" in ziggy|galileo|audi-private|porsche) ;; *) exit 2 ;; esac
runtime=/run/overalls-satellite
satellite=/run/overalls-satellite-secrets
[[ -s "$satellite/host-id" ]] || exit 1
host=$(<"$satellite/host-id")
case "$role" in
  ziggy|galileo)
    [[ -S "/run/$role/proxy.sock" ]] || exit 1
    response=$(curl --silent --show-error --fail --max-time 3 \
      --unix-socket "/run/$role/proxy.sock" 'http://localhost/health/ready')
    jq -e --arg role "$role" --arg host "$host" \
      '.version == 1 and .ready == true and .role == $role and .host_id == $host' <<< "$response" >/dev/null
    ;;
  audi-private)
    [[ -S /run/audi-private/status.sock && -S /run/lilly-ingress/audi.sock ]] || exit 1
    response=$(socat -T 5 - 'UNIX-CONNECT:/run/audi-private/status.sock' </dev/null)
    jq -e '.version == 1 and .role == "private" and .ready == true' <<< "$response" >/dev/null
    ;;
  porsche)
    [[ -S "$runtime/porsche-status.sock" ]] || exit 1
    response=$(socat -T 5 - "UNIX-CONNECT:$runtime/porsche-status.sock" </dev/null)
    jq -e '.version == 1 and .ready == true' <<< "$response" >/dev/null
    ;;
esac
