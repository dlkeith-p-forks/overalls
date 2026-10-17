{ pkgs, firmware ? (import ./windows/firmware.nix { inherit pkgs; }).fd }:
let
  inherit (pkgs) lib;
  nativeKernels = import ./native-kernels { inherit pkgs; };
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
  # @cc [owner:ghuntley,label:build;protocol] freebsd-native-image-pinned
  # The FreeBSD builder MUST use the reviewed 14.3 source pin, preserve its
  # complete GPT/EFI/UFS disk for the CloudHv firmware boot path, and bind
  # every emitted artifact's exact byte length and SHA-256 in the v6 manifest.
  mkFreeBSD = { imageName ? "lilly-freebsd-14_3-x86_64", minimumMemoryBytes ? 1073741824
    , minimumDiskBytes ? 68719476736, workspaceSourceVersion ? null, agentPackage ? null
    , kernel ? nativeKernels.freebsd, kernelProvenance ? kernel.provenance }:
    pkgs.runCommand imageName { nativeBuildInputs = [ pkgs.coreutils pkgs.jq pkgs.util-linux pkgs.xz ]; preferLocalBuild = true;
      passthru = {
        os = "freebsd";
        release = "14.3-RELEASE";
        inherit firmware kernel kernelProvenance;
        kernelSourceRevision = nativeKernels.freebsdRevision;
        kernelPatchHash = nativeKernels.freebsdPatchHash;
        kernelConfigurationHash = nativeKernels.freebsdConfigurationHash;
        kernelCompiler = nativeKernels.compiler;
        kernelReady = kernelProvenance.bytes > 1;
        # UFS mutation, service installation and post-boot probes require an
        # OS-native assembler. No Linux-side helper may turn a stock disk into
        # an admitted native image.
        imageAssemblyReady = false;
        # The source image and agents are not enough to admit a native guest:
        # both a real cross-built kernel and an OS-specific agent package are
        # required.  Keep this false while the receipt is scaffold-only.
        nativeAdmission = false;
        source = mkFreeBSDSource;
        sourceUrl = "https://web.archive.org/web/20250625173735id_/https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/FreeBSD-14.3-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz";
        sourceHash = "sha256-5zyETu3q+WirvfHlcvXeC2tgKflH7Rvp4iIEp0qIaqw=";
      };
    } ''
      set -euo pipefail
      # The source/patch receipt is deliberately not a boot artifact. Until a
      # cross FreeBSD build supplies a real kernel, fail before unpacking the
      # stock disk so a stock kernel can never be advertised as native support.
      test ${lib.boolToString (kernelProvenance.bytes > 1)} = true
      # Keep this explicit until the FreeBSD-aware UFS/EFI assembler and its
      # native boot probe exist; copying files beside a raw disk is insufficient.
      test false = true
      # Native daemons are installed into the guest root by the OS-specific
      # image assembler.  Do not add an `$out/agents` sidecar: Image.load's
      # closed file set intentionally rejects files that are not manifest
      # artifacts, and a host-side directory would not put binaries in the
      # booted root anyway.
      mkdir -p "$out"
      # Keep the source disk sparse while retaining GPT backup metadata and the
      # EFI system partition. A direct FreeBSD ELF kernel cannot be consumed by
      # Firecracker's Linux kernel loader.
      xz -dc ${mkFreeBSDSource} | dd of="$out/disk.raw" bs=1M conv=sparse status=none
      sfdisk --json "$out/disk.raw" | jq -e '.partitiontable.partitions[] | select(.name == "efiesp")' >/dev/null
      sfdisk --json "$out/disk.raw" | jq -e '.partitiontable.partitions[] | select(.name == "rootfs")' >/dev/null
      ln -s ${firmware}/FV/CLOUDHV.fd "$out/firmware"
      firmware_bytes=$(stat -Lc %s "$out/firmware")
      firmware_sha256=$(sha256sum "$out/firmware" | cut -d' ' -f1)
      root_bytes=$(stat -Lc %s "$out/disk.raw")
      root_sha256=$(sha256sum "$out/disk.raw" | cut -d' ' -f1)
      jq -n \
        --argjson memory ${toString minimumMemoryBytes} --argjson disk ${toString minimumDiskBytes} \
        --argjson source ${if workspaceSourceVersion != null then toString workspaceSourceVersion else if agentPackage != null then "2" else "null"} \
        --argjson kernel '${builtins.toJSON kernelProvenance}' \
        --argjson firmware_bytes "$firmware_bytes" --arg firmware_sha256 "$firmware_sha256" \
        --argjson root_bytes "$root_bytes" --arg root_sha256 "$root_sha256" \
        '{version:6,os:"freebsd",architecture:"x86_64",boot:{kind:"firmware",pci:true,firmware:{bytes:$firmware_bytes,sha256:$firmware_sha256}},kernel:$kernel,root:{format:"raw-gpt",bytes:$root_bytes,sha256:$root_sha256},guest_agents:"freebsd-v1",minimum_memory_bytes:$memory,minimum_disk_bytes:$disk,workspace_source_version:$source}' > "$out/manifest.json"
    '';
  # @cc [owner:ghuntley,label:build;protocol] omnios-native-image-pinned
  # The OmniOS builder MUST use the immutable r151050 cloud raw pin and emit
  # the v6 illumos firmware/raw-GPT shape; it MUST NOT reuse a Linux ext4
  # builder or infer its agent capability from installed files.
  mkOmniOS = { imageName ? "lilly-omnios-r151050-x86_64", minimumMemoryBytes ? 2147483648
    , minimumDiskBytes ? 17179869184, workspaceSourceVersion ? null, agentPackage ? null
    , kernel ? nativeKernels.illumos, kernelProvenance ? kernel.provenance }:
    pkgs.runCommand imageName { nativeBuildInputs = [ pkgs.jq pkgs.zstd ]; preferLocalBuild = true;
      passthru = {
        os = "illumos";
        distribution = "OmniOS";
        release = "r151050";
        inherit firmware kernel kernelProvenance;
        kernelSourceRevision = nativeKernels.illumosRevision;
        kernelPatchHash = nativeKernels.illumosPatchHash;
        kernelConfigurationHash = nativeKernels.illumosConfigurationHash;
        kernelCompiler = nativeKernels.compiler;
        kernelReady = kernelProvenance.bytes > 1;
        # ZFS pool import/export and SMF installation require an illumos-aware
        # assembler, followed by a native machine probe.
        imageAssemblyReady = false;
        nativeAdmission = false;
        illumosSdk = nativeKernels.illumosSdk;
        upstreamUrl = illumosUpstreamUrl;
        source = mkOmniOSSource;
        sourceUrl = "https://downloads.omnios.org/media/r151050/omnios-r151050.cloud.raw.zst";
        sourceHash = "sha256-787Bo109Vm7bEyjQd6VKgMHeKobdN+U73hL5bKXGi4s=";
      }; } ''
      set -euo pipefail
      # Keep OmniOS admission closed until the patched kernel and SDK have been
      # built and attested by the native machine gate.
      test ${lib.boolToString (kernelProvenance.bytes > 1)} = true
      test false = true
      # Native daemons are installed into the guest root by the OS-specific
      # image assembler; this output remains only the closed image artifact
      # set until that assembler and its boot evidence exist.
      mkdir -p "$out"
      zstd -dc ${mkOmniOSSource} > "$out/disk.raw"
      # The CloudHv PVH firmware is supplied by the pinned package input. It is
      # content-addressed in the manifest alongside the OmniOS disk.
      ln -s ${firmware}/FV/CLOUDHV.fd "$out/firmware"
      firmware_bytes=$(stat -Lc %s "$out/firmware")
      firmware_sha256=$(sha256sum "$out/firmware" | cut -d' ' -f1)
      root_bytes=$(stat -Lc %s "$out/disk.raw")
      root_sha256=$(sha256sum "$out/disk.raw" | cut -d' ' -f1)
      jq -n \
        --argjson memory ${toString minimumMemoryBytes} --argjson disk ${toString minimumDiskBytes} \
        --argjson source ${if workspaceSourceVersion != null then toString workspaceSourceVersion else if agentPackage != null then "2" else "null"} \
        --argjson kernel '${builtins.toJSON kernelProvenance}' \
        --argjson firmware_bytes "$firmware_bytes" --arg firmware_sha256 "$firmware_sha256" \
        --argjson root_bytes "$root_bytes" --arg root_sha256 "$root_sha256" \
        '{version:6,os:"illumos",architecture:"x86_64",boot:{kind:"firmware",pci:true,firmware:{bytes:$firmware_bytes,sha256:$firmware_sha256}},kernel:$kernel,root:{format:"raw-gpt",bytes:$root_bytes,sha256:$root_sha256},guest_agents:"illumos-v1",minimum_memory_bytes:$memory,minimum_disk_bytes:$disk,workspace_source_version:$source}' > "$out/manifest.json"
    '';
  # @cc [owner:ghuntley,label:build;protocol] illumos-downstream-image
  # The generic illumos constructor MUST use the pinned OmniOS downstream
  # artifact while preserving the illumos protocol family and manifest shape.
  # illumos.org is an upstream source project, not an image distribution, so a
  # direct URL cannot be used as a guest root without selecting a downstream.
  mkIllumos = { imageName ? "lilly-illumos-r151050-x86_64", minimumMemoryBytes ? 2147483648
    , minimumDiskBytes ? 17179869184, workspaceSourceVersion ? null, agentPackage ? null
    , kernel ? nativeKernels.illumos, kernelProvenance ? kernel.provenance }:
    mkOmniOS { inherit imageName minimumMemoryBytes minimumDiskBytes workspaceSourceVersion agentPackage kernel kernelProvenance; };
in
{ inherit mkFreeBSD mkOmniOS mkIllumos mkFreeBSDSource mkOmniOSSource illumosUpstreamUrl nativeKernels; }
