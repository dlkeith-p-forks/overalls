{ pkgs, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-zfs-io";
  nodes.storage = { config, lib, ... }: {
    system.stateVersion = "26.05";
    networking.hostId = "aabbccdd";
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.forceImportRoot = false;
    systemd.services.zfs-zed.enable = false;
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    virtualisation.emptyDiskImages = [ 2048 2048 2048 ];
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    environment.etc."zfs-io.exs".source = ./probe.exs;
    environment.etc."zfs-io-fault".source = pkgs.writeShellScript "zfs-io-fault" ''
      fault="$(cat /run/zfs-io-fault/mode 2>/dev/null || true)"
      export ZFS_IO_FAULT="$fault"
      if [ "$1" = iostat ] && [ "$ZFS_IO_FAULT" = timeout ]; then exec sleep 10; fi
      if [ "$1" = iostat ] && [ "$ZFS_IO_FAULT" = malformed ]; then
        echo unexpected-extra-row
        exit 0
      fi
      ${config.boot.zfs.package}/bin/zpool "$@"
      result=$?
      if [ "$result" = 0 ] && [ "$1" = iostat ]; then
        case "$ZFS_IO_FAULT" in
          reload)
            ${config.boot.zfs.package}/bin/zpool export tank || exit 1
            ${config.boot.zfs.package}/bin/zpool import tank || exit 1
            ;;
        esac
      fi
      exit "$result"
    '';
    # The production hostd daemon resolves utilities from its own systemd PATH,
    # so install the fixture wrapper there as well as in the probe environment.
    systemd.services.lilly-hostd.path = pkgs.lib.mkBefore [
      (pkgs.writeShellScriptBin "zpool" ''
        exec /etc/zfs-io-fault "$@"
      '')
    ];
    systemd.services.io-workload = {
      serviceConfig.Type = "simple";
      serviceConfig.ExecStart = pkgs.writeShellScript "zfs-io-workload" ''
        while true; do
          ${pkgs.coreutils}/bin/dd if=/dev/urandom of=/outside/io bs=1M count=8 conv=fsync status=none || exit 1
        done
      '';
    };
    systemd.services.io-reader = {
      serviceConfig.Type = "simple";
      serviceConfig.ExecStart = pkgs.writeShellScript "zfs-io-reader" ''
        while true; do
          ${pkgs.coreutils}/bin/dd if=/outside/read of=/dev/null bs=1M iflag=direct status=none || exit 1
          ${pkgs.coreutils}/bin/touch /run/zfs-io-read-completed
        done
      '';
    };
    environment.systemPackages = [ config.boot.zfs.package packages.lilly pkgs.jq
      (pkgs.writeShellScriptBin "zfs-io" ''
        export PATH="/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
        export ERL_FLAGS="+S 2:2"
        export RELEASE_COOKIE="isolated-zfs-io-test-cookie"
        export RELEASE_DISTRIBUTION="none"
        export RELEASE_TMP="/run/zfs-io-release"
        mkdir -p "$RELEASE_TMP"
        exec ${packages.lilly}/bin/lilly eval 'Code.eval_file("/etc/zfs-io.exs")'
      '')
    ];
  };
  testScript = builtins.readFile ./driver.py;
}
