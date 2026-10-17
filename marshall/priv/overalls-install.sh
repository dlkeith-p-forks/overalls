#!/usr/bin/env bash
set -euo pipefail
umask 077

# Inputs: HTTPS origin, application DNS zone, guest DNS name. All are validated
# before filesystem changes. The two constants are substituted by Marshall.
management_host='@OVERALLS_MANAGEMENT_HOST@'
deployment_zone='@OVERALLS_GUEST_ZONE@'
origin="${1:?origin required}"
zone="${2:?zone required}"
host="${3:?host required}"

fail() { printf 'overalls: %s\n' "$1" >&2; exit 1; }

valid_dns_name() {
  local label maximum="${2:-189}"
  local -a labels
  [ "${#1}" -le "$maximum" ] && [[ "$1" != *[!a-z0-9.-]* ]] || return 1
  [[ "$1" != .* && "$1" != *. && "$1" != *..* ]] || return 1
  IFS=. read -r -a labels <<< "$1"
  [ "${#labels[@]}" -gt 0 ] || return 1
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] &&
      [ "${#label}" -le 63 ] || return 1
  done
}

# @cc [owner:ghuntley,label:security] installer-origin-binding
# Before local filesystem changes, the supplied origin MUST be a valid HTTPS
# authority whose hostname equals the deployment hostname embedded by Marshall.
case "$origin" in https://*) ;; *) fail 'Invalid HTTPS origin' ;; esac
authority="${origin#https://}"
origin_host="${authority%%:*}"
valid_dns_name "$origin_host" || fail 'Invalid HTTPS origin'
if [[ "$authority" == *:* ]]; then
  port="${authority#*:}"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$port))" -ge 1 ] &&
    [ "$((10#$port))" -le 65535 ] || fail 'Invalid HTTPS port'
fi
[ "$origin_host" = "$management_host" ] || fail 'Installer origin does not match deployment'
valid_dns_name "$zone" || fail 'Invalid guest zone'
[ "$zone" = "$deployment_zone" ] || fail 'Installer zone does not match deployment'
valid_dns_name "$host" 253 || fail 'Invalid guest hostname'
[[ "$host" == *."$zone" ]] || fail 'Guest hostname does not match zone'
case "${HOME:?HOME required}" in /*) ;; *) fail 'HOME must be absolute' ;; esac
for tool in ssh curl mktemp; do
  command -v "$tool" >/dev/null || fail "Required tool unavailable: $tool"
done
case "$(uname -s):$(uname -m)" in
  Linux:x86_64) target=linux-amd64 ;;
  Linux:aarch64) target=linux-arm64 ;;
  Darwin:x86_64) target=darwin-amd64 ;;
  Darwin:arm64) target=darwin-arm64 ;;
  *) fail 'Unsupported platform' ;;
esac

temp=''
cleanup() { [ -z "$temp" ] || rm -f "$temp"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$HOME/.local/bin"
chmod 700 "$HOME/.local/bin"
temp="$(mktemp "$HOME/.local/bin/.overalls.XXXXXXXX")"
curl --disable --fail --silent --show-error --location --proto '=https' --max-time 180 --max-filesize 104857600 \
  "$origin/bin/$target" -o "$temp"
[ "$(wc -c < "$temp")" -le 104857600 ] || exit 1
expected="$(curl --disable --fail --silent --show-error --location --proto '=https' --max-time 10 \
  "$origin/bin/sha256/$target")"
case "$expected" in *[!0-9a-f]*|'') exit 2 ;; esac
if command -v sha256sum >/dev/null; then
  actual="$(sha256sum "$temp")"; actual="${actual%% *}"
else
  actual="$(shasum -a 256 "$temp")"; actual="${actual%% *}"
fi
[ "$actual" = "$expected" ] || { printf 'Binary checksum mismatch\n' >&2; exit 1; }
chmod 700 "$temp"

# @cc [owner:ghuntley,label:security] installer-refusal-retains-client
# Trust or account-proof refusal MUST leave the previously installed executable
# unchanged. Configuration MUST use the stable managed path before replacement.
"$temp" config-ssh --origin "$origin" --zone "$zone" --staged-installer
mv -f "$temp" "$HOME/.local/bin/overalls"
exec ssh "$host" </dev/tty
