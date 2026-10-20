#!/bin/sh
# Offline OmniOS administration-guest stage for the Nix assembly derivation.
# It runs as root in a single-user disposable administration boot whose own
# pool was re-GUIDed in an earlier boot. The read-only transfer disk carries
# the exact candidate kit; the writable evidence disk receives exact receipts.

# @cc [owner:ghuntley,label:build;isolation;verification] omnios-guest-assembly-stage
# The stage MUST locate exactly one importable scratch pool whose label is
# not the running administration pool, select its ZFS slice by label GUID,
# and run the reviewed native_image.py assemble with the Nix-declared build ID.
# Receipt extraction MUST import the exported pool read-only and copy exact
# receipt and installed-module bytes; it MUST NOT mutate or boot the target.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin
export PATH
kit=/mnt/kit
evidence=/mnt/evidence
work=/root/overalls-nix-kit
pool=overalls_native_candidate
dataset=$pool/ROOT/overalls-native-candidate
expected=$(cat "$kit/build-id")
case "$expected" in
  *[!0-9a-f]* | "") echo "invalid build identity" >&2; exit 1 ;;
esac
test "${#expected}" -eq 64

mkdir -p "$evidence"
found=
for device in /dev/dsk/c*p1; do
  mount -F pcfs "$device" "$evidence" 2>/dev/null || continue
  if test -f "$evidence/overalls-evidence"; then found=$device; break; fi
  umount "$evidence"
done
test -n "$found"
echo "evidence-disk=$found"

# The administration copy was re-GUIDed in an earlier boot, but both pools
# still share vdev GUIDs, which makes a bare `zpool import` scan merge their
# labels. Read each slice label directly and require exactly one ZFS slice
# whose pool GUID differs from every imported pool.
zpool list -H -o name,guid > "$evidence/zpool-imported.txt"
imported=$(awk '{ print $2 }' "$evidence/zpool-imported.txt")
target=
guid=
: > "$evidence/slice-labels.txt"
for slice in /dev/dsk/c*t*d*s1; do
  label=$(zdb -l "$slice" 2>/dev/null | awk '$1 == "pool_guid:" { print $2 }' | sort -u)
  test -n "$label" || continue
  printf '%s %s\n' "$slice" "$label" >> "$evidence/slice-labels.txt"
  test "$(echo "$label" | grep -c .)" -eq 1
  if echo "$imported" | grep -qx "$label"; then continue; fi
  test -z "$target" || { echo "ambiguous scratch slice" >&2; exit 1; }
  target=$slice
  guid=$label
done
cat "$evidence/zpool-imported.txt" "$evidence/slice-labels.txt"
test -n "$target"
case "$guid" in *[!0-9]* | "") exit 1 ;; esac
echo "target-slice=$target guid=$guid"
printf '%s\n' "$guid" > "$evidence/pool-guid"

rm -rf "$work"
mkdir -m 0700 "$work"
tar xf "$kit/kit.tar" -C "$work"
status=0
python3.12 -B -E -s "$work/bin/native_image.py" assemble "$work" "$target" "$guid" "$expected" \
  > "$evidence/assembly.log" 2>&1 || status=$?
tail -n 40 "$evidence/assembly.log"
test "$status" -eq 0

# Read-only receipt extraction from the exported, assembled pool.
base=/var/tmp/overalls-nix-evidence
rm -rf "$base"
mkdir -m 0700 "$base" "$base/devices" "$base/root"
ln -s "$target" "$base/devices/scratch"
zpool import -f -N -o readonly=on -o cachefile=none -R "$base" -d "$base/devices" "$guid" "$pool"
test "$(zpool get -H -o value guid "$pool")" = "$guid"
test "$(zpool get -H -o value bootfs "$pool")" = "$dataset"
mount -F zfs -o ro "$dataset" "$base/root"
root=$base/root
cp "$root/etc/overalls/native-image/assembly-receipt.json" "$evidence/assembly-receipt.json"
cp "$root/etc/overalls/native-kernel/linked-receipt.json" "$evidence/linked-receipt.json"
cp "$root/etc/overalls/native-kernel/install-receipt.json" "$evidence/install-receipt.json"
cp "$root/etc/overalls/kernel-build-id" "$evidence/kernel-build-id"
: > "$evidence/installed-modules.txt"
for module in kernel/misc/amd64/virtio kernel/drv/amd64/vioblk kernel/drv/amd64/vioif \
  kernel/drv/amd64/vioscsi kernel/drv/amd64/vio9p kernel/drv/amd64/viorand \
  kernel/fs/amd64/sockfs kernel/drv/amd64/viosock kernel/socketmod/amd64/sockvsock \
  platform/i86pc/kernel/amd64/unix; do
  printf '%s %s\n' "$(digest -a sha256 "$root/$module")" "$module" >> "$evidence/installed-modules.txt"
done
mkdir -p "$evidence/modules"
cp "$root/kernel/drv/amd64/viosock" "$evidence/modules/viosock"
cp "$root/kernel/socketmod/amd64/sockvsock" "$evidence/modules/sockvsock"
cp "$root/etc/sock2path.d/overalls-native-vsock" "$evidence/sock2path-overalls-native-vsock"
umount "$base/root"
zpool export "$pool"
rm -rf "$base"
printf 'assembled:%s\n' "$expected" > "$evidence/guest-status"
sync
umount "$evidence"
echo OVERALLS_GUEST_ASSEMBLY_COMPLETE
