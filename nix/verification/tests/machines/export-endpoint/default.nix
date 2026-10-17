{ pkgs, packages }:
let
  fixture = { role, memory }: { lib, ... }: {
    imports = [ (import ../../support/zfs-node.nix {
      inherit packages;
      memoryMiB = memory;
      diskMiB = 8192;
    }) ];
    environment.etc."endpoint-check.exs".source = ./check.exs;
    environment.systemPackages = [ pkgs.python3 pkgs.openssh
      (pkgs.writeShellScriptBin "endpoint-control" ''
        export PATH="/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
        export ERL_FLAGS="+S 2:2"
        export RELEASE_DISTRIBUTION=none
        export RELEASE_COOKIE=isolated-endpoint-fixture
        export RELEASE_TMP=/run/endpoint-fixture-release
        mkdir -p "$RELEASE_TMP"
        export ENDPOINT_ROLE=${role} ENDPOINT_ACTION="$1"
        exec ${packages.lilly}/bin/lilly eval 'Code.eval_file("/etc/endpoint-check.exs")'
      '')
    ];
  };
in pkgs.testers.runNixOSTest {
  name = "overalls-export-endpoint";
  nodes.source = { lib, ... }: {
    imports = [ (fixture { role = "source"; memory = 3072; })
      (import ../../../../domains/system/transfer.nix { inherit packages; }) ];
    services.lillyTransfer = {
      enable = true;
      configurationFile = "/run/transfer-config.json";
      stateDirectory = "/run/source-permits";
      openFirewall = true;
    };
    # The fixture discovers real pool GUIDs and creates its disposable host key
    # before manually starting the unchanged installed listener unit.
    systemd.services.lilly-transfer-sshd.wantedBy = lib.mkForce [];
  };
  nodes.destination = fixture { role = "destination"; memory = 2048; };
  testScript = builtins.readFile ./driver.py;
}
