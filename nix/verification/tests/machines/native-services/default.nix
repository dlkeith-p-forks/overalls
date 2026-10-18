{ pkgs, packages, image ? packages.freebsdImageCandidate, osName ? "freebsd"
, isolation ? false, growth ? false, recovery ? false, crash ? false
, transport ? false, transportReset ? false, transportProbe ? null
, transportBuildId ? "", github ? false }:
let
  scenario = if github then "github-retained" else if transportReset then "transport-reset" else if transport then "ordinary-transport" else if isolation then "isolation" else if growth then "growth" else if recovery then "recovery" else if crash then "crash-recovery" else "services";
  tools = pkgs.runCommand "overalls-native-service-tools" {
    nativeBuildInputs = [ pkgs.python3 pkgs.ruff pkgs.ty ];
  } ''
    mkdir -p "$out" config
    cp ${../../../../../pyproject.toml} config/pyproject.toml
    cp ${../../support/native_services.py} "$out/native_services.py"
    cp ${../../support/native_control.py} "$out/native_control.py"
    cp ${../../support/native_git_fixture.py} "$out/native_git_fixture.py"
    cp ${../../support/native_github_fixture.py} "$out/native_github_fixture.py"
    cp ${../../support/native_growth_oracle.py} "$out/native_growth_oracle.py"
    cp ${../../support/native_fat_oracle.py} "$out/native_fat_oracle.py"
    cp ${../../support/native_omnios_growth_oracle.py} "$out/native_omnios_growth_oracle.py"
    cp ${../../support/native_service_runner.py} "$out/native_service_runner.py"
    ${pkgs.lib.optionalString recovery ''
      cp ${../../support/native_recovery.py} "$out/native_recovery.py"
    ''}
    ${pkgs.lib.optionalString crash ''
      cp ${../../support/native_crash_recovery.py} "$out/native_crash_recovery.py"
    ''}
    ${pkgs.lib.optionalString isolation ''
      cp ${../../support/native_isolation.py} "$out/native_isolation.py"
      cp ${../../support/native_tcp_probe.py} "$out/native_tcp_probe.py"
    ''}
    ${pkgs.lib.optionalString (transport || transportReset) ''
      cp ${../../support/native_reset.py} "$out/native_reset.py"
      cp ${../../support/native_transport.py} "$out/native_transport.py"
      cp ${../../support/native_ordinary_transport.py} "$out/native_ordinary_transport.py"
    ''}
    ${pkgs.lib.optionalString transportReset ''
      cp ${../../support/native_omnios_reset_runner.py} "$out/native_omnios_reset_runner.py"
    ''}
    ruff format --check --config config/pyproject.toml "$out"
    ruff check --config config/pyproject.toml "$out"
    ty check --project "$out" --python ${pkgs.python3}/bin/python3 --python-version 3.13 "$out"
  '';
  fixture = pkgs.runCommand "overalls-native-service-isolated-authority" {
    nativeBuildInputs = [ pkgs.openssl pkgs.openssh ];
  } ''
    mkdir -p "$out"
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 36500 \
      -subj '/CN=Overalls native isolated fixture' \
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
in
assert github || !image.nativeAdmission;
assert builtins.elem osName [ "freebsd" "illumos" ];
assert (!transport && !transportReset) || (osName == "illumos" && transportProbe != null && builtins.match "[0-9a-f]{64}" transportBuildId != null);
assert pkgs.lib.count (enabled: enabled) [ isolation growth recovery crash transport transportReset github ] <= 1;
# @cc [owner:ghuntley,label:verification;security] native-service-machine-boundary
# The actual native image MUST bootstrap against isolated MMDS in nested KVM
# and answer the host-only daemon protocols. Missing SSH authority MUST withhold
# readiness. SSH/execution MUST use only the isolated synthetic authority; clean
# reboot MUST rotate boot identity and refuse stale metadata. These results MUST
# NOT grant native admission. The base service receipt MUST NOT claim crash
# recovery. Only the optional
# isolation variant may establish its explicit native IPv4 routing/guard scope;
# it MUST NOT claim jail, physical-host or multi-host isolation.
# The growth variant MUST retain one root through three verified clean exits,
# perform two host-side expansions and check native root-capacity increases,
# nonroot bytes and an untouched foreign disk without granting crash recovery.
# The recovery variant MUST kill an actual native daemon, keep readiness
# withheld while it cannot restart, restore the exact executable mode and
# verify a replacement daemon with the same boot identity and protocol.
# The crash variant MUST observe a first-boot VMM SIGKILL, restart the same
# disk under fresh boot authority, verify retained synchronized data and native
# filesystem recovery, and finish with a verified clean exit. Its separate
# receipt MUST NOT claim interrupted-write durability or physical recovery.
# Ordinary transport MUST run only an external test probe after a complete
# production-service baseline, stop production listeners for its exact socket
# capacity checks and restore the same boot before two verified clean exits.
# Reset transport MUST observe an actual private VMM event after that baseline
# and dispose its VM after independent serial verification; it MUST NOT create
# an ordinary service receipt or claim restored service or clean shutdown.
# The GitHub variant MUST use only a disposable copy of the retained image,
# bootstrap public verified tools through its existing executor and exercise
# actual personal-UID gh, Git and LFS before and after clean reboot. Its separate
# receipt MUST NOT change native admission or claim SQL broker authorization.
pkgs.testers.runNixOSTest {
  name = "overalls-${osName}-native-${scenario}";
  requiredFeatures.nested-kvm = true;
  globalTimeout = if growth || crash then 1500 else 900;
  nodes.host = { lib, ... }: {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;
    virtualisation.emptyDiskImages = [ 16384 ];
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    boot.kernelModules = [ "kvm" "kvm-intel" "kvm-amd" "tun" ];
    environment.systemPackages = [ pkgs.python3 pkgs.e2fsprogs pkgs.jq pkgs.iproute2 pkgs.iputils pkgs.openssh pkgs.git ]
      ++ pkgs.lib.optionals growth [ pkgs.util-linux pkgs.mtools ]
      ++ pkgs.lib.optionals isolation [ pkgs.nftables pkgs.util-linux
        (pkgs.writeShellScriptBin "native-isolation-prepare" ''
          set -euo pipefail
          export ERL_FLAGS="+S 2:2" RELEASE_COOKIE=isolated-native-network RELEASE_DISTRIBUTION=none
          export RELEASE_TMP=/run/native-policy-release
          mkdir -p "$RELEASE_TMP"
          ${packages.lilly}/bin/lilly eval 'Code.eval_file("${../native-isolation/prepare.exs}")'
        '')
      ];
    environment.etc."overalls-native-service-image".source = image;
    environment.etc."native-service-tools".source = tools;
    environment.etc."native-service-fixture".source = fixture;
    environment.etc."native-github-tools" = lib.mkIf github {
      source = packages.githubTools.release;
    };
    environment.etc."native-github-executors" = lib.mkIf github {
      source = packages.githubBootstrapRelease;
    };
    environment.etc."native-transport-probe" = lib.mkIf (transport || transportReset) {
      source = transportProbe;
    };
    networking.firewall.trustedInterfaces = [ "native0" ];
    boot.kernel.sysctl."net.ipv4.ip_forward" = 0;
  };
  testScript = ''
    vmm = "${packages.vmm}/bin/firecracker"
    os_name = "${osName}"
    build_id = "${transportBuildId}"
    growth = ${if growth then "True" else "False"}
    recovery = ${if recovery then "True" else "False"}
    crash = ${if crash then "True" else "False"}
    github = ${if github then "True" else "False"}
    service_runner = "${if recovery then "native_recovery.py" else if crash then "native_crash_recovery.py" else "native_service_runner.py"}"
  '' + builtins.readFile (
    if transportReset then ./omnios-reset-driver.py
    else if transport then ./ordinary-transport-driver.py
    else if isolation then ../native-isolation/driver.py
    else ./driver.py
  );
}
