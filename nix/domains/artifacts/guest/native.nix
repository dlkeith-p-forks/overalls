{ pkgs, firmware ? (import ./windows/firmware.nix { inherit pkgs; }).fd, nativeAgents ? null, lyra ? null }:
let
  inherit (pkgs) lib;
  # Native guests are deliberately assembled from immutable upstream release
  # artifacts.  The source derivations are separate so a source refresh cannot
  # silently change the manifest or the file set.
  mkFreeBSDSource = pkgs.fetchurl {
    pname = "freebsd-14.3-amd64-basic-cloudinit-ufs";
    version = "14.3-RELEASE";
    # FreeBSD removed 14.3 from the rolling VM-IMAGES index. Keep the release
    # URL and digest explicit; updating this pin requires a reviewed source
    # refresh, rather than following Latest.
    url = "https://web.archive.org/web/20250625173735id_/https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/FreeBSD-14.3-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz";
    hash = "sha256-5zyETu3q+WirvfHlcvXeC2tgKflH7Rvp4iIEp0qIaqw=";
  };
  mkOmniOSSource = pkgs.fetchurl {
    pname = "omnios-r151050-cloud-raw";
    version = "r151050";
    url = "https://downloads.omnios.org/media/r151050/omnios-r151050.cloud.raw.zst";
    hash = "sha256-787Bo109Vm7bEyjQd6VKgMHeKobdN+U73hL5bKXGi4s=";
  };
  # illumos.org is the upstream operating-system project. It publishes the
  # common source and directs users to downstream distributions for installable
  # images; the pinned OmniOS artifact below is therefore the concrete illumos
  # image source used by this builder.
  illumosUpstreamUrl = "https://illumos.org/";
  nativeFreeBSDSource =
    if nativeAgents != null then "${nativeAgents}/freebsd/bin"
    else if lyra != null then "${lyra}/bin"
    else null;
  nativeFreeBSDPrefix =
    if nativeAgents != null then "overalls-native-"
    else "x86_64-unknown-freebsd-overalls-native-";
  # @cc [owner:ghuntley,label:build;protocol] freebsd-native-image-pinned
  # The FreeBSD builder MUST use the reviewed 14.3 source pin, preserve its
  # complete GPT/EFI/UFS disk for the CloudHv firmware boot path, and bind
  # every emitted artifact's exact byte length and SHA-256 in the v6 manifest.
  mkFreeBSD = { imageName ? "lilly-freebsd-14_3-x86_64", minimumMemoryBytes ? 1073741824
    , minimumDiskBytes ? 68719476736, workspaceSourceVersion ? 2 }:
    assert workspaceSourceVersion == null || nativeAgents != null || lyra != null;
    pkgs.runCommand imageName { nativeBuildInputs = [ pkgs.coreutils pkgs.jq pkgs.mtools pkgs.util-linux pkgs.xz ]; preferLocalBuild = true;
      passthru = { os = "freebsd"; release = "14.3-RELEASE"; inherit firmware; source = mkFreeBSDSource; sourceUrl = "https://web.archive.org/web/20250625173735id_/https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/FreeBSD-14.3-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz"; sourceHash = "sha256-5zyETu3q+WirvfHlcvXeC2tgKflH7Rvp4iIEp0qIaqw="; }; } ''
      set -euo pipefail
      mkdir -p "$out"
      # Keep the source disk sparse while retaining GPT backup metadata and the
      # EFI system partition. A direct FreeBSD ELF kernel cannot be consumed by
      # Firecracker's Linux kernel loader.
      xz -dc ${mkFreeBSDSource} | dd of="$out/disk.raw" bs=1M conv=sparse status=none
      ${lib.optionalString (nativeAgents != null) ''
        mkdir -p "$out/evidence/native-agents/freebsd"
        for agent in overalls-native-readinessd overalls-native-trustd overalls-native-workspaced; do
          test -x ${nativeAgents}/freebsd/bin/"$agent"
        done
        cp -a ${nativeAgents}/freebsd/bin/. "$out/evidence/native-agents/freebsd/"
      ''}
      ${lib.optionalString (nativeAgents == null && lyra != null) ''
        mkdir -p "$out/evidence/native-agents/freebsd"
        for binary in readinessd trustd workspaced; do
          install -m 0755 ${lyra}/bin/x86_64-unknown-freebsd-overalls-native-$binary "$out/evidence/native-agents/freebsd/overalls-native-$binary"
        done
      ''}
      ${lib.optionalString (nativeAgents != null || lyra != null) ''
        mkdir -p "$out/evidence/native-services/freebsd"
        for service in readiness trust workspace; do
          cat > "$out/evidence/native-services/freebsd/overalls-$service" <<EOF
#!/bin/sh
# Native Overalls service definition; install into /usr/local/etc/rc.d by the
# image installer after the payload has been copied to /usr/local/libexec.
# PROVIDE: overalls_$service
# REQUIRE: NETWORKING
# KEYWORD: shutdown
. /etc/rc.subr
name=overalls_$service
rcvar=overalls_''${service}_enable
command=/usr/local/libexec/overalls-native-''${service}d
load_rc_config "\$name"
: \''${overalls_''${service}_enable:=NO}
run_rc_command "\$1"
EOF
          chmod 0755 "$out/evidence/native-services/freebsd/overalls-$service"
        done
      ''}
      ${lib.optionalString (nativeAgents != null || lyra != null) ''
        # The UFS root cannot be edited by the Linux builder. Stage native
        # agents on the writable EFI FAT filesystem and let nuageinit's
        # first-boot user-data installer copy them into /usr/local/libexec.
        esp_start=$(sfdisk --json "$out/disk.raw" | jq -r '.partitiontable.partitions[] | select(.name == "efiesp") | .start')
        mmd -i "$out/disk.raw@@$((esp_start * 512))" ::overalls
        for binary in readinessd trustd workspaced; do
          mcopy -i "$out/disk.raw@@$((esp_start * 512))" \
            "${nativeFreeBSDSource}/${nativeFreeBSDPrefix}$binary" \
            "::overalls/overalls-native-$binary"
        done
        config_start=$(sfdisk --json "$out/disk.raw" | jq -r '.partitiontable.partitions[] | select(.name == "config-drive") | .start')
        config_size=$(sfdisk --json "$out/disk.raw" | jq -r '.partitiontable.partitions[] | select(.name == "config-drive") | .size')
        config_drive="$TMPDIR/freebsd-config-drive.img"
        dd if="$out/disk.raw" of="$config_drive" bs=512 skip="$config_start" count="$config_size" status=none
        mformat -i "$config_drive" -v cidata ::
        cat > "$TMPDIR/freebsd-meta-data" <<'EOF'
instance-id: overalls-native
local-hostname: overalls-native
EOF
        mcopy -i "$config_drive" "$TMPDIR/freebsd-meta-data" ::meta-data
        cat > "$TMPDIR/freebsd-user-data" <<'EOF'
#!/bin/sh
set -eu
esp=/boot/efi
if ! mount -p | grep -q ' /boot/efi '; then
  mount -t msdosfs /dev/gpt/efiboot0 "$esp"
fi
install -d -m 0755 /usr/local/libexec /usr/local/etc/rc.d
for service in readiness trust workspace; do
  install -m 0755 "$esp/overalls/overalls-native-$service"d \
    "/usr/local/libexec/overalls-native-$service"d
done
for service in readiness trust workspace; do
  cat > "/usr/local/etc/rc.d/overalls-$service" <<RC
#!/bin/sh
# PROVIDE: overalls_$service
# REQUIRE: NETWORKING
# KEYWORD: shutdown
. /etc/rc.subr
name=overalls_$service
rcvar=overalls_''${service}_enable
command=/usr/local/libexec/overalls-native-''${service}d
load_rc_config "\$name"
[ -n "\$overalls_''${service}_enable" ] || overalls_''${service}_enable=NO
run_rc_command "\$1"
RC
  chmod 0755 "/usr/local/etc/rc.d/overalls-$service"
done
cat > /etc/rc.conf.d/overalls <<'RC'
overalls_readiness_enable=YES
overalls_trust_enable=YES
overalls_workspace_enable=YES
RC
for service in readiness trust workspace; do
  service "overalls-$service" start || true
done
EOF
        mcopy -i "$config_drive" "$TMPDIR/freebsd-user-data" ::user-data
        dd if="$config_drive" of="$out/disk.raw" bs=512 seek="$config_start" conv=notrunc status=none
      ''}
      sfdisk --json "$out/disk.raw" | jq -e '.partitiontable.partitions[] | select(.name == "efiesp")' >/dev/null
      sfdisk --json "$out/disk.raw" | jq -e '.partitiontable.partitions[] | select(.name == "rootfs")' >/dev/null
      ln -s ${firmware}/FV/CLOUDHV.fd "$out/firmware"
      firmware_bytes=$(stat -Lc %s "$out/firmware")
      firmware_sha256=$(sha256sum "$out/firmware" | cut -d' ' -f1)
      root_bytes=$(stat -Lc %s "$out/disk.raw")
      root_sha256=$(sha256sum "$out/disk.raw" | cut -d' ' -f1)
      jq -n \
        --argjson memory ${toString minimumMemoryBytes} --argjson disk ${toString minimumDiskBytes} \
        --argjson source ${lib.optionalString (workspaceSourceVersion == null) "null"}${lib.optionalString (workspaceSourceVersion != null) (toString workspaceSourceVersion)} \
        --argjson firmware_bytes "$firmware_bytes" --arg firmware_sha256 "$firmware_sha256" \
        --argjson root_bytes "$root_bytes" --arg root_sha256 "$root_sha256" \
        '{version:6,os:"freebsd",architecture:"x86_64",boot:{kind:"firmware",pci:true,firmware:{bytes:$firmware_bytes,sha256:$firmware_sha256}},root:{format:"raw-gpt",bytes:$root_bytes,sha256:$root_sha256},guest_agents:"freebsd-v1",minimum_memory_bytes:$memory,minimum_disk_bytes:$disk,workspace_source_version:$source}' > "$out/manifest.json"
    '';
  # @cc [owner:ghuntley,label:build;protocol] omnios-native-image-pinned
  # The OmniOS builder MUST use the immutable r151050 cloud raw pin and emit
  # the v6 illumos firmware/raw-GPT shape; it MUST NOT reuse a Linux ext4
  # builder or infer its agent capability from installed files.
  mkOmniOS = { imageName ? "lilly-omnios-r151050-x86_64", minimumMemoryBytes ? 2147483648
    , minimumDiskBytes ? 17179869184, workspaceSourceVersion ? null }:
    assert workspaceSourceVersion == null || nativeAgents != null || lyra != null;
    pkgs.runCommand imageName { nativeBuildInputs = [ pkgs.coreutils pkgs.jq pkgs.util-linux pkgs.zstd ]; preferLocalBuild = true;
      passthru = {
        os = "illumos";
        distribution = "OmniOS";
        release = "r151050";
        nativeAgentsAvailable = nativeAgents != null;
        inherit firmware;
        upstreamUrl = illumosUpstreamUrl;
        source = mkOmniOSSource;
        sourceUrl = "https://downloads.omnios.org/media/r151050/omnios-r151050.cloud.raw.zst";
        sourceHash = "sha256-787Bo109Vm7bEyjQd6VKgMHeKobdN+U73hL5bKXGi4s=";
      }; } ''
      set -euo pipefail
      mkdir -p "$out"
      zstd -dc ${mkOmniOSSource} > "$out/disk.raw"
      ${lib.optionalString (nativeAgents != null) ''
        mkdir -p "$out/evidence/native-agents/illumos"
        for agent in overalls-native-readinessd overalls-native-trustd overalls-native-workspaced; do
          test -x ${nativeAgents}/illumos/bin/"$agent"
        done
        cp -a ${nativeAgents}/illumos/bin/. "$out/evidence/native-agents/illumos/"
      ''}
      ${lib.optionalString (nativeAgents == null && lyra != null) ''
        mkdir -p "$out/evidence/native-agents/illumos"
        for binary in readinessd trustd workspaced; do
          install -m 0755 ${lyra}/bin/x86_64-unknown-illumos-overalls-native-$binary "$out/evidence/native-agents/illumos/overalls-native-$binary"
        done
      ''}
      ${lib.optionalString (nativeAgents != null || lyra != null) ''
        mkdir -p "$out/evidence/native-services/illumos"
        for service in readiness trust workspace; do
          cat > "$out/evidence/native-services/illumos/overalls-$service.xml" <<EOF
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<service_bundle type="manifest" name="overalls-$service">
  <service name="site/overalls-$service" type="service" version="1">
    <create_default_instance enabled="true"/>
    <single_instance/>
    <exec_method type="method" name="start" exec="/opt/overalls/libexec/overalls-native-''${service}d" timeout_seconds="0"/>
    <exec_method type="method" name="stop" exec=":kill" timeout_seconds="30"/>
    <property_group name="startd" type="framework">
      <propval name="duration" type="astring" value="contract"/>
    </property_group>
  </service>
</service_bundle>
EOF
        done
      ''}
      # Keep the complete OmniOS GPT layout.  The loader and ZFS partitions
      # are required by CloudHv firmware; accepting an arbitrary raw disk here
      # would produce a manifest that cannot boot the pinned userspace.
      sfdisk --json "$out/disk.raw" | jq -e '.partitiontable.label == "gpt"' >/dev/null
      sfdisk --json "$out/disk.raw" | jq -e '.partitiontable.partitions[] | select(.name == "loader")' >/dev/null
      sfdisk --json "$out/disk.raw" | jq -e '.partitiontable.partitions[] | select(.name == "zfs")' >/dev/null
      # The CloudHv PVH firmware is supplied by the pinned package input. It is
      # content-addressed in the manifest alongside the OmniOS disk.
      ln -s ${firmware}/FV/CLOUDHV.fd "$out/firmware"
      firmware_bytes=$(stat -Lc %s "$out/firmware")
      firmware_sha256=$(sha256sum "$out/firmware" | cut -d' ' -f1)
      root_bytes=$(stat -Lc %s "$out/disk.raw")
      root_sha256=$(sha256sum "$out/disk.raw" | cut -d' ' -f1)
      jq -n \
        --argjson memory ${toString minimumMemoryBytes} --argjson disk ${toString minimumDiskBytes} \
        --argjson source ${lib.optionalString (workspaceSourceVersion == null) "null"}${lib.optionalString (workspaceSourceVersion != null) (toString workspaceSourceVersion)} \
        --argjson firmware_bytes "$firmware_bytes" --arg firmware_sha256 "$firmware_sha256" \
        --argjson root_bytes "$root_bytes" --arg root_sha256 "$root_sha256" \
        '{version:6,os:"illumos",architecture:"x86_64",boot:{kind:"firmware",pci:true,firmware:{bytes:$firmware_bytes,sha256:$firmware_sha256}},root:{format:"raw-gpt",bytes:$root_bytes,sha256:$root_sha256},guest_agents:"illumos-v1",minimum_memory_bytes:$memory,minimum_disk_bytes:$disk,workspace_source_version:$source}' > "$out/manifest.json"
    '';
  # @cc [owner:ghuntley,label:build;protocol] illumos-downstream-image
  # The generic illumos constructor MUST use the pinned OmniOS downstream
  # artifact while preserving the illumos protocol family and manifest shape.
  # illumos.org is an upstream source project, not an image distribution, so a
  # direct URL cannot be used as a guest root without selecting a downstream.
  mkIllumos = { imageName ? "lilly-illumos-r151050-x86_64", minimumMemoryBytes ? 2147483648
    , minimumDiskBytes ? 17179869184, workspaceSourceVersion ? null }:
    mkOmniOS { inherit imageName minimumMemoryBytes minimumDiskBytes workspaceSourceVersion; };
in
{ inherit mkFreeBSD mkOmniOS mkIllumos mkFreeBSDSource mkOmniOSSource illumosUpstreamUrl; }
