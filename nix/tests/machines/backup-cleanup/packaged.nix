{ pkgs, packages, module }:
pkgs.testers.runNixOSTest {
  name = "overalls-packaged-backup-cleanup";
  nodes.storage = { config, lib, ... }: {
    imports = [ module (import ../../support/zfs-node.nix {
      inherit packages;
      memoryMiB = 2048;
      diskMiB = 4096;
    }) ];
    services.overallsBackups = {
      enable = true;
      defaults.enable = false;
      s3 = { endpoint = "https://unused.test"; bucket = "backups"; region = "unused"; };
      secretUnits = [];
      postgres.enable = false;
    };
    systemd.timers = lib.genAttrs
      [ "overalls-backup" "overalls-backup-prune" "overalls-backup-check" "overalls-backup-read-check" "overalls-backup-cleanup" ]
      (_: { wantedBy = lib.mkForce []; });
    systemd.services.overalls-backup-cleanup.wantedBy = lib.mkForce [];
    environment.systemPackages = [ (pkgs.python313.withPackages (ps: [ ps.hypothesis ])) ];
    environment.etc."backup-runtime".source = ../../../modules/backups;
    environment.etc."packaged-cleanup.py".source = ./packaged_cleanup.py;
    environment.variables.NATIVE_ZFS = "${config.boot.zfs.package}/bin/zfs";
  };
  testScript = ''
    storage.start()
    storage.wait_for_unit("multi-user.target")
    storage.succeed("zpool create -f -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc")
    with subtest("packaged cleanup preserves failure and converges without credentials"):
        storage.succeed("PYTHONPATH=/etc/backup-runtime python3 /etc/packaged-cleanup.py", timeout=300)
  '';
}
