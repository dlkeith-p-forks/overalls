{ pkgs, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-image-copy";
  nodes.storage = { config, ... }: {
    system.stateVersion = "26.05";
    networking.hostId = "aabbccdd";
    boot.supportedFilesystems = [ "zfs" ];
    systemd.services.zfs-zed.enable = false;
    virtualisation.memorySize = 2048;
    virtualisation.emptyDiskImages = [ 4096 ];
    boot.extraModprobeConfig = "options zfs zfs_arc_max=268435456 zfs_bclone_enabled=1";
    environment.systemPackages = [ config.boot.zfs.package packages.hostTools ];
  };
  testScript = builtins.readFile ./driver.py;
}
