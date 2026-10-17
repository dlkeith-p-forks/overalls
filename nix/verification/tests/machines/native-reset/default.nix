{ pkgs, packages }:
let
  probes = import ../../evaluation/native-reset-probes.nix { inherit pkgs packages; };
  image = packages.mkFreeBSDImageCandidate {
    extraRoot = pkgs.runCommand "overalls-test-only-freebsd-reset-root" {} ''
      install -D -m 0555 ${probes}/bin/freebsd-reset-probe "$out/usr/local/libexec/overalls-native-reset-probe"
    '';
    runtimeRcLocal = pkgs.writeText "overalls-test-only-freebsd-reset-rc.local" ''
      #!/bin/sh
      exec /usr/local/libexec/overalls-native-reset-probe
    '';
  };
  tools = pkgs.runCommand "overalls-native-reset-tools" {
    nativeBuildInputs = [ pkgs.python313 pkgs.ruff pkgs.ty ];
  } ''
    mkdir -p "$out" config
    cp ${../../../../../pyproject.toml} config/pyproject.toml
    cp ${../../support/native_reset.py} "$out/native_reset.py"
    ruff format --check --config config/pyproject.toml "$out"
    ruff check --config config/pyproject.toml "$out"
    ty check --project "$out" --python ${pkgs.python313}/bin/python3.13 --python-version 3.13 "$out"
  '';
in
assert !image.nativeAdmission;
# @cc [owner:ghuntley,label:verification;security] native-reset-machine-scope
# A disposable nested-KVM PCI guest MUST hold pending accept/read/write and a
# peerless live socket before the private fixture API pauses, takes a full
# snapshot and resumes it. Serial evidence MUST prove the peerless identity
# option fails and the pending operations wake with errors. FreeBSD MUST refuse
# new sockets until a replacement VM. The writable disk and saved memory MUST
# remain disposable; this gate MUST NOT claim DMA, physical-host, clean service,
# crash recovery or native admission acceptance.
pkgs.testers.runNixOSTest {
  name = "overalls-freebsd-native-reset";
  requiredFeatures.nested-kvm = true;
  globalTimeout = 600;
  nodes.host = { lib, ... }: {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;
    virtualisation.emptyDiskImages = [ 16384 ];
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    boot.kernelModules = [ "kvm" "kvm-intel" "kvm-amd" ];
    environment.systemPackages = [ pkgs.python313 pkgs.e2fsprogs pkgs.jq ];
    environment.etc."native-reset-image".source = image;
    environment.etc."native-reset-tools".source = tools;
    environment.etc."native-reset-probes".source = probes;
  };
  testScript = ''
    vmm = "${packages.vmm}/bin/firecracker"
  '' + builtins.readFile ./driver.py;
}
