{ pkgs, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-native-zfs";
  nodes.storage = { ... }: {
    imports = [ (import ../../support/zfs-node.nix {
      inherit packages;
      memoryMiB = 2048;
      diskMiB = 4096;
    }) ];
    environment.systemPackages = [ pkgs.python3 ];
    environment.etc."resource-native.py".source = ../auto-update/native_resources.py;
    environment.etc."resource-policy.py".source = ../../../modules/auto-update/resources.py;
    environment.etc."updater.py".source = ../../../modules/auto-update/runtime.py;
    systemd.slices.lilly.sliceConfig = { CPUQuota = "100%"; MemoryMax = "512M"; };
  };
  testScript = builtins.readFile ./driver.py;
}
