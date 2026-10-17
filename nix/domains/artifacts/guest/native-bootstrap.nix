{ pkgs, lyra }:
let
  growth = import ./native-growth.nix { inherit pkgs lyra; };
  freebsdRc = pkgs.writeText "overalls-native-bootstrap-freebsd.rc" ''
    #!/bin/sh
    # PROVIDE: overalls_native_bootstrap
    # REQUIRE: NETWORKING cleanvar overalls_native_growth
    # BEFORE: overalls_native_agents
    # KEYWORD: shutdown
    . /etc/rc.subr
    name="overalls_native_bootstrap"
    rcvar="overalls_native_bootstrap_enable"
    command="/usr/local/libexec/overalls-native-bootstrap"
    load_rc_config "$name"
    : "''${overalls_native_bootstrap_enable:=NO}"
    run_rc_command "$1"
  '';
  illumosManifest = pkgs.writeText "overalls-native-bootstrap-illumos.xml" ''
    <?xml version="1.0"?>
    <!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
    <service_bundle type="manifest" name="overalls-native-bootstrap">
      <service name="site/overalls-native-bootstrap" type="service" version="1">
        <create_default_instance enabled="true"/>
        <single_instance/>
        <dependency name="local-filesystem" grouping="require_all" restart_on="none" type="service">
          <service_fmri value="svc:/system/filesystem/local:default"/>
        </dependency>
        <dependency name="physical-network" grouping="require_all" restart_on="error" type="service">
          <service_fmri value="svc:/network/physical:default"/>
        </dependency>
        <dependency name="root-growth" grouping="require_all" restart_on="error" type="service">
          <service_fmri value="svc:/site/overalls-native-growth:default"/>
        </dependency>
        <method_context>
          <method_credential user="root" group="root"/>
        </method_context>
        <exec_method type="method" name="start" exec="/opt/overalls/libexec/overalls-native-bootstrap" timeout_seconds="360"/>
        <exec_method type="method" name="stop" exec=":true" timeout_seconds="30"/>
        <property_group name="startd" type="framework">
          <propval name="duration" type="astring" value="transient"/>
        </property_group>
        <stability value="Unstable"/>
        <template>
          <common_name><loctext xml:lang="C">Overalls native MMDS network bootstrap</loctext></common_name>
        </template>
      </service>
    </service_bundle>
  '';
  resolv = pkgs.writeText "overalls-native-resolv.conf" ''
    nameserver 1.1.1.1
    nameserver 9.9.9.9
  '';
  # @cc [owner:ghuntley,label:build;security] native-bootstrap-service-root
  # Each native bootstrap tree MUST carry its cross-built OS-specific helper
  # and service definition. Image assembly MUST disable DHCP and automatic
  # network configuration and order all native agents after this bootstrap.
  # The helper's successful exit establishes configured boot identity only;
  # it MUST NOT grant native catalog admission or daemon readiness.
  tree = os: pkgs.runCommand "overalls-${os}-native-bootstrap" { } ''
    cp -a ${growth.${os}}/. "$out/"
    chmod -R u+w "$out"
    mkdir -p "$out/etc"
    install -m 0644 ${resolv} "$out/etc/resolv.conf"
    ${if os == "freebsd" then ''
      mkdir -p "$out/usr/local/libexec" "$out/usr/local/etc/rc.d" "$out/etc/rc.conf.d"
      install -m 0755 ${lyra.native}/bin/x86_64-unknown-freebsd-overalls-native-bootstrap "$out/usr/local/libexec/overalls-native-bootstrap"
      install -m 0755 ${freebsdRc} "$out/usr/local/etc/rc.d/overalls_native_bootstrap"
      printf '%s\n' 'overalls_native_bootstrap_enable="YES"' > "$out/etc/rc.conf.d/overalls_native_bootstrap"
      printf '%s\n' 'cleanvar_enable="YES"' > "$out/etc/rc.conf.d/cleanvar"
    '' else ''
      mkdir -p "$out/opt/overalls/libexec" "$out/lib/svc/manifest/site"
      install -m 0755 ${lyra.native}/bin/x86_64-unknown-illumos-overalls-native-bootstrap "$out/opt/overalls/libexec/overalls-native-bootstrap"
      install -m 0644 ${illumosManifest} "$out/lib/svc/manifest/site/overalls-native-bootstrap.xml"
    ''}
  '';
in
{
  freebsd = tree "freebsd";
  illumos = tree "illumos";
}
