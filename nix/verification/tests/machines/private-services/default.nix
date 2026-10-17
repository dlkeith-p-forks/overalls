{ pkgs, packages }:
let python = pkgs.python3.withPackages (p: [ p.cryptography ]);
in pkgs.testers.runNixOSTest {
  name = "overalls-private-services-network";
  nodes.router = { lib, ... }: {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    virtualisation.qemu.forceAccel = lib.mkForce true;
    users.users.audi = { isSystemUser = true; group = "audi"; };
    users.groups.audi = {};
    environment.systemPackages = [ pkgs.iproute2 pkgs.nftables pkgs.curl pkgs.dig python pkgs.util-linux
      (pkgs.writeShellScriptBin "private-network-prepare" ''
        set -euo pipefail
        export ERL_FLAGS="+S 2:2" RELEASE_COOKIE=isolated-private-network RELEASE_DISTRIBUTION=none
        export RELEASE_TMP=/run/private-network-release
        mkdir -p "$RELEASE_TMP"
        ${packages.lilly}/bin/lilly eval 'Code.eval_file("${./prepare.exs}")'
        ${python}/bin/python3 ${./certificates.py} ${../../../../../audi/priv/private_pki}
        chown -R audi:audi /run/private-audi
      '')
    ];
    systemd.services.private-audi-test = {
      environment = { AUDI_CONFIG_FILE = "/run/private-audi/config.json"; RELEASE_DISTRIBUTION = "none";
        RELEASE_COOKIE = "isolated-private-audi"; RELEASE_TMP = "/run/private-audi-release"; ERL_FLAGS = "+S 2:2"; ERL_CRASH_DUMP = "/dev/null"; };
      serviceConfig = { User = "audi"; Group = "audi"; ExecStart = "${packages.audi}/bin/audi start";
        RuntimeDirectory = "private-audi-release"; RuntimeDirectoryMode = "0700";
        NetworkNamespacePath = "/run/netns/lilly-bd7662a5eeb4";
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ]; CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ]; };
    };
  };
  testScript = builtins.readFile ./driver.py;
}
