{ pkgs, packages }:
let
  inherit (pkgs) lib;
  freebsd = packages.mkFreeBSDGuest { imageName = "freebsd-evaluation"; };
  omnios = packages.mkOmniOSGuest { imageName = "omnios-evaluation"; };
  illumos = packages.mkIllumosGuest { imageName = "illumos-evaluation"; };
  fleetImages = import ../../../fleet/guest-images.nix { overallsPackages = packages; };
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
assert toString omnios.passthru.firmware == toString packages.windowsFirmware.fd;
assert illumos.passthru.os == "illumos";
assert illumos.passthru.distribution == "OmniOS";
assert illumos.passthru.release == "r151050";
assert toString illumos.passthru.firmware == toString packages.windowsFirmware.fd;
assert illumos.passthru.upstreamUrl == "https://illumos.org/";
# Native kernels are currently source/patch receipts only.  Their constructors
# remain evaluable for provenance checks, but fleet admission must stay closed
# until a cross-built kernel and native machine evidence are recorded.
assert freebsd.passthru.kernelReady == false;
assert omnios.passthru.kernelReady == false;
assert freebsd.passthru.nativeAdmission == false;
assert omnios.passthru.nativeAdmission == false;
assert freebsdFleetImage == null;
assert illumosFleetImage == null;
assert lib.hasInfix "web.archive.org/web/20250625173735" freebsd.passthru.sourceUrl;
assert freebsd.passthru.sourceHash == "sha256-5zyETu3q+WirvfHlcvXeC2tgKflH7Rvp4iIEp0qIaqw=";
assert freebsd.passthru.kernelSourceRevision == "833d39bd2e38421a14ea489a956261a0fa993fbc";
assert freebsd.passthru.kernelReady == false;
assert builtins.match "[0-9a-f]{64}" freebsd.passthru.kernelPatchHash != null;
assert builtins.match "[0-9a-f]{64}" freebsd.passthru.kernelConfigurationHash != null;
assert lib.hasInfix "source_revision" freebsdCommand;
assert lib.hasInfix "downloads.omnios.org/media/r151050" omnios.passthru.sourceUrl;
assert omnios.passthru.sourceHash == "sha256-787Bo109Vm7bEyjQd6VKgMHeKobdN+U73hL5bKXGi4s=";
assert omnios.passthru.kernelSourceRevision == "edfc22bf3262825b4b63c15d0415f58f1ca34f1f";
assert omnios.passthru.kernelReady == false;
assert builtins.match "[0-9a-f]{64}" omnios.passthru.kernelPatchHash != null;
assert builtins.match "[0-9a-f]{64}" omnios.passthru.kernelConfigurationHash != null;
assert omnios.passthru.illumosSdk.sourceRevision == "595bfdc217ae3cc19f982bc483701cdb89649a2d";
assert omnios.passthru.illumosSdk.artifact.available == false;
assert omnios.passthru.illumosSdk.artifact.bytes == 0;
assert lib.hasInfix "source_revision" omniosCommand;
assert lib.hasInfix "zstd -dc" omniosCommand;
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
assert lib.hasInfix "kernel:$kernel" freebsdCommand;
assert lib.hasInfix "version:6" omniosCommand;
assert lib.hasInfix "os:\"illumos\"" omniosCommand;
assert lib.hasInfix "kind:\"firmware\",pci:true" omniosCommand;
assert lib.hasInfix "guest_agents:\"illumos-v1\"" omniosCommand;
assert lib.hasInfix "kernel:$kernel" omniosCommand;
assert lib.hasInfix "CLOUDHV.fd" omniosCommand;
assert lib.hasInfix "firmware:{bytes:$firmware_bytes,sha256:$firmware_sha256}" omniosCommand;
assert lib.hasInfix "root:{format:\"raw-gpt\",bytes:$root_bytes,sha256:$root_sha256}" omniosCommand;
assert lib.hasInfix "zstd -dc" illumosCommand;
assert lib.hasInfix "os:\"illumos\"" illumosCommand;
assert lib.hasInfix "guest_agents:\"illumos-v1\"" illumosCommand;
assert lib.hasInfix "root:{format:\"raw-gpt\",bytes:$root_bytes,sha256:$root_sha256}" illumosCommand;
pkgs.runCommand "native-os-guest-evaluation" { } ''
  test ${lib.escapeShellArg freebsd.name} = freebsd-evaluation
  test ${lib.escapeShellArg omnios.name} = omnios-evaluation
  test ${lib.escapeShellArg illumos.name} = illumos-evaluation
  touch "$out"
''
