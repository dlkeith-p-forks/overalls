{ pkgs, packages }:
let
  inherit (pkgs) lib;
  freebsd = packages.mkFreeBSDGuest { imageName = "freebsd-evaluation"; };
  omnios = packages.mkOmniOSGuest { imageName = "omnios-evaluation"; };
  illumos = packages.mkIllumosGuest { imageName = "illumos-evaluation"; };
  fleetImages = import ../../../../fleet/guest-images.nix { overallsPackages = packages; };
  plain = builtins.unsafeDiscardStringContext;
  freebsdCommand = plain freebsd.buildCommand;
  omniosCommand = plain omnios.buildCommand;
  illumosCommand = plain illumos.buildCommand;
  freebsdFleetImage = lib.findFirst (image: image.name == "FreeBSD 14.3") null fleetImages;
  illumosFleetImage = lib.findFirst (image: image.name == "OmniOS r151050") null fleetImages;
in
# This is an evaluation gate: it checks source pins, closed artifact assembly
# and v6 manifest fields without downloading or installing a guest image.
assert freebsd.passthru.os == "freebsd";
assert freebsd.passthru.release == "14.3-RELEASE";
assert toString freebsd.passthru.firmware == toString packages.windowsFirmware.fd;
assert omnios.passthru.os == "illumos";
assert omnios.passthru.release == "r151050";
assert !omnios.passthru.nativeAgentsAvailable;
assert toString omnios.passthru.firmware == toString packages.windowsFirmware.fd;
assert illumos.passthru.os == "illumos";
assert illumos.passthru.distribution == "OmniOS";
assert illumos.passthru.release == "r151050";
assert toString illumos.passthru.firmware == toString packages.windowsFirmware.fd;
assert illumos.passthru.upstreamUrl == "https://illumos.org/";
# Receipts are not native kernels; neither OS may enter the fleet catalog.
assert freebsdFleetImage == null;
assert illumosFleetImage == null;
assert !freebsd.passthru.kernelReady;
assert !omnios.passthru.kernelReady;
assert !freebsd.passthru.imageAssemblyReady;
assert !freebsd.passthru.stagingOnly;
assert !packages.freebsdImageCandidate.nativeAdmission;
assert !packages.freebsdImageCandidate.runtimeValidated;
assert !omnios.passthru.imageAssemblyReady;
assert !freebsd.passthru.nativeAdmission;
assert !omnios.passthru.nativeAdmission;
assert freebsd.passthru.kernelSourceRevision == "833d39bd2e38421a14ea489a956261a0fa993fbc";
assert omnios.passthru.kernelSourceRevision == "6f87d0b5d63b957991dc9d4a01a7e6c95483282c";
assert freebsd.passthru.kernelSourceHash == packages.nativeKernels.pins.freebsd.hash;
assert omnios.passthru.kernelSourceHash == packages.nativeKernels.pins.illumos.hash;
assert builtins.match "[0-9a-f]{64}" freebsd.passthru.kernelPatchHash != null;
assert builtins.match "[0-9a-f]{64}" freebsd.passthru.kernelConfigurationHash != null;
assert builtins.match "[0-9a-f]{64}" omnios.passthru.kernelPatchHash != null;
assert builtins.match "[0-9a-f]{64}" omnios.passthru.kernelConfigurationHash != null;
assert omnios.passthru.illumosSdk.sourceRevision == "595bfdc217ae3cc19f982bc483701cdb89649a2d";
assert !omnios.passthru.illumosSdk.artifact.available;
assert omnios.passthru.illumosSdk.artifact.bytes == 0;
assert builtins.attrNames freebsd.passthru.kernelProvenance == [ "bytes" "compiler" "configuration_hash" "patch_hash" "sha256" "source_revision" ];
assert lib.hasInfix "#define OVERALLS_AF_VSOCK 45" (builtins.readFile packages.nativeKernels.freebsd.patch);
assert lib.hasInfix "uint8_t svm_len;" (builtins.readFile packages.nativeKernels.freebsd.patch);
assert lib.hasInfix "#define OVERALLS_AF_VSOCK 40" (builtins.readFile packages.nativeKernels.illumos.patch);
assert !(lib.hasInfix "svm_len" (builtins.readFile packages.nativeKernels.illumos.patch));
assert lib.hasInfix "test false = true" freebsdCommand;
assert lib.hasInfix "test false = true" omniosCommand;
assert lib.hasInfix "kernel:$kernel" freebsdCommand;
assert lib.hasInfix "kernel:$kernel" omniosCommand;
assert lib.hasInfix "web.archive.org/web/20250625173735" freebsd.passthru.sourceUrl;
assert freebsd.passthru.sourceHash == "sha256-5zyETu3q+WirvfHlcvXeC2tgKflH7Rvp4iIEp0qIaqw=";
assert lib.hasInfix "downloads.omnios.org/media/r151050" omnios.passthru.sourceUrl;
assert omnios.passthru.sourceHash == "sha256-787Bo109Vm7bEyjQd6VKgMHeKobdN+U73hL5bKXGi4s=";
assert lib.hasInfix "zstd -dc" omniosCommand;
assert lib.hasInfix "partitiontable.label == \"gpt\"" omniosCommand;
assert lib.hasInfix "select(.name == \"loader\")" omniosCommand;
assert lib.hasInfix "select(.name == \"zfs\")" omniosCommand;
assert lib.hasInfix "xz -dc" freebsdCommand;
assert lib.hasInfix "select(.name == \"efiesp\")" freebsdCommand;
assert lib.hasInfix "select(.name == \"rootfs\")" freebsdCommand;
assert lib.hasInfix "disk.raw" freebsdCommand;
assert lib.hasInfix "CLOUDHV.fd" freebsdCommand;
assert lib.hasInfix "firmware:{bytes:$firmware_bytes,sha256:$firmware_sha256}" freebsdCommand;
assert lib.hasInfix "root:{format:\"raw-gpt\",bytes:$root_bytes,sha256:$root_sha256}" freebsdCommand;
assert lib.hasInfix "version:6" freebsdCommand;
assert lib.hasInfix "os:\"freebsd\"" freebsdCommand;
assert lib.hasInfix "guest_agents:\"freebsd-v1\"" freebsdCommand;
assert lib.hasInfix "evidence/native-agents/freebsd" freebsdCommand;
assert lib.hasInfix "evidence/native-services/freebsd" freebsdCommand;
assert lib.hasInfix "overalls-native-readinessd" freebsdCommand;
# FreeBSD's immutable UFS root receives the complete installation payload from
# an offline ISO, with nuageinit configuration in the reserved cidata drive.
assert lib.hasInfix "mcopy -i" freebsdCommand;
assert lib.hasInfix "mformat -i \"$config_drive\" -v cidata ::" freebsdCommand;
assert lib.hasInfix "::user-data" freebsdCommand;
assert lib.hasInfix "/dev/gpt/efiesp" freebsdCommand;
assert lib.hasInfix "config-drive" freebsdCommand;
assert lib.hasInfix "mcopy" freebsdCommand;
assert lib.hasInfix "freebsd-user-data" freebsdCommand;
assert lib.hasInfix "xorriso -as mkisofs" freebsdCommand;
assert lib.hasInfix "freebsd-root.tar" freebsdCommand;
assert lib.hasInfix "/dev/iso9660/OVERALLS_NATIVE" freebsdCommand;
assert lib.hasInfix "/etc/overalls/kernel-build-id" freebsdCommand;
assert lib.hasInfix "/usr/local/etc/rc.d/overalls-native-agents" freebsdCommand;
assert lib.hasInfix "version:6" omniosCommand;
assert lib.hasInfix "os:\"illumos\"" omniosCommand;
assert lib.hasInfix "kind:\"firmware\",pci:true" omniosCommand;
assert lib.hasInfix "guest_agents:\"illumos-v1\"" omniosCommand;
# The pinned OmniOS image has no config drive and its ZFS root cannot be
# mutated by the Linux builder. Image construction remains blocked until an
# illumos libc SDK, patched kernel and SMF installation path are verified.
assert !(lib.hasInfix "evidence/native-agents/illumos" omniosCommand);
assert !(lib.hasInfix "evidence/native-services/illumos" omniosCommand);
assert !(lib.hasInfix "overalls-native-readinessd" omniosCommand);
assert lib.hasInfix "CLOUDHV.fd" omniosCommand;
assert lib.hasInfix "firmware:{bytes:$firmware_bytes,sha256:$firmware_sha256}" omniosCommand;
assert lib.hasInfix "root:{format:\"raw-gpt\",bytes:$root_bytes,sha256:$root_sha256}" omniosCommand;
assert lib.hasInfix "zstd -dc" illumosCommand;
assert lib.hasInfix "os:\"illumos\"" illumosCommand;
assert lib.hasInfix "guest_agents:\"illumos-v1\"" illumosCommand;
assert lib.hasInfix "root:{format:\"raw-gpt\",bytes:$root_bytes,sha256:$root_sha256}" illumosCommand;
# Target service scripts use native filesystem paths and exact PID markers;
# these source assertions do not establish target service-manager execution.
assert lib.hasInfix "#!/bin/sh" packages.nativeGuestAgents.freebsdSupervisor.text;
assert lib.hasInfix "printf '%s\\n'" packages.nativeGuestAgents.freebsdSupervisor.text;
assert lib.hasInfix "/usr/local/libexec/overalls-native-kernel-probed" packages.nativeGuestAgents.freebsdSupervisor.text;
assert lib.hasInfix "/opt/overalls/libexec/overalls-native-kernel-probed" packages.nativeGuestAgents.illumosSupervisor.text;
assert lib.hasInfix "supervise sshd" packages.nativeGuestAgents.freebsdSupervisor.text;
assert lib.hasInfix "supervise lilly-terminald" packages.nativeGuestAgents.freebsdSupervisor.text;
assert !(lib.hasInfix "/nix/store/" (plain packages.nativeGuestAgents.freebsdSupervisor.text));
pkgs.runCommand "native-os-guest-evaluation" { } ''
  test ${lib.escapeShellArg freebsd.name} = freebsd-evaluation
  test ${lib.escapeShellArg omnios.name} = omnios-evaluation
  test ${lib.escapeShellArg illumos.name} = illumos-evaluation
  touch "$out"
''
