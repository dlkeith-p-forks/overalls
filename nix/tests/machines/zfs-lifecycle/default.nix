{ pkgs, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-zfs-lifecycle";
  # Each fixture prepare hashes a real image (170-260 s under shared-host load);
  # the full suite measured 2527 s quiet and exceeded 3600 s at load ~30.
  globalTimeout = 7200;
  nodes.storage = import ../../support/zfs-node.nix {
    inherit packages;
    memoryMiB = 3072;
    diskMiB = 8192;
  };
  testScript = builtins.readFile ./driver.py;
}
