{ pkgs, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-native-backup-cleanup";
  nodes.storage = { config, ... }: {
    imports = [ (import ../../support/zfs-node.nix {
      inherit packages;
      memoryMiB = 2048;
      diskMiB = 4096;
    }) ];
    environment.systemPackages = [ (pkgs.python313.withPackages (ps: [ ps.hypothesis ])) ];
    environment.etc."backup-runtime".source = ../../../../domains/system/backups;
    environment.etc."native-cleanup.py".source = ./native_cleanup.py;
    environment.etc."cleanup-zfs.py".source = ./zfs_command.py;
    environment.variables.NATIVE_ZFS = "${config.boot.zfs.package}/bin/zfs";
  };
  testScript = ''
    storage.start()
    storage.wait_for_unit("multi-user.target")
    storage.succeed("zpool create -f -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc")
    with subtest("native host snapshot cleanup refuses foreign proofs and converges once"):
        storage.succeed("PYTHONPATH=/etc/backup-runtime python3 /etc/native-cleanup.py", timeout=300)
  '';
}
