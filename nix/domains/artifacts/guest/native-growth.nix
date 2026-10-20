{ pkgs, lyra }:
let
  kernels = import ./native-kernels { inherit pkgs; };
  abiCheck = pkgs.runCommand "overalls-native-root-growth-abi" {
    nativeBuildInputs = [ pkgs.zig ];
  } ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
    cat > freebsd.c <<'C'
    #include <stddef.h>
    #include "${kernels.freebsdSource}/sys/sys/disk.h"
    _Static_assert(sizeof(off_t) == 8, "off_t");
    _Static_assert(sizeof(u_int) == 4, "u_int");
    _Static_assert(DIOCGMEDIASIZE == 0x40086481, "media size ioctl");
    _Static_assert(DIOCGSECTORSIZE == 0x40046480, "sector size ioctl");
    /* lyra native_guest flush_disk_cache hardcodes this request. */
    _Static_assert(DIOCGFLUSH == 0x20006487, "cache flush ioctl");
    int overalls_growth_abi(void) { return 0; }
    C
    zig cc -target x86_64-freebsd -std=c11 -Wall -Wextra -Werror -c freebsd.c -o freebsd.o
    cat > illumos.c <<'C'
    #include <stddef.h>
    #include <sys/types.h>
    #include <sys/dkio.h>
    _Static_assert(DKIOCGMEDIAINFO == 0x42a, "media info ioctl");
    _Static_assert(sizeof(struct dk_minfo) == 16, "media info size");
    _Static_assert(_Alignof(struct dk_minfo) == 8, "media info alignment");
    _Static_assert(offsetof(struct dk_minfo, dki_media_type) == 0, "media type offset");
    _Static_assert(offsetof(struct dk_minfo, dki_lbsize) == 4, "sector size offset");
    _Static_assert(offsetof(struct dk_minfo, dki_capacity) == 8, "capacity offset");
    _Static_assert(sizeof(((struct dk_minfo *)0)->dki_capacity) == 8, "capacity width");
    int overalls_growth_abi(void) { return 0; }
    C
    ${lyra.native.illumosSdk.compiler}/bin/illumos-clang -std=c11 -D__EXTENSIONS__ \
      -Wall -Wextra -Werror -c illumos.c -o illumos.o
    touch "$out"
  '';
  freebsdRc = pkgs.writeText "overalls-native-growth-freebsd.rc" ''
    #!/bin/sh
    # PROVIDE: overalls_native_growth
    # REQUIRE: FILESYSTEMS cleanvar
    # BEFORE: overalls_native_bootstrap
    . /etc/rc.subr
    name="overalls_native_growth"
    rcvar="overalls_native_growth_enable"
    command="/usr/local/libexec/overalls-native-grow-root"
    load_rc_config "$name"
    : "''${overalls_native_growth_enable:=NO}"
    run_rc_command "$1"
  '';
  illumosManifest = pkgs.writeText "overalls-native-growth-illumos.xml" ''
    <?xml version="1.0"?>
    <!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
    <service_bundle type="manifest" name="overalls-native-growth">
      <service name="site/overalls-native-growth" type="service" version="1">
        <create_default_instance enabled="true"/>
        <single_instance/>
        <dependency name="local-filesystem" grouping="require_all" restart_on="none" type="service">
          <service_fmri value="svc:/system/filesystem/local:default"/>
        </dependency>
        <method_context><method_credential user="root" group="root"/></method_context>
        <exec_method type="method" name="start" exec="/opt/overalls/libexec/overalls-native-grow-root" timeout_seconds="360"/>
        <exec_method type="method" name="stop" exec=":true" timeout_seconds="30"/>
        <property_group name="startd" type="framework">
          <propval name="duration" type="astring" value="transient"/>
        </property_group>
        <stability value="Unstable"/>
        <template><common_name><loctext xml:lang="C">Overalls mounted root growth</loctext></common_name></template>
      </service>
    </service_bundle>
  '';
  # @cc [owner:ghuntley,label:security;recovery] native-growth-service-order
  # Both native roots MUST run the no-argument mounted-root helper on every
  # boot after writable local filesystems and before network bootstrap. The
  # FreeBSD firstboot growfs path MUST be disabled; bootstrap MUST require the
  # helper's current volatile success receipt even when rcorder continues after
  # a failed service. Installation alone MUST NOT establish growth acceptance.
  tree = os: pkgs.runCommand "overalls-${os}-native-growth" { } ''
    test -f ${abiCheck}
    ${if os == "freebsd" then ''
      mkdir -p "$out/usr/local/libexec" "$out/usr/local/etc/rc.d" "$out/etc/rc.conf.d"
      install -m 0755 ${lyra.native}/bin/x86_64-unknown-freebsd-overalls-native-grow-root "$out/usr/local/libexec/overalls-native-grow-root"
      install -m 0755 ${freebsdRc} "$out/usr/local/etc/rc.d/overalls_native_growth"
      printf '%s\n' 'overalls_native_growth_enable="YES"' > "$out/etc/rc.conf.d/overalls_native_growth"
      printf '%s\n' 'growfs_enable="NO"' > "$out/etc/rc.conf.d/growfs"
    '' else ''
      mkdir -p "$out/opt/overalls/libexec" "$out/lib/svc/manifest/site"
      install -m 0755 ${lyra.native}/bin/x86_64-unknown-illumos-overalls-native-grow-root "$out/opt/overalls/libexec/overalls-native-grow-root"
      install -m 0644 ${illumosManifest} "$out/lib/svc/manifest/site/overalls-native-growth.xml"
    ''}
  '';
in
{
  inherit abiCheck;
  freebsd = tree "freebsd";
  illumos = tree "illumos";
}
