#!/usr/bin/env bash
set -euo pipefail
umask 077

secrets=/run/overalls-secrets
state=/var/lib/lilly
runtime=/run/lilly-release
mkdir -p "$state/control" "$state/vm" "$state/network" "$state/pool" "$runtime"
if [[ ! -s "$state/host-machine-id" ]]; then
  if [[ -e "$state/host-machine-id" ]]; then echo 'invalid retained machine identity' >&2; exit 1; fi
  openssl rand -hex 16 > "$state/.host-machine-id.new"
  chmod 0600 "$state/.host-machine-id.new"
  mv "$state/.host-machine-id.new" "$state/host-machine-id"
fi
machine_hex=$(<"$state/host-machine-id")
[[ "$machine_hex" =~ ^[0-9a-f]{32}$ && "$machine_hex" != 00000000000000000000000000000000 ]] || { echo 'invalid machine identity' >&2; exit 1; }
printf '%s\n' "$machine_hex" > /etc/machine-id
chown root:root /etc/machine-id
chmod 0644 /etc/machine-id
machine_id="sha256:$(printf '%s' "$machine_hex" | xxd -r -p | openssl dgst -sha256 -mac HMAC -macopt key:kittens.lilly.host.v1 -binary | od -An -tx1 -v | tr -d ' \n')"
unset machine_hex
[[ "$machine_id" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'invalid derived machine identity' >&2; exit 1; }

request="$secrets/lilly-a-enrollment.json"
if [[ ! -f "$request" ]]; then
  jq -n --arg machine "$machine_id" '{version:3,name:"lilly-a",architecture:"x86_64",machine_id:$machine,overhead_cores:0,overhead_memory_bytes:0,credential_ttl_seconds:86400,pools:[{name:"antithesis",storage:{backend:"zfs",zpool_guid:"10001",dataset_guid:"10002",dataset:"overalls/antithesis"},overhead_bytes:0}]}' > "$secrets/.lilly-a-enrollment.json.new"
  chmod 0600 "$secrets/.lilly-a-enrollment.json.new"
  mv "$secrets/.lilly-a-enrollment.json.new" "$request"
else
  jq -e --arg machine "$machine_id" '.version == 3 and .name == "lilly-a" and .machine_id == $machine' "$request" >/dev/null || { echo 'retained enrollment identity mismatch' >&2; exit 1; }
fi
for ((attempt=0; attempt<180; attempt++)); do
  [[ -s "$secrets/lilly-a-credential.json" && -s "$secrets/lilly-a-pool-id" ]] && break
  sleep 1
done
[[ -s "$secrets/lilly-a-credential.json" ]] || { echo 'issued Lilly credential unavailable' >&2; exit 1; }
[[ -s "$secrets/lilly-a-pool-id" ]] || { echo 'enrolled Lilly pool identity unavailable' >&2; exit 1; }
host_id=$(jq -er '.host_id | select(type == "string" and test("^[0-9a-f-]{36}$"))' "$secrets/lilly-a-credential.json")
pool_id=$(<"$secrets/lilly-a-pool-id")
[[ "$pool_id" =~ ^[0-9a-f-]{36}$ ]] || { echo 'invalid enrolled Lilly pool identity' >&2; exit 1; }
metadata=/opt/kittens/lilly/overalls-release.json
[[ -s "$metadata" ]] || { echo 'Lilly release metadata unavailable' >&2; exit 1; }
firecracker=$(jq -er '.firecracker | select(type == "string" and startswith("/nix/store/"))' "$metadata")
jailer=$(jq -er '.jailer | select(type == "string" and startswith("/nix/store/"))' "$metadata")
unshare=$(jq -er '.unshare | select(type == "string" and startswith("/nix/store/"))' "$metadata")
for executable in "$firecracker" "$jailer" "$unshare"; do
  [[ -x "$executable" ]] || { echo 'Lilly canonical executable unavailable' >&2; exit 1; }
done
case "${OVERALLS_ANTITHESIS_PRIVATE_SERVICES:-0}" in
  0) private_services=false ;;
  1)
    private_services=true
    mkdir -p /run/lilly-ingress
    chmod 0700 /run/lilly-ingress
    ;;
  *) echo 'invalid private service selection' >&2; exit 1 ;;
esac

jq -n --arg host "$host_id" --arg pool "$pool_id" --arg credential "$secrets/lilly-a-credential.json" \
  --arg ca "$secrets/ca.crt" --arg firecracker "$firecracker" --arg jailer "$jailer" --arg unshare "$unshare" \
  --argjson private "$private_services" \
  '{version:4,control_plane:"https://marshall-a:5443",host_id:$host,credential_file:$credential,cacertfile:$ca,state_dir:"/var/lib/lilly/control",cgroup_path:"/sys/fs/cgroup/lilly.slice",images:[],pools:[{id:$pool,path:"/var/lib/lilly/pool",filesystem_id:"zfs:10001:10002",storage:{backend:"zfs",zpool_guid:"10001",dataset_guid:"10002",dataset:"overalls/antithesis"}}],execution:{state_dir:"/var/lib/lilly/vm",network_state_dir:"/var/lib/lilly/network",egress_interface:"eth0",protected_cidrs:[],firecracker:$firecracker,jailer:$jailer,unshare:$unshare,audi_ingress:false,private_services:$private,guest_trust_roots:[],brady:null,firecracker_logging:false,provisioning_readiness:false,inception_smtp_file:null,inception_image_id:null,inception_proof_file:null,inception_probe_id:null}} | if $private then .ingress={path:"/run/lilly-ingress/audi.sock",audi_uid:0} else . end' > "$runtime/config.json.new"
chmod 0600 "$runtime/config.json.new"
mv "$runtime/config.json.new" "$runtime/config.json"
export LILLY_CONFIG_FILE="$runtime/config.json" LILLY_STATUS_SOCKET="$runtime/status.sock"
export RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP=/dev/null
export RELEASE_COOKIE="$(openssl rand -hex 32)"
exec /opt/kittens/lilly/bin/lilly start
