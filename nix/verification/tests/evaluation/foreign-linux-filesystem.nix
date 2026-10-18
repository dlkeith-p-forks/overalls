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
    "/usr/bin/systemctl" = "0755";
    "/usr/bin/systemd-run" = "0755";
    "/usr/lib/os-release" = "0644";
    "/usr/bin/sudo" = "04755";
    "/etc/shadow" = "0600";
    "/etc/gshadow" = "0600";
    "/usr/local/lib/lilly/install-pam-helper" = "0755";
    "/etc/systemd/system/overalls-pam-helpers.service" = "0644";
    "/etc/systemd/system/overalls-vscode-web.service" = "0644";
  };
  pamHelperUnit = pkgs.writeText "expected-pam-helpers.service" ''
    [Unit]
    Description=Install the pinned PAM account helper
    Before=ssh.service
    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/usr/local/lib/lilly/install-pam-helper
    [Install]
    WantedBy=multi-user.target
  '';
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
    closure = pkgs.closureInfo { rootPaths = image.runtimeStorePaths; };
    editorLinks = {
      "/usr/local/bin/overalls-code" = "${packages.vscodeWeb}/bin/overalls-code";
      "/usr/local/bin/direnv" = "${pkgs.direnv}/bin/direnv";
      "/nix/var/nix/gcroots/overalls-vscode-web" = toString packages.vscodeWeb;
      "/nix/var/nix/gcroots/overalls-vscode-web-broker" = toString packages.vscodeWebBroker;
      "/nix/var/nix/gcroots/overalls-vscode-web-configuration" = toString image.editorConfiguration;
      "/nix/var/nix/gcroots/overalls-vscode-web-unit" = toString image.editorUnit;
      "/nix/var/nix/gcroots/overalls-vscode-web-direnv" = toString pkgs.direnv;
      "/etc/systemd/system/multi-user.target.wants/overalls-vscode-web.service" = "../overalls-vscode-web.service";
    };
    loader = if distribution == "arch" then "/usr/lib/ld-linux-x86-64.so.2" else "/usr/lib64/ld-linux-x86-64.so.2";
    modes = expectedModes // {
      ${loader} = "0755";
      ${builtins.unsafeDiscardStringContext "${pkgs.pam}/bin/unix_chkpwd"} = "0555";
      ${builtins.unsafeDiscardStringContext (toString image.editorConfiguration)} = "0444";
      ${builtins.unsafeDiscardStringContext (toString image.editorUnit)} = "0444";
    };
    entries = lib.mapAttrs (_: mode: { inherit mode; kind = "regular"; }) modes // {
      "/" = { mode = "0755"; kind = "directory"; };
      "/tmp" = { mode = "01777"; kind = "directory"; };
      "/var/tmp" = { mode = "01777"; kind = "directory"; };
    } // lib.mapAttrs (_: _: { mode = "0777"; kind = "symlink"; }) editorLinks
    // lib.optionalAttrs (distribution == "arch") {
      "/etc/tmpfiles.d/root.conf" = { mode = "0644"; kind = "regular"; };
    } // lib.optionalAttrs (distribution == "almalinux")
      (lib.mapAttrs (_: _: { mode = "0644"; kind = "regular"; }) almaResolverFiles
        // lib.mapAttrs (_: _: { mode = "0777"; kind = "symlink"; }) almaResolverLinks);
  in ''
    # @cc [owner:ghuntley,label:verification;build;security] foreign-linux-final-editor-payload
    # Each actual private image MUST expose the exact pinned descriptor, its
    # immutable broker configuration and service, complete registered closure
    # and GC roots. Memory and disk MUST preserve editor minima. These checks
    # establish artifact custody only, not browser or personal-worker execution.
    jq -e --argjson expected '${builtins.toJSON image.editorDescriptor}' '
      .version == 4 and .editor == $expected and .minimum_memory_bytes >= 2147483648 and
      .minimum_disk_bytes >= (.rootfs.bytes + 2147483648) and
      (.minimum_disk_bytes % 1073741824 == 0)
    ' ${image}/manifest.json >/dev/null
    debugfs -R 'cat ${image.editorConfiguration}' ${image}/rootfs.ext4 2>/dev/null > editor-config
    cmp ${image.editorConfiguration} editor-config
    debugfs -R 'cat /etc/systemd/system/overalls-vscode-web.service' ${image}/rootfs.ext4 2>/dev/null > editor-unit
    cmp ${image.editorUnit} editor-unit
    debugfs -R 'cat ${packages.vscodeWeb}/bin/overalls-code' ${image}/rootfs.ext4 2>/dev/null > editor-launcher
    cmp ${packages.vscodeWeb}/bin/overalls-code editor-launcher
    debugfs -R 'cat ${packages.vscodeWebBroker}/bin/overalls-vscode-web-broker' ${image}/rootfs.ext4 2>/dev/null > editor-broker
    cmp ${packages.vscodeWebBroker}/bin/overalls-vscode-web-broker editor-broker
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (path: expected: ''
      metadata=$(debugfs -R ${lib.escapeShellArg "stat ${path}"} ${image}/rootfs.ext4 2>/dev/null)
      target=$(printf '%s\n' "$metadata" | sed -nE 's/^Fast link dest: "([^"]+)"$/\1/p')
      if test -z "$target"; then
        target=$(debugfs -R ${lib.escapeShellArg "cat ${path}"} ${image}/rootfs.ext4 2>/dev/null)
      fi
      if test "$target" != ${lib.escapeShellArg expected}; then
        echo ${lib.escapeShellArg "${distribution} ${path}: missing or altered editor activation/GC link"} >&2
        exit 1
      fi
    '') editorLinks)}
    debugfs -R 'cat /nix/var/nix/db/db.sqlite' ${image}/rootfs.ext4 2>/dev/null > editor-db.sqlite
    test "$(sqlite3 editor-db.sqlite 'PRAGMA quick_check;')" = ok
    test "$(sqlite3 editor-db.sqlite 'SELECT count(*) FROM ValidPaths WHERE registrationTime != 1;')" = 0
    mkdir ${distribution}-expected-state
    NIX_STATE_DIR=$PWD/${distribution}-expected-state nix-store --load-db --option build-users-group "" < ${closure}/registration
    sqlite3 ${distribution}-expected-state/db/db.sqlite 'SELECT path,hash,narSize FROM ValidPaths ORDER BY path;' > expected-paths
    sqlite3 editor-db.sqlite 'SELECT path,hash,narSize FROM ValidPaths ORDER BY path;' > actual-paths
    cmp expected-paths actual-paths
    reference_query='SELECT source.path,target.path FROM Refs JOIN ValidPaths AS source ON source.id = Refs.referrer JOIN ValidPaths AS target ON target.id = Refs.reference ORDER BY source.path,target.path;'
    sqlite3 ${distribution}-expected-state/db/db.sqlite "$reference_query" > expected-refs
    sqlite3 editor-db.sqlite "$reference_query" > actual-refs
    cmp expected-refs actual-refs
    while IFS= read -r path; do
      printf 'stat %s\n' "$path"
    done < ${closure}/store-paths > closure-commands
    debugfs -f closure-commands ${image}/rootfs.ext4 > closure-metadata 2> closure-diagnostics
    test "$(grep -c '^Inode:' closure-metadata)" = "$(wc -l < ${closure}/store-paths)"
    test "$(grep -c '^User: *0 *Group: *0 *Project:' closure-metadata)" = "$(wc -l < ${closure}/store-paths)"
    for path in /nix-path-registration /nix/var/nix/db/reserved /nix/var/nix/db/db.sqlite-wal /nix/var/nix/db/db.sqlite-shm; do
      metadata=$(debugfs -R "stat $path" ${image}/rootfs.ext4 2>/dev/null)
      test -z "$metadata"
    done
    # @cc [owner:ghuntley,label:verification;security] foreign-linux-final-pam-helper
    # Actual images MUST retain the exact reviewed helper unit, pinned installer
    # and immutable non-setuid PAM source; SSH MUST require and follow helper
    # success. This is offline artifact evidence, not native login acceptance.
    debugfs -R 'cat /etc/systemd/system/overalls-pam-helpers.service' ${image}/rootfs.ext4 2>/dev/null > pam-helper-unit
    cmp ${pamHelperUnit} pam-helper-unit
    debugfs -R 'cat /usr/local/lib/lilly/install-pam-helper' ${image}/rootfs.ext4 2>/dev/null > pam-helper-installer
    cmp ${image.passthru.pamHelperInstaller} pam-helper-installer
    debugfs -R 'cat ${pkgs.pam}/bin/unix_chkpwd' ${image}/rootfs.ext4 2>/dev/null > pam-helper-source
    cmp ${pkgs.pam}/bin/unix_chkpwd pam-helper-source
    debugfs -R 'cat /etc/systemd/system/ssh.service' ${image}/rootfs.ext4 2>/dev/null > pam-ssh-unit
    grep -Fx 'Requires=overalls-pam-helpers.service' pam-ssh-unit
    grep -Fx 'After=overalls-ssh-sync.service overalls-pam-helpers.service' pam-ssh-unit
    metadata=$(debugfs -R 'stat /etc/systemd/system/multi-user.target.wants/overalls-pam-helpers.service' ${image}/rootfs.ext4 2>/dev/null)
    target=$(printf '%s\n' "$metadata" | sed -nE 's/^Fast link dest: "([^"]+)"$/\1/p')
    test "$target" = ../overalls-pam-helpers.service
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
  nativeBuildInputs = [ pkgs.e2fsprogs pkgs.gnused pkgs.gnugrep pkgs.jq pkgs.nix pkgs.sqlite ];
  passthru = { inherit images; };
} ''
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList checkImage images)}
  touch "$out"
''
