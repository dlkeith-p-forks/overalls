{ pkgs, lyra }:
let
  # @cc [owner:ghuntley,label:security] native-agent-set-complete
  # Every binary listed here MUST be cross-built for the selected native OS;
  # the image builder MUST never copy the Linux Lyra closure into a native
  # root. Services start trust, roster and identity prerequisites before
  # readiness can answer on the host-only vsock channel.
  # The release derivation type-checks and cross-builds the same protocol
  # daemons for both libc families. Keep the image package explicit so a
  # FreeBSD image cannot accidentally receive an illumos service manifest.
  binaries = [
    "overalls-native-kernel-probed"
    "overalls-native-agentd"
    "overalls-native-flushd"
    "overalls-native-readinessd"
    "overalls-native-trustd"
    "overalls-native-workspaced"
    "overalls-ssh-authorize"
    "overalls-host-certificate"
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
    export OVERALLS_SSH_CA_BUNDLE=/etc/ssl/cert.pem
    mkdir -p /var/run/overalls
    ${freebsdBinaries}/bin/overalls-native-kernel-probed &
    ${freebsdBinaries}/bin/overalls-native-agentd &
    ${freebsdBinaries}/bin/overalls-native-flushd &
    ${freebsdBinaries}/bin/overalls-native-readinessd &
    ${freebsdBinaries}/bin/overalls-native-trustd &
    ${freebsdBinaries}/bin/overalls-native-workspaced &
    # SSH remains closed until the private roster and per-boot host
    # certificate have both been reconciled. The helpers emit only their
    # reviewed fixed event names; their request and key bytes never enter logs.
    if ${freebsdBinaries}/bin/overalls-ssh-authorize sync &&
       ${freebsdBinaries}/bin/overalls-host-certificate; then
      /usr/sbin/sshd 2>/dev/null || true
    fi
  '';
  illumosService = pkgs.writeShellScript "overalls-native-agents-start" ''
    set -eu
    export OVERALLS_SSH_CA_BUNDLE=/etc/ssl/cacert.pem
    mkdir -p /var/run/overalls
    ${illumosBinaries}/bin/overalls-native-kernel-probed &
    ${illumosBinaries}/bin/overalls-native-agentd &
    ${illumosBinaries}/bin/overalls-native-flushd &
    ${illumosBinaries}/bin/overalls-native-readinessd &
    ${illumosBinaries}/bin/overalls-native-trustd &
    ${illumosBinaries}/bin/overalls-native-workspaced &
    if ${illumosBinaries}/bin/overalls-ssh-authorize sync &&
       ${illumosBinaries}/bin/overalls-host-certificate; then
      /usr/lib/ssh/sshd -f /etc/ssh/sshd_config 2>/dev/null || true
    fi
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
    # Terminal support is deliberately omitted until a FreeBSD/illumos
    # terminald target is built and exercised.  Keep the native capability row
    # fail-closed rather than letting the presence of the other daemons imply
    # an unimplemented PTY service.
    capabilities = [ "readiness" "trust" "workspace" "flush" "ssh" "agents" ];
  };
}
