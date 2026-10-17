{ pkgs, packages, hegel }:
let
  hostTools = packages.hostTools;
in hegel.runTest {
  name = "overalls-zfs-transfer";

  properties = {
    enable = true;
    profile = "ci";
    testCases = 2;
    statefulStepCount = 18;
  };

  nodes.storage = { config, lib, ... }: {
    system.stateVersion = "26.05";
    networking.hostId = "aabbccde";
    networking.dhcpcd.denyInterfaces = [ "lu*" ];
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    boot.supportedFilesystems = [ "zfs" ];
    boot.extraModprobeConfig = "options zfs zfs_arc_max=134217728";
    systemd.services.zfs-zed.enable = false;
    virtualisation.memorySize = 1536;
    virtualisation.cores = 2;
    virtualisation.emptyDiskImages = [ 1024 1024 ];
    virtualisation.qemu.forceAccel = lib.mkForce true;
    environment.systemPackages = [ config.boot.zfs.package pkgs.e2fsprogs pkgs.python3 hostTools packages.lilly
      (pkgs.writeShellScriptBin "received-check" ''
        export PATH="${packages.lilly}/host-tools/bin:/run/current-system/sw/bin"
        if [ -n "''${ADOPTION_PAUSE:-}" ]; then export PATH="/run/adoption-tools:$PATH"; fi
        export ADOPTION_RELEASE_METADATA="${packages.lilly}/overalls-release.json"
        export ERL_FLAGS="+S 2:2"
        export RELEASE_COOKIE=local-received-test
        export RELEASE_TMP=/run/received-release
        mkdir -p "$RELEASE_TMP"
        export RECEIVED_ACTION="$1"
        export RECEIVED_MODE="''${2:-full}"
        exec ${packages.lilly}/bin/lilly eval 'Code.eval_file(if System.get_env("RECEIVED_MODE") in ["adoption", "adoption-cancel", "adoption-inception"], do: "/etc/adoption-check.exs", else: "/etc/received-check.exs")'
      '')
    ];
    environment.etc."received-check.exs".source = ./received.exs;
    environment.etc."adoption-check.exs".source = ./adoption.exs;
    environment.etc."adoption-zfs-fault".source = pkgs.writeShellScript "adoption-zfs-fault" ''
      ${config.boot.zfs.package}/bin/zfs "$@"
      result=$?
      if [ "$result" = 0 ] && [ "''${ADOPTION_PAUSE:-}" = "$1" ]; then
        touch /run/adoption-operation-committed
        exec sleep 300
      fi
      exit "$result"
    '';
    environment.etc."received-fixture.py".source = ./receive.py;
    environment.etc."native-stream-probe.py".source = ./stream.py;
  };
  testScript = builtins.readFile ./driver.py;
}
