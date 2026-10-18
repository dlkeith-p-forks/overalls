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
    };
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
  '' + lib.concatStringsSep "\n" (lib.mapAttrsToList (path: expected: ''
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
