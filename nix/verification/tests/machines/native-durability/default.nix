{ pkgs, packages, scenario, image ? packages.freebsdImageCandidate, osName ? "freebsd"
, allowNativeAdmission ? false }:
let
  tools = pkgs.runCommand "overalls-native-durability-tools" {
    nativeBuildInputs = [ pkgs.python3 pkgs.ruff pkgs.ty ];
  } ''
    mkdir -p "$out" config
    cp ${../../../../../pyproject.toml} config/pyproject.toml
    for name in native_services native_control native_git_fixture native_github_fixture \
      native_growth_oracle native_fat_oracle native_omnios_growth_oracle \
      native_service_runner native_crash_recovery native_durability native_write_log; do
      cp ${../../support}/$name.py "$out/$name.py"
    done
    ruff format --check --config config/pyproject.toml "$out"
    ruff check --config config/pyproject.toml "$out"
    ty check --project "$out" --python ${pkgs.python3}/bin/python3 --python-version 3.13 "$out"
  '';
  fixture = pkgs.runCommand "overalls-native-durability-authority" {
    nativeBuildInputs = [ pkgs.openssl pkgs.openssh ];
  } ''
    mkdir -p "$out"
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 36500 \
      -subj '/CN=Overalls native durability fixture' \
      -addext 'basicConstraints=critical,CA:TRUE' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -keyout "$out/ca.key" -out "$out/ca.pem" 2>/dev/null
    openssl req -new -newkey rsa:2048 -nodes -sha256 \
      -subj '/CN=ssh.integration.internal' \
      -addext 'subjectAltName=DNS:ssh.integration.internal,DNS:llm.internal,DNS:github.com,DNS:com-github.integration.internal' \
      -addext 'basicConstraints=critical,CA:FALSE' \
      -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
      -addext 'extendedKeyUsage=serverAuth' \
      -keyout "$out/tls.key" -out tls.csr 2>/dev/null
    openssl x509 -req -in tls.csr -CA "$out/ca.pem" -CAkey "$out/ca.key" \
      -CAcreateserial -days 36500 -sha256 -copy_extensions copy \
      -out "$out/tls.pem" 2>/dev/null
    for name in ssh-ca user wrong-user; do
      ssh-keygen -q -t ed25519 -N "" -C "" -f "$out/$name"
    done
  '';
  relocation = scenario == "relocation";
  powerLoss = scenario == "power-loss";
  node = hostId: { config, lib, ... }: {
    system.stateVersion = "26.05";
    networking.hostId = hostId;
    boot.supportedFilesystems = [ "zfs" ];
    boot.extraModprobeConfig = "options zfs zfs_arc_max=268435456";
    boot.kernelModules = [ "kvm" "kvm-intel" "kvm-amd" "tun" ]
      ++ lib.optionals powerLoss [ "dm-log-writes" ];
    systemd.services.zfs-zed.enable = false;
    virtualisation.memorySize = 6144;
    virtualisation.cores = 4;
    # vdb: private work root; vdc: host ZFS pool (or its dm-log-writes data
    # device); vdd: dm-log-writes journal; vde: power-cut replay target.
    virtualisation.emptyDiskImages = [ 8192 20480 ] ++ lib.optionals powerLoss [ 32768 20480 ];
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    environment.systemPackages = [
      config.boot.zfs.package pkgs.python3 pkgs.e2fsprogs pkgs.jq pkgs.iproute2 pkgs.iputils
      pkgs.openssh pkgs.git pkgs.util-linux pkgs.strace pkgs.socat pkgs.lvm2
    ];
    environment.etc."overalls-native-image".source = image;
    environment.etc."native-durability-tools".source = tools;
    environment.etc."native-durability-fixture".source = fixture;
    networking.firewall.trustedInterfaces = [ "native0" "eth1" ];
    boot.kernel.sysctl."net.ipv4.ip_forward" = 0;
  };
in
assert allowNativeAdmission || !image.nativeAdmission;
assert builtins.elem osName [ "freebsd" "illumos" ];
assert builtins.elem scenario [ "interrupted-growth" "power-loss" "relocation" ];
# @cc [owner:ghuntley,label:verification;recovery] native-durability-machine-boundary
# Each scenario MUST boot the actual native image in nested KVM with Lilly's
# production drive cache mode on a disk file inside a host ZFS dataset.
# Interrupted growth MUST SIGKILL the VMM at traced growth writes and recover
# a consistent, grown root. Power loss MUST place the host pool on dm-log-writes
# and boot only the journal prefix before the cut, so unflushed host and device
# state is discarded. Relocation MUST move a stopped guest between two hosts by
# ZFS send/receive and boot it under a new placement. Receipts MUST remain
# native_admission=false and MUST NOT claim Lilly or Marshall orchestration.
pkgs.testers.runNixOSTest {
  name = "overalls-${osName}-native-${scenario}";
  requiredFeatures.nested-kvm = true;
  globalTimeout = 3600;
  nodes = { host = node "aabbcc01"; }
    // pkgs.lib.optionalAttrs relocation { destination = node "aabbcc02"; };
  testScript = ''
    vmm = "${packages.vmm}/bin/firecracker"
    os_name = "${osName}"
    scenario = "${scenario}"
  '' + builtins.readFile ./common.py + builtins.readFile (
    if relocation then ./relocation.py else if powerLoss then ./power-loss.py else ./growth.py
  );
}
