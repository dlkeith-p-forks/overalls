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

# @cc [owner:ghuntley,label:capacity;verification] lilly-entrypoint-stub-storage
# Only OVERALLS_ANTITHESIS_STORAGE_STUB=1 creates the harness stub substrate:
# a fixed private substrate file naming configured (not measured) totals for
# the enrolled pool identity, and a tiny non-bootable image whose manifest is
# published for the operator to register. Nothing here creates or observes ZFS.
case "${OVERALLS_ANTITHESIS_STORAGE_STUB:-0}" in
  0) storage_stub=0 ;;
  1) storage_stub=1 ;;
  *) echo 'invalid storage stub selection' >&2; exit 1 ;;
esac
stub_image="$state/stub-image"
stub_artifact() {
  local file="$state/.stub-image.new/$1" digest
  digest=$(sha256sum "$file")
  jq -n --argjson bytes "$(stat -c '%s' "$file")" --arg sha "${digest%% *}" '{bytes:$bytes,sha256:$sha}'
}
if [[ "$storage_stub" == 1 ]]; then
  if [[ ! -d "$stub_image" ]]; then
    rm -rf "$state/.stub-image.new"
    mkdir -m 0755 "$state/.stub-image.new"
    printf 'overalls antithesis admission-stub kernel placeholder; not bootable\n' > "$state/.stub-image.new/kernel"
    printf 'overalls antithesis admission-stub initrd placeholder; not bootable\n' > "$state/.stub-image.new/initrd"
    head -c 4096 /dev/zero > "$state/.stub-image.new/rootfs.ext4"
    jq -n --argjson kernel "$(stub_artifact kernel)" --argjson initrd "$(stub_artifact initrd)" \
      --argjson rootfs "$(stub_artifact rootfs.ext4)" \
      '{version:4,architecture:"x86_64",boot_args:"console=ttyS0 overalls.antithesis.storage_stub=1",minimum_memory_bytes:536870912,minimum_disk_bytes:1073741824,kernel:$kernel,initrd:$initrd,rootfs:$rootfs,workspace_source_version:null}' \
      > "$state/.stub-image.new/manifest.json"
    chmod 0444 "$state/.stub-image.new"/*
    mv -T "$state/.stub-image.new" "$stub_image"
  fi
  cp "$stub_image/manifest.json" "$secrets/.lilly-a-stub-image.json.new"
  chmod 0600 "$secrets/.lilly-a-stub-image.json.new"
  mv -f "$secrets/.lilly-a-stub-image.json.new" "$secrets/lilly-a-stub-image.json"
  jq -n --arg image "$stub_image" \
    '{version:1,scope:"antithesis-harness-stub-not-zfs",zpool_guid:"10001",dataset_guid:"10002",dataset:"overalls/antithesis",total_bytes:68719476736,free_bytes:51539607552,stub_cpu_millicores:1000,image_path:$image}' \
    > "$runtime/.storage-stub.json.new"
  chmod 0600 "$runtime/.storage-stub.json.new"
  mv -f "$runtime/.storage-stub.json.new" "$runtime/storage-stub.json"
  export OVERALLS_ANTITHESIS_STORAGE_STUB_FILE="$runtime/storage-stub.json"
else
  unset OVERALLS_ANTITHESIS_STORAGE_STUB_FILE
fi

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
metadata=/opt/overalls/lilly/overalls-release.json
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

# The guest-lifecycle profile selects the STUB-storage guest release and names
# its baked immutable TCG image. Only that canonical store directory may be
# configured; its manifest is also published to the enrollment operator's
# catalog share so the operator can register the content-derived image ID.
images='[]'
case "${OVERALLS_ANTITHESIS_GUEST_IMAGE:-}" in
  '') ;;
  /opt/overalls/guest-vmm/image)
    image_dir=$(readlink -e /opt/overalls/guest-vmm/image) || { echo 'guest image unavailable' >&2; exit 1; }
    [[ "$image_dir" =~ ^/nix/store/[0-9a-z]{32}-[A-Za-z0-9._+-]+$ && -f "$image_dir/manifest.json" ]] ||
      { echo 'invalid guest image' >&2; exit 1; }
    images=$(jq -cn --arg path "$image_dir" '[{path:$path}]')
    catalog=/run/overalls-guest-catalog
    [[ -d "$catalog" && ! -L "$catalog" ]] || { echo 'guest catalog share unavailable' >&2; exit 1; }
    jq -e 'type == "object" and .version == 4 and .architecture == "x86_64"' "$image_dir/manifest.json" >/dev/null ||
      { echo 'invalid guest image manifest' >&2; exit 1; }
    cp "$image_dir/manifest.json" "$catalog/.manifest.json.new"
    chmod 0644 "$catalog/.manifest.json.new"
    mv -T "$catalog/.manifest.json.new" "$catalog/manifest.json"
    ;;
  *) echo 'invalid guest image selection' >&2; exit 1 ;;
esac

jq -n --arg host "$host_id" --arg pool "$pool_id" --arg credential "$secrets/lilly-a-credential.json" \
  --arg ca "$secrets/ca.crt" --arg firecracker "$firecracker" --arg jailer "$jailer" --arg unshare "$unshare" \
  --argjson private "$private_services" --argjson images "$images" \
  '{version:4,control_plane:"https://marshall-a:5443",host_id:$host,credential_file:$credential,cacertfile:$ca,state_dir:"/var/lib/lilly/control",cgroup_path:"/sys/fs/cgroup/lilly.slice",images:$images,pools:[{id:$pool,path:"/var/lib/lilly/pool",filesystem_id:"zfs:10001:10002",storage:{backend:"zfs",zpool_guid:"10001",dataset_guid:"10002",dataset:"overalls/antithesis"}}],execution:{state_dir:"/var/lib/lilly/vm",network_state_dir:"/var/lib/lilly/network",egress_interface:"eth0",protected_cidrs:[],firecracker:$firecracker,jailer:$jailer,unshare:$unshare,audi_ingress:false,private_services:$private,guest_trust_roots:[],brady:null,firecracker_logging:false,provisioning_readiness:false,inception_smtp_file:null,inception_image_id:null,inception_proof_file:null,inception_probe_id:null}} | if $private then .ingress={path:"/run/lilly-ingress/audi.sock",audi_uid:0} else . end' > "$runtime/config.json.new"
chmod 0600 "$runtime/config.json.new"
mv "$runtime/config.json.new" "$runtime/config.json"
export LILLY_CONFIG_FILE="$runtime/config.json" LILLY_STATUS_SOCKET="$runtime/status.sock"
export RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP=/dev/null
export RELEASE_COOKIE="$(openssl rand -hex 32)"
exec /opt/overalls/lilly/bin/lilly start
