#!/usr/bin/env bash
set -euo pipefail
umask 077

# @cc [owner:ghuntley,label:security;verification] satellite-closed-startup
# Ziggy and Galileo MUST load operator-issued host-bound control credentials;
# Porsche and private Audi MUST use their reviewed role-specific credentials.
# Upstream TLS MUST trust the independent origin CA in Erlang; control uses its
# separate Marshall CA. Private Audi MUST have Lilly's real local connector.
role=${1:-}
case "$role" in ziggy|galileo|audi-private|porsche) ;; *) exit 2 ;; esac
satellite=/run/overalls-satellite-secrets
runtime=/run/overalls-satellite
[[ -s "$satellite/issued-ready" && -s "$satellite/host-id" && -s "$satellite/control-ca.pem" ]] || {
  echo 'Satellite enrollment unavailable' >&2
  exit 1
}
private_file() {
  [[ -f "$1" && ! -L "$1" && "$(stat -c '%a:%u:%h' "$1")" == '600:0:1' ]]
}
private_file "$satellite/host-id" && private_file "$satellite/control-ca.pem" || exit 1
host=$(<"$satellite/host-id")
[[ "$host" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || exit 1
mkdir -p "$runtime"
chmod 0700 "$runtime"
export RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP=/dev/null ERL_FLAGS='+S 2:2'
export RELEASE_COOKIE
RELEASE_COOKIE=$(openssl rand -hex 32)

case "$role" in
  ziggy|galileo)
    private_file "$satellite/$role.token" && [[ -s /run/overalls-origin-ca/ca.pem ]] || exit 1
    cat /etc/ssl/certs/ca-certificates.crt /run/overalls-origin-ca/ca.pem > "$runtime/upstream-roots.pem"
    chmod 0600 "$runtime/upstream-roots.pem"
    export SSL_CERT_FILE="$runtime/upstream-roots.pem"
    export ERL_AFLAGS="-eval 'public_key:cacerts_load(\"$runtime/upstream-roots.pem\").'"
    ;;
esac

case "$role" in
  ziggy)
    private_file "$satellite/openai.key" && private_file "$satellite/anthropic.key" || exit 1
    mkdir -p /run/ziggy
    chmod 0700 /run/ziggy
    mkdir -p /var/lib/ziggy/spool
    chmod 0700 /var/lib/ziggy/spool
    jq -n --arg host "$host" --arg satellite "$satellite" \
      '{version:1,host_id:$host,control_plane:"https://marshall-a:5443",ca_file:($satellite+"/control-ca.pem"),credential_file:($satellite+"/ziggy.token"),openai_key_file:($satellite+"/openai.key"),anthropic_key_file:($satellite+"/anthropic.key"),socket:"/run/ziggy/proxy.sock",spool:"/var/lib/ziggy/spool",max_requests:1000,enabled_providers:["openai","anthropic"],agent_enabled:false}' > "$runtime/ziggy.json"
    chmod 0600 "$runtime/ziggy.json"
    export ZIGGY_CONFIG_FILE="$runtime/ziggy.json" RELEASE_TMP="$runtime"
    exec /opt/overalls/ziggy/bin/ziggy start
    ;;
  galileo)
    mkdir -p /run/galileo
    chmod 0700 /run/galileo
    jq -n --arg host "$host" --arg satellite "$satellite" \
      '{version:1,host_id:$host,control_plane:"https://marshall-a:5443",ca_file:($satellite+"/control-ca.pem"),credential_file:($satellite+"/galileo.token"),socket:"/run/galileo/proxy.sock"}' > "$runtime/galileo.json"
    chmod 0600 "$runtime/galileo.json"
    export GALILEO_CONFIG_FILE="$runtime/galileo.json" RELEASE_TMP="$runtime"
    exec /opt/overalls/galileo/bin/galileo start
    ;;
  audi-private)
    private_file "$satellite/private-leaf.pem" && private_file "$satellite/private-leaf.key" && private_file "$satellite/private-root.pem" || exit 1
    for ((attempt=0; attempt<120; attempt++)); do
      [[ -S /run/lilly-ingress/private.sock ]] && break
      sleep 1
    done
    [[ -S /run/lilly-ingress/private.sock ]] || { echo 'Lilly private connector unavailable' >&2; exit 1; }
    mkdir -p /run/audi-private
    chmod 0700 /run/audi-private
    ip address show dev lo | grep -q '169[.]254[.]254[.]1' || ip address add 169.254.254.1/32 dev lo
    jq -n --arg host "$host" --arg satellite "$satellite" \
      '{version:1,role:"private",host_id:$host,connector_path:"/run/lilly-ingress/private.sock",connector_uid:0,ziggy_socket:"/run/ziggy/proxy.sock",galileo_socket:"/run/galileo/proxy.sock",certificate_file:($satellite+"/private-leaf.pem"),key_file:($satellite+"/private-leaf.key"),roots_file:($satellite+"/private-root.pem"),status_socket:"/run/audi-private/status.sock"}' > "$runtime/audi.json"
    chmod 0600 "$runtime/audi.json"
    export AUDI_CONFIG_FILE="$runtime/audi.json" RELEASE_TMP="$runtime"
    exec /opt/overalls/audi/bin/audi start
    ;;
  porsche)
    private_file "$satellite/porsche.token" || exit 1
    mkdir -p /var/lib/porsche/host-keys
    chmod 0700 /var/lib/porsche/host-keys
    if [[ ! -e /var/lib/porsche/host-keys/ssh_host_ed25519_key ]]; then
      ssh-keygen -q -t ed25519 -N '' -f /var/lib/porsche/host-keys/ssh_host_ed25519_key >/dev/null
      chmod 0600 /var/lib/porsche/host-keys/ssh_host_ed25519_key
    fi
    # @cc [owner:ghuntley,label:security;verification] porsche-host-certificate
    # Porsche refuses to listen without a Marshall-signed host certificate. In
    # production Lyra's overalls-host-certificate obtains it; this harness stand-in
    # makes the same reviewed POST to Marshall's SSH API with the gateway token,
    # passing the token only through a private header file, never argv or logs.
    certificate=/var/lib/porsche/host-keys/ssh_host_ed25519_key-cert.pub
    if [[ ! -s "$certificate" ]]; then
      printf 'Authorization: Bearer %s\n' "$(<"$satellite/porsche.token")" > "$runtime/porsche-auth.header"
      chmod 0600 "$runtime/porsche-auth.header"
      jq -cn --arg key "$(</var/lib/porsche/host-keys/ssh_host_ed25519_key.pub)" \
        '{version:1,public_key:$key}' > "$runtime/porsche-certificate-request.json"
      for ((attempt=0; attempt<60; attempt++)); do
        if curl -sSf --max-time 10 --cacert "$satellite/control-ca.pem" \
            -H @"$runtime/porsche-auth.header" -H 'content-type: application/json' \
            --data @"$runtime/porsche-certificate-request.json" \
            -o "$runtime/porsche-certificate.json" \
            https://marshall-a:5443/api/ssh/v1/host-certificate 2>/dev/null &&
          jq -er 'select(.version == 1) | .certificate' "$runtime/porsche-certificate.json" > "$certificate.new"; then
          break
        fi
        rm -f "$certificate.new"
        sleep 2
      done
      rm -f "$runtime/porsche-auth.header" "$runtime/porsche-certificate.json"
      [[ -s "$certificate.new" ]] || { echo 'Porsche host certificate unavailable' >&2; exit 1; }
      chmod 0644 "$certificate.new"
      mv -T "$certificate.new" "$certificate"
    fi
    jq -n --arg satellite "$satellite" \
      '{version:1,control_plane:"https://marshall-a:5443",public_origin:"https://marshall-a",credential_file:($satellite+"/porsche.token"),host_key_dir:"/var/lib/porsche/host-keys",bind:"0.0.0.0",port:2223,cacertfile:($satellite+"/control-ca.pem"),status_socket:"/run/overalls-satellite/porsche-status.sock"}' > "$runtime/porsche.json"
    chmod 0600 "$runtime/porsche.json"
    export PORSCHE_CONFIG_FILE="$runtime/porsche.json" RELEASE_TMP="$runtime"
    exec /opt/overalls/porsche/bin/porsche start
    ;;
esac
