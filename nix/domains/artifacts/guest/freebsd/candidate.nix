{ pkgs, stagedImage, kernel, agentNames, installMemoryMiB ? 2048
, installCores ? 2, timeoutSeconds ? 600, extraRoot ? null, runtimeRcLocal ? null }:
assert stagedImage.stagingOnly;
assert kernel ? buildId;
assert installMemoryMiB >= 1024 && installMemoryMiB <= 16384;
assert installCores >= 1 && installCores <= 8;
assert timeoutSeconds >= 60 && timeoutSeconds <= 3600;
let
  inherit (pkgs) lib;
  installMedia = if extraRoot == null && runtimeRcLocal == null
    then "${stagedImage}/payload.iso"
    else pkgs.runCommand "overalls-freebsd-candidate-install-media" {
      nativeBuildInputs = [ pkgs.xorriso pkgs.gnutar ];
    } ''
      mkdir -p "$out"
      ${lib.optionalString (extraRoot != null) ''
        tar --format=ustar --owner=0 --group=0 --numeric-owner \
          -C ${extraRoot} -cf "$TMPDIR/extra-root.tar" .
      ''}
      xorriso -indev ${stagedImage}/payload.iso -outdev "$out/payload.iso" \
        ${lib.optionalString (extraRoot != null) ''-map "$TMPDIR/extra-root.tar" /extra-root.tar''} \
        ${lib.optionalString (runtimeRcLocal != null) ''-map ${runtimeRcLocal} /runtime-rc.local''} \
        -commit
    '' + "/payload.iso";
in
# @cc [owner:ghuntley,label:build;verification;isolation] freebsd-native-assembly
# Assembly MUST mutate only a scratch copy of the pinned disk, boot offline in
# bounded KVM guests, require successful installation and a second boot matching
# the compiled build ID and actual kernel digest, then cleanly power off before
# hashing the final GPT/UFS/ESP disk. Assembly MUST NOT establish Firecracker
# transport, service, isolation or native catalog acceptance.
pkgs.runCommand "overalls-freebsd-native-image-candidate" {
  nativeBuildInputs = [ pkgs.qemu_kvm pkgs.coreutils pkgs.mtools pkgs.util-linux pkgs.jq ];
  requiredSystemFeatures = [ "kvm" ];
  preferLocalBuild = true;
  passthru = {
    inherit kernel stagedImage;
    firmware = stagedImage.firmware;
    os = "freebsd";
    nativeAdmission = false;
    imageAssemblyReady = false;
    runtimeValidated = false;
  };
} ''
  set -euo pipefail
  mkdir -p "$out/evidence"
  cp --reflink=auto --sparse=always ${stagedImage}/disk.raw "$out/disk.raw"
  chmod u+w "$out/disk.raw"
  cp -a ${stagedImage}/evidence/. "$out/evidence/"
  chmod u+w "$out/evidence"
  ln -s ${stagedImage.firmware}/FV/CLOUDHV.fd "$out/firmware"
  disk="$out/disk.raw"
  esp_start=$(sfdisk --json "$disk" | jq -er '.partitiontable.partitions[] | select(.name == "efiesp") | .start')
  config_start=$(sfdisk --json "$disk" | jq -er '.partitiontable.partitions[] | select(.name == "config-drive") | .start')
  config_size=$(sfdisk --json "$disk" | jq -er '.partitiontable.partitions[] | select(.name == "config-drive") | .size')
  kernel_digest=$(jq -er .sha256 ${kernel}/share/overalls/native-kernel/provenance.json)
  cp "$out/evidence/freebsd-user-data" "$TMPDIR/installer"
  chmod u+w "$TMPDIR/installer"
  cat >> "$TMPDIR/installer" <<'INSTALL'
# Installation boots have no network or MMDS identity. Disable services until
# the second boot validates the installed root, then restore their declaration.
${lib.optionalString (extraRoot != null) ''tar -xpf "$payload/extra-root.tar" -C /''}
${lib.optionalString (runtimeRcLocal != null) ''install -o root -g wheel -m 0555 "$payload/runtime-rc.local" /etc/overalls/runtime-rc.local''}
# The verified package closure carries no set-ID bits in the Nix store. Restore
# only this reviewed elevation entry point after checking the exact target file.
test -f /usr/local/bin/sudo
test ! -L /usr/local/bin/sudo
test ! -L /usr/local/bin
test ! -L /usr/local
test "$(stat -f %u:%g /usr/local/bin/sudo)" = 0:0
test "$(sha256 -q /usr/local/bin/sudo)" = "$(cat "$payload/sudo-sha256")"
chmod 4755 /usr/local/bin/sudo
install -o root -g wheel -m 0644 "$payload/sudo-sha256" /etc/overalls/sudo-sha256
# Nix store publication makes configuration readable; native sudo requires its
# reviewed policy to recover the target's exact restrictive permissions.
test -f /usr/local/etc/sudoers
test ! -L /usr/local/etc/sudoers
test ! -L /usr/local/etc
test "$(stat -f %u:%g /usr/local/etc/sudoers)" = 0:0
chmod 0440 /usr/local/etc/sudoers
printf 'overalls_native_agents_enable="NO"\n' > /etc/rc.conf.d/overalls_native_agents
printf 'overalls_native_bootstrap_enable="NO"\n' > /etc/rc.conf.d/overalls_native_bootstrap
printf 'sshd_enable="NO"\n' > /etc/rc.conf.d/sshd
printf '\nnuageinit_enable="NO"\nsshd_enable="NO"\nsendmail_enable="NONE"\n' >> /etc/rc.conf
# MMDS bootstrap owns the only native NIC. Never run the release image's DHCP
# defaults or IPv6 autoconfiguration before the validated /32 is installed.
printf '\nifconfig_DEFAULT="NOAUTO"\nifconfig_vtnet0="NOAUTO"\nipv6_activate_all_interfaces="NO"\nip6addrctl_policy="ipv4_prefer"\nrtsold_enable="NO"\n' >> /etc/rc.conf
printf '\nconsole="comconsole"\nboot_serial="YES"\nautoboot_delay="1"\n' >> /boot/loader.conf.local
cat > /etc/rc.local <<'VERIFY'
#!/bin/sh
# This offline verifier handles only public artifact identities and file modes.
# Trace its assertions so a rejected image records the exact failed boundary.
set -eux
trap 'status=$?; if [ "$status" -ne 0 ]; then printf "verification-failed:%s\n" "$status"; shutdown -p now; fi' EXIT
if ! mount -p | grep -q '[[:space:]]/boot/efi[[:space:]]'; then
  mount -t msdosfs /dev/gpt/efiesp /boot/efi
fi
test "$(sysctl -n kern.overalls_vsock_build_id)" = '${kernel.buildId}'
test "$(sysctl -n kern.overalls_vsock_abi)" = 1
test "$(sysctl -n kern.overalls_vsock_cid)" = 3
test "$(sha256 -q /boot/kernel/kernel)" = '@KERNEL_SHA256@'
test "$(cat /etc/overalls/kernel-build-id)" = '${kernel.buildId}'
test "$(stat -f %u /etc/overalls/kernel-build-id)" = 0
test "$(stat -f %p /etc/overalls/kernel-build-id)" = 100644
for binary in ${lib.escapeShellArgs agentNames}; do
  test -x "/usr/local/libexec/$binary"
done
test -x /usr/local/libexec/native-agents-supervisor
test -x /usr/local/etc/rc.d/overalls-native-agents
test -f /etc/rc.conf.d/overalls_native_agents
test -x /usr/local/etc/rc.d/overalls_native_bootstrap
test -f /etc/rc.conf.d/overalls_native_bootstrap
test -x /usr/local/bin/git
test -x /usr/local/libexec/git-core/git-remote-https
test -s /etc/ssl/cert.pem
/usr/local/bin/git --version
test -f /usr/local/bin/sudo
test ! -L /usr/local/bin/sudo
test "$(stat -f %u:%g /usr/local/bin/sudo)" = 0:0
# FreeBSD's %Lp deliberately masks out set-ID bits; full %p includes type.
test "$(stat -f %p /usr/local/bin/sudo)" = 104755
test "$(sha256 -q /usr/local/bin/sudo)" = "$(cat /etc/overalls/sudo-sha256)"
test -x /usr/local/bin/bash
test -f /usr/local/etc/sudoers
test ! -L /usr/local/etc/sudoers
test "$(stat -f %u:%g /usr/local/etc/sudoers)" = 0:0
test "$(stat -f %p /usr/local/etc/sudoers)" = 100440
/usr/local/bin/sudo --version
/usr/local/bin/bash --version
test -f /usr/include/sys/vsock.h
grep -q '^#define VSOCK_SO_BUILD_ID 1$' /usr/include/sys/vsock.h
printf 'overalls_native_agents_enable="YES"\n' > /etc/rc.conf.d/overalls_native_agents
printf 'overalls_native_bootstrap_enable="YES"\n' > /etc/rc.conf.d/overalls_native_bootstrap
${if runtimeRcLocal == null then ''rm -f /etc/rc.local'' else ''mv /etc/overalls/runtime-rc.local /etc/rc.local''}
printf 'verified:%s\n' '${kernel.buildId}' > /boot/efi/overalls/verify-status
sync
shutdown -p now
VERIFY
chmod 0555 /etc/rc.local
printf 'installed:%s\n' '${kernel.buildId}' > /boot/efi/overalls/install-status
sync
shutdown -p now
INSTALL
  substituteInPlace "$TMPDIR/installer" --replace-fail '@KERNEL_SHA256@' "$kernel_digest"
  config_drive="$TMPDIR/config-drive.img"
  dd if="$disk" of="$config_drive" bs=512 skip="$config_start" count="$config_size" status=none
  mcopy -o -i "$config_drive" "$TMPDIR/installer" ::user-data
  dd if="$config_drive" of="$disk" bs=512 seek="$config_start" conv=notrunc status=none
  for stage in install verify; do
    # QEMU's pinned SeaBIOS boots the preserved BIOS loader for offline
    # installation. The shipped disk also retains its EFI loader and separately
    # hashed CloudHv firmware for Firecracker's PVH boot contract.
    declare -a media=()
    if [ "$stage" = install ]; then
      media=(-drive file=${installMedia},format=raw,media=cdrom,if=ide,readonly=on)
    fi
    if ! timeout --signal=TERM --kill-after=10s ${toString timeoutSeconds}s \
      ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
      -enable-kvm -cpu host -m ${toString installMemoryMiB} -smp ${toString installCores} \
      -display none -serial stdio -monitor none -no-reboot \
      -nic none \
      -rtc base=2026-10-17T00:00:00,clock=vm \
      "''${media[@]}" \
      -drive "file=$disk,format=raw,if=virtio" \
      > "$out/evidence/$stage-serial.log" 2>&1; then
      tail -n 80 "$out/evidence/$stage-serial.log" >&2
      exit 1
    fi
    if ! mcopy -i "$disk@@$((esp_start * 512))" "::overalls/$stage-status" "$TMPDIR/$stage-status"; then
      tail -n 80 "$out/evidence/$stage-serial.log" >&2
      exit 1
    fi
    expected=installed
    if [ "$stage" = verify ]; then expected=verified; fi
    test "$(cat "$TMPDIR/$stage-status")" = "$expected:${kernel.buildId}"
    cp "$TMPDIR/$stage-status" "$out/evidence/$stage-status"
  done
  sfdisk --json "$disk" > "$out/evidence/partition-table.json"
  jq -e '.partitiontable.label == "gpt" and
    any(.partitiontable.partitions[]; .name == "efiesp") and
    any(.partitiontable.partitions[]; .name == "rootfs")' "$out/evidence/partition-table.json" > /dev/null
  root_bytes=$(stat -Lc %s "$disk")
  root_sha256=$(sha256sum "$disk" | cut -d ' ' -f1)
  jq --argjson bytes "$root_bytes" --arg sha256 "$root_sha256" \
    '.root.bytes=$bytes | .root.sha256=$sha256' ${stagedImage}/manifest.json > "$out/manifest.json"
  jq -n --slurpfile manifest "$out/manifest.json" --arg build_id '${kernel.buildId}' \
    '{version:1,os:"freebsd",manifest:$manifest[0],build_id:$build_id,
      installed:true,booted_kernel_checked:true,kernel_digest_checked:true,
      agent_files_checked:true,service_files_checked:true,git_runtime_checked:true,
      trust_bundle_checked:true,clean_poweroff:true,
      sudo_digest_and_mode_checked:true,native_shell_checked:true,
      firecracker_transport_validated:false,native_services_validated:false,
      isolation_validated:false,native_admission:false}' > "$out/evidence/assembly-receipt.json"
''
