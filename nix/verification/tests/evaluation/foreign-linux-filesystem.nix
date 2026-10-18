{ pkgs, packages }:
let
  inherit (pkgs) lib;
  privateServiceRoots = [ ../../../../secrets/private-services-root.pem ../../../../secrets/brady-root.pem ];
  images = {
    arch = packages.mkArchGuest { inherit privateServiceRoots; };
    almalinux = packages.mkAlmaLinuxGuest { inherit privateServiceRoots; };
  };
  expectedModes = {
    "/usr/lib/systemd/systemd" = "0755";
    "/usr/bin/bash" = "0755";
    "/usr/lib/os-release" = "0644";
    "/usr/bin/sudo" = "04755";
    "/etc/shadow" = "0600";
    "/etc/gshadow" = "0600";
  };
  almaResolverFiles = {
    "/usr/lib/systemd/system/systemd-resolved.service" = "${pkgs.systemd}/example/systemd/system/systemd-resolved.service";
    "/usr/lib/systemd/system/systemd-resolved-varlink.socket" = "${pkgs.systemd}/example/systemd/system/systemd-resolved-varlink.socket";
    "/usr/lib/systemd/system/systemd-resolved-monitor.socket" = "${pkgs.systemd}/example/systemd/system/systemd-resolved-monitor.socket";
    "/usr/lib/sysusers.d/systemd-resolve.conf" = "${pkgs.systemd}/example/sysusers.d/systemd-resolve.conf";
    "/usr/share/dbus-1/system.d/org.freedesktop.resolve1.conf" = "${pkgs.systemd}/share/dbus-1/system.d/org.freedesktop.resolve1.conf";
    "/usr/share/dbus-1/system-services/org.freedesktop.resolve1.service" = "${pkgs.systemd}/share/dbus-1/system-services/org.freedesktop.resolve1.service";
    "/etc/systemd/system/overalls-resolved-identity.service" = pkgs.writeText "expected-resolver-identity.service" ''
      [Unit]
      Description=Create the private DNS resolver service identity
      DefaultDependencies=no
      After=systemd-remount-fs.service systemd-sysusers.service
      Before=sysinit.target systemd-resolved.service dbus.socket dbus.service dbus-broker.service
      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=${pkgs.systemd}/bin/systemd-sysusers /usr/lib/sysusers.d/systemd-resolve.conf
      [Install]
      WantedBy=sysinit.target
    '';
    "/etc/systemd/system/systemd-resolved.service.d/identity.conf" = pkgs.writeText "expected-resolver-identity.conf" ''
      [Unit]
      Requires=overalls-resolved-identity.service
      After=overalls-resolved-identity.service
    '';
  };
  almaResolverLinks = {
    "/etc/systemd/system/dbus-org.freedesktop.resolve1.service" = "/usr/lib/systemd/system/systemd-resolved.service";
    "/etc/systemd/system/multi-user.target.wants/systemd-resolved.service" = "/usr/lib/systemd/system/systemd-resolved.service";
    "/etc/systemd/system/sockets.target.wants/systemd-resolved-varlink.socket" = "/usr/lib/systemd/system/systemd-resolved-varlink.socket";
    "/etc/systemd/system/sockets.target.wants/systemd-resolved-monitor.socket" = "/usr/lib/systemd/system/systemd-resolved-monitor.socket";
    "/etc/systemd/system/sysinit.target.wants/overalls-resolved-identity.service" = "../overalls-resolved-identity.service";
  };
  # @cc [owner:ghuntley,label:verification;build;security] foreign-linux-final-filesystem-modes
  # The actual fleet Arch and Alma ext4 images MUST retain executable upstream
  # init/shell/loader files, non-executable release data and root ownership. The owned
  # sudo copy MUST be setuid while account secrets remain private. The root MUST
  # be a root-owned mode-0755 directory, and both temporary directories MUST be
  # real root-owned directories with mode 01777. This offline
  # check MUST NOT be reported as guest boot, SSH or elevation execution.
  checkImage = distribution: image:
  let
    loader = if distribution == "arch" then "/usr/lib/ld-linux-x86-64.so.2" else "/usr/lib64/ld-linux-x86-64.so.2";
    modes = expectedModes // { ${loader} = "0755"; };
    entries = lib.mapAttrs (_: mode: { inherit mode; kind = "regular"; }) modes // {
      "/" = { mode = "0755"; kind = "directory"; };
      "/tmp" = { mode = "01777"; kind = "directory"; };
      "/var/tmp" = { mode = "01777"; kind = "directory"; };
    } // lib.optionalAttrs (distribution == "arch") {
      "/etc/tmpfiles.d/root.conf" = { mode = "0644"; kind = "regular"; };
    } // lib.optionalAttrs (distribution == "almalinux")
      (lib.mapAttrs (_: _: { mode = "0644"; kind = "regular"; }) almaResolverFiles
        // lib.mapAttrs (_: _: { mode = "0777"; kind = "symlink"; }) almaResolverLinks);
  in ''
    # @cc [owner:ghuntley,label:verification;security] foreign-linux-final-kernel-lsm
    # Actual private-service manifests MUST select exactly one reviewed LSM
    # stack and retain their own distribution marker. Missing, duplicate or
    # SELinux-bearing selections MUST fail this offline artifact check.
    if ! jq -e --arg distribution ${lib.escapeShellArg distribution} '
      (.boot_args | split(" ") | map(select(length > 0))) as $arguments |
      [$arguments[] | select(startswith("lsm="))] == ["lsm=landlock,yama,bpf"] and
      ($arguments | index("overalls.distribution=" + $distribution) != null)
    ' ${image}/manifest.json >/dev/null; then
      echo ${lib.escapeShellArg "${distribution}: invalid LSM selection or distribution in final manifest"} >&2
      exit 1
    fi
  '' + lib.optionalString (distribution == "arch") ''
    # @cc [owner:ghuntley,label:verification;security] arch-final-root-tmpfiles-policy
    # The actual private Arch image MUST carry the exact higher-priority 0755
    # root policy. An initial writable inode alone MUST NOT pass when boot-time
    # tmpfiles would remove the owner's write bit.
    printf 'z / 0755 root root -\n' > expected-root.conf
    debugfs -R 'cat /etc/tmpfiles.d/root.conf' ${image}/rootfs.ext4 2>/dev/null > actual-root.conf
    if ! cmp -s expected-root.conf actual-root.conf; then
      echo 'arch: missing or invalid boot-time root tmpfiles override' >&2
      exit 1
    fi
  '' + lib.optionalString (distribution == "almalinux") (
    # @cc [owner:ghuntley,label:verification;security] almalinux-final-resolver-runtime
    # The actual private Alma image MUST retain exact pinned resolver service,
    # sockets, sysusers and D-Bus files plus the scoped identity bootstrap and
    # activation links. Missing or altered bytes MUST fail this offline gate.
    lib.concatStringsSep "\n" (lib.mapAttrsToList (path: expected: ''
      debugfs -R ${lib.escapeShellArg "cat ${path}"} ${image}/rootfs.ext4 2>/dev/null > resolver-file
      if ! cmp -s ${expected} resolver-file; then
        echo ${lib.escapeShellArg "almalinux ${path}: missing or altered resolver runtime file"} >&2
        exit 1
      fi
    '') almaResolverFiles) + "\n" + lib.concatStringsSep "\n" (lib.mapAttrsToList (path: target: ''
      metadata=$(debugfs -R ${lib.escapeShellArg "stat ${path}"} ${image}/rootfs.ext4 2>/dev/null)
      target=$(printf '%s\n' "$metadata" | sed -nE 's/^Fast link dest: "([^"]+)"$/\1/p')
      if test "$target" != ${lib.escapeShellArg target}; then
        echo ${lib.escapeShellArg "almalinux ${path}: missing or altered resolver activation link"} >&2
        exit 1
      fi
    '') almaResolverLinks)
  ) + lib.concatStringsSep "\n" (lib.mapAttrsToList (path: expected: ''
    metadata=$(debugfs -R ${lib.escapeShellArg "stat ${path}"} ${image}/rootfs.ext4 2>/dev/null)
    mode=$(printf '%s\n' "$metadata" | sed -nE 's/^Inode: [0-9]+ +Type: ${expected.kind} +Mode: +(0[0-7]+) +Flags:.*/\1/p')
    ownership=$(printf '%s\n' "$metadata" | sed -nE 's/^User: +([0-9]+) +Group: +([0-9]+) +Project:.*/\1:\2/p')
    if test "$mode" != ${lib.escapeShellArg expected.mode} || test "$ownership" != 0:0; then
      echo ${lib.escapeShellArg "${distribution} ${path}: unexpected ${expected.kind} mode or ownership"} >&2
      exit 1
    fi
  '') entries);
in
pkgs.runCommand "foreign-linux-guest-filesystem" {
  nativeBuildInputs = [ pkgs.e2fsprogs pkgs.gnused pkgs.jq ];
  passthru = { inherit images; };
} ''
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList checkImage images)}
  touch "$out"
''
