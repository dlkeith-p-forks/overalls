{ pkgs, lyra }:
let
  # The release derivation type-checks and cross-builds the same protocol
  # daemons for both libc families. Keep the image package explicit so a
  # FreeBSD image cannot accidentally receive an illumos service manifest.
  binaries = [
    "overalls-native-readinessd"
    "overalls-native-trustd"
    "overalls-native-workspaced"
  ];
  copy = os: pkgs.runCommand "overalls-${os}-guest-agent-binaries" { } ''
    mkdir -p "$out/bin"
    ${pkgs.lib.concatMapStringsSep "\n" (binary: ''
      install -D -m 0755 ${lyra}/bin/x86_64-unknown-${if os == "freebsd" then "freebsd" else "illumos"}-${binary} "$out/bin/${binary}"
    '') binaries}
  '';
  freebsdBinaries = copy "freebsd";
  illumosBinaries = copy "illumos";
  freebsdRc = pkgs.writeText "overalls-native-agents-freebsd.rc" ''
    # Native Overalls guest daemons. The boot-id file is volatile and is
    # recreated before any boot-bound protocol listener starts.
    overalls_native_boot_id="/var/run/overalls/boot-id"
    overalls_native_agents_enable="YES"
  '';
  illumosManifest = pkgs.writeText "overalls-native-agents-illumos.xml" ''
    <?xml version="1.0"?>
    <!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
    <service_bundle type="manifest" name="overalls-native-agents">
      <service name="site/overalls-native-agents" type="service" version="1">
        <create_default_instance enabled="true"/>
        <single_instance/>
        <dependency name="multi-user" grouping="require_all" restart_on="error" type="service"
          value="milestone/multi-user"/>
        <exec_method type="method" name="start" exec="%{config/usr}/lib/overalls/native-agents-start" timeout_seconds="30"/>
        <exec_method type="method" name="stop" exec=":kill" timeout_seconds="30"/>
        <stability value="Uncommitted"/>
        <template>
          <common_name><loctext xml:lang="C">Overalls native guest agents</loctext></common_name>
        </template>
      </service>
    </service_bundle>
  '';
  freebsdService = pkgs.writeShellScript "overalls-native-agents-freebsd" ''
    # rc.d invokes fixed binaries and never forwards request data to a shell.
    set -eu
    : "''${overalls_native_agents_enable:=NO}"
    [ "$overalls_native_agents_enable" = YES ] || exit 0
    mkdir -p /var/run/overalls
    ${freebsdBinaries}/bin/overalls-native-readinessd &
    ${freebsdBinaries}/bin/overalls-native-trustd &
    ${freebsdBinaries}/bin/overalls-native-workspaced &
  '';
  illumosService = pkgs.writeShellScript "overalls-native-agents-start" ''
    set -eu
    mkdir -p /var/run/overalls
    ${illumosBinaries}/bin/overalls-native-readinessd &
    ${illumosBinaries}/bin/overalls-native-trustd &
    ${illumosBinaries}/bin/overalls-native-workspaced &
  '';
  freebsd = pkgs.runCommand "overalls-freebsd-guest-agents" {} ''
    mkdir -p "$out/bin" "$out/etc/rc.d" "$out/etc/rc.conf.d"
    cp -a ${freebsdBinaries}/bin/. "$out/bin/"
    install -m 0755 ${freebsdService} "$out/etc/rc.d/overalls-native-agents"
    install -m 0644 ${freebsdRc} "$out/etc/rc.conf.d/overalls-native-agents"
  '';
  illumos = pkgs.runCommand "overalls-illumos-guest-agents" {} ''
    mkdir -p "$out/bin" "$out/lib/svc/manifest/site" "$out/lib/overalls"
    cp -a ${illumosBinaries}/bin/. "$out/bin/"
    install -m 0644 ${illumosManifest} "$out/lib/svc/manifest/site/overalls-native-agents.xml"
    install -m 0755 ${illumosService} "$out/lib/overalls/native-agents-start"
  '';
in
{
  inherit freebsd illumos freebsdRc freebsdService illumosManifest illumosService;
  manifest = {
    version = 1;
    agents = binaries;
    capabilities = [ "readiness" "trust" "workspace" "flush" "ssh" "agents" ];
  };
}
