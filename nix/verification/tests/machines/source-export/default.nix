{ pkgs, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-source-export";
  nodes.storage = { ... }: {
    imports = [ (import ../../support/zfs-node.nix {
      inherit packages;
      memoryMiB = 3072;
      diskMiB = 8192;
    }) ];
    environment.etc."source-export.exs".source = ./export.exs;
    environment.systemPackages = [ pkgs.python3 pkgs.e2fsprogs
      (pkgs.writeShellScriptBin "source-export-control" ''
        export PATH="/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
        export ERL_FLAGS="+S 2:2"
        export RELEASE_COOKIE="isolated-source-export"
        export RELEASE_DISTRIBUTION=none
        export RELEASE_TMP=/run/source-export-release
        mkdir -p "$RELEASE_TMP"
        export SOURCE_EXPORT_ACTION="$1"
        exec ${packages.lilly}/bin/lilly eval 'Code.eval_file("/etc/source-export.exs")'
      '')
    ];
  };
  testScript = builtins.readFile ./driver.py;
}
