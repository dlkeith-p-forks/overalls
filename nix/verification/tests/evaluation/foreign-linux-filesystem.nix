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
  # sudo copy MUST be setuid while account secrets remain private. This offline
  # check MUST NOT be reported as guest boot, SSH or elevation execution.
  checkImage = distribution: image:
  let
    loader = if distribution == "arch" then "/usr/lib/ld-linux-x86-64.so.2" else "/usr/lib64/ld-linux-x86-64.so.2";
    modes = expectedModes // { ${loader} = "0755"; };
  in lib.concatStringsSep "\n" (lib.mapAttrsToList (path: expected: ''
    metadata=$(debugfs -R ${lib.escapeShellArg "stat ${path}"} ${image}/rootfs.ext4 2>/dev/null)
    mode=$(printf '%s\n' "$metadata" | sed -nE 's/^Inode: [0-9]+ +Type: regular +Mode: +(0[0-7]+) +Flags:.*/\1/p')
    ownership=$(printf '%s\n' "$metadata" | sed -nE 's/^User: +([0-9]+) +Group: +([0-9]+) +Project:.*/\1:\2/p')
    if test "$mode" != ${lib.escapeShellArg expected} || test "$ownership" != 0:0; then
      echo ${lib.escapeShellArg "${distribution} ${path}: unexpected regular-file mode or ownership"} >&2
      exit 1
    fi
  '') modes);
in
pkgs.runCommand "foreign-linux-guest-filesystem" {
  nativeBuildInputs = [ pkgs.e2fsprogs pkgs.gnused ];
  passthru = { inherit images; };
} ''
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList checkImage images)}
  touch "$out"
''
