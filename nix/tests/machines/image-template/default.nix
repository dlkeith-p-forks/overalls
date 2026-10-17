{ pkgs, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-image-template";
  nodes.storage = { config, lib, ... }: {
    system.stateVersion = "26.05";
    networking.hostId = "aabbccdd";
    boot.supportedFilesystems = [ "zfs" ];
    systemd.services.zfs-zed.enable = false;
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    virtualisation.emptyDiskImages = [ 4096 ];
    virtualisation.qemu.forceAccel = lib.mkForce true;
    boot.extraModprobeConfig = "options zfs zfs_arc_max=268435456";
    environment.etc."image-template.exs".source = ./probe.exs;
    environment.etc."template-zfs-fault".source = pkgs.writeShellScript "template-zfs-fault" ''
      # A loaded host: the native change completes, but only after Lilly's
      # three-second utility default (the 2026-10-09 production claim).
      if [ "''${TEMPLATE_SLOW:-}" = "$1" ]; then sleep 6; fi
      # An interrupted remount: ZFS has unmounted the dataset, then the
      # utility dies before any property changes (the 2026-10-09 failure).
      # A create that completes natively but whose mount is lost before the
      # utility returns (the 2026-10-10 template create timeout).
      if [ "''${TEMPLATE_CREATE_UNMOUNTED:-}" = "$1" ]; then
        ${config.boot.zfs.package}/bin/zfs "$@"
        for target; do :; done
        ${config.boot.zfs.package}/bin/zfs unmount "$target"
        touch /run/template-effect-committed
        exec sleep 300
      fi
      if [ "''${TEMPLATE_UNMOUNT:-}" = "$1" ]; then
        for target; do :; done
        ${config.boot.zfs.package}/bin/zfs unmount "$target"
        touch /run/template-effect-committed
        exec sleep 300
      fi
      ${config.boot.zfs.package}/bin/zfs "$@"
      result=$?
      if [ "$result" = 0 ] && [ "$TEMPLATE_PAUSE" = "$1" ]; then
        touch /run/template-effect-committed
        exec sleep 300
      fi
      exit "$result"
    '';
    # ADR-0152 evidence: log each zfs, zpool and findmnt invocation (name and
    # arguments) while the probe holds the pool lock for one preparation.
    environment.etc."template-trace".source = pkgs.writeShellScript "template-trace" ''
      utility=$(basename "$0")
      if [ -f /run/template-trace.log ]; then printf '%s %s\n' "$utility" "$*" >> /run/template-trace.log; fi
      exec /run/current-system/sw/bin/"$utility" "$@"
    '';
    environment.etc."template-copy-fault".source = pkgs.writeShellScript "template-copy-fault" ''
      ${packages.lilly}/host-tools/bin/lilly-image-copy "$@"
      result=$?
      if [ "$result" = 0 ] && [ "$TEMPLATE_PAUSE" = copy ] && [ "$1" = copy ]; then
        touch /run/template-effect-committed
        exec sleep 300
      fi
      exit "$result"
    '';
    # Kernel copy offload finishes a fixture-sized copy in milliseconds; this
    # holds the real copier inside its copy syscall so the lock test can observe it.
    environment.etc."template-copy-slow".source = pkgs.writeShellScript "template-copy-slow" ''
      if [ "$1" = auto ]; then
        exec ${pkgs.strace}/bin/strace -f -qq -o /dev/null \
          -e trace=copy_file_range -e inject=copy_file_range:delay_enter=45000000 \
          ${packages.lilly}/host-tools/bin/lilly-image-copy "$@"
      fi
      exec ${packages.lilly}/host-tools/bin/lilly-image-copy "$@"
    '';
    environment.systemPackages = [ config.boot.zfs.package packages.lilly pkgs.jq
      (pkgs.writeShellScriptBin "image-template" ''
        export PATH="/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
        if [ -n "''${TEMPLATE_PAUSE:-}''${TEMPLATE_SLOW:-}''${TEMPLATE_UNMOUNT:-}''${TEMPLATE_CREATE_UNMOUNTED:-}" ]; then export PATH="/run/template-fault/bin:$PATH"; fi
        if [ -n "''${TEMPLATE_SLOW:-}" ]; then export PATH="/run/template-slow/bin:$PATH"; fi
        if [ -n "''${TEMPLATE_TRACE:-}" ]; then export PATH="/run/template-trace/bin:$PATH"; fi
        export ERL_FLAGS="+S 2:2"
        export RELEASE_COOKIE="isolated-template-test"
        export RELEASE_DISTRIBUTION="none"
        export RELEASE_TMP="/run/template-release"
        mkdir -p "$RELEASE_TMP"
        export TEMPLATE_ACTION="$1"
        export TEMPLATE_IMAGE="''${2:-1}"
        exec ${packages.lilly}/bin/lilly eval 'Code.eval_file("/etc/image-template.exs")'
      '')
    ];
  };
  testScript = builtins.readFile ./driver.py;
}
