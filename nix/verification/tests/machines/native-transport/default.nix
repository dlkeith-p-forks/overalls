{ pkgs, packages }:
let
  image = packages.freebsdTransportProbeImage;
  probeTools = pkgs.runCommand "overalls-native-transport-tools" {
    nativeBuildInputs = [ pkgs.python3 pkgs.ruff pkgs.ty ];
  } ''
    mkdir -p "$out" config
    cp ${../../../../../pyproject.toml} config/pyproject.toml
    cp ${../../support/native_transport.py} "$out/native_transport.py"
    cp ${../../support/native_transport_runner.py} "$out/native_transport_runner.py"
    ruff format --check --config config/pyproject.toml "$out"
    ruff check --config config/pyproject.toml "$out"
    ty check --project "$out" --python ${pkgs.python3}/bin/python3 --python-version 3.13 "$out"
  '';
in
assert !image.nativeAdmission;
# @cc [owner:ghuntley,label:verification] native-transport-machine-scope
# This check MUST boot the source-built FreeBSD kernel and test-only native
# listener through the actual patched Firecracker under nested KVM. It MUST
# verify the compiled transport token, host CID, refusals, reconnects and byte
# equality across credit-window boundaries. It MUST NOT claim native service,
# physical isolation, recovery or catalog admission acceptance.
pkgs.testers.runNixOSTest {
  name = "overalls-freebsd-native-transport";
  requiredFeatures.nested-kvm = true;
  globalTimeout = 900;
  nodes.host = { lib, ... }: {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;
    virtualisation.emptyDiskImages = [ 16384 ];
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    boot.kernelModules = [ "kvm" "kvm-intel" "kvm-amd" ];
    environment.systemPackages = [ pkgs.python3 pkgs.e2fsprogs pkgs.jq ];
    environment.etc."overalls-native-probe-image".source = image;
    environment.etc."native-transport-tools".source = probeTools;
  };
  testScript = ''
    vmm = "${packages.vmm}/bin/firecracker"
    build_id = "${image.kernel.buildId}"
  '' + builtins.readFile ./driver.py;
}
