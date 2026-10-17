{ pkgs, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-audi-ingress-network";
  nodes.connector = { lib, ... }: {
    system.stateVersion = "26.05";
    networking.firewall.allowedTCPPorts = [ 8080 ];
    networking.firewall.allowedUDPPorts = [ 53 ];
    virtualisation.memorySize = 1536;
    virtualisation.cores = 2;
    virtualisation.qemu.forceAccel = lib.mkForce true;
    environment.etc."ingress-check.exs".source = ./probe.exs;
    environment.etc."ingress-echo.py".source = ./echo.py;
    environment.etc."ingress-egress.py".source = ./egress.py;
    environment.etc."ingress-denied.py".source = ./denied.py;
    environment.systemPackages = [ packages.lilly pkgs.iproute2 pkgs.nftables pkgs.python3 pkgs.util-linux pkgs.iputils
      (pkgs.writeShellScriptBin "ingress-check" ''
        export ERL_FLAGS="+S 2:2"
        export RELEASE_COOKIE=isolated-ingress-fixture
        export RELEASE_DISTRIBUTION=none
        export RELEASE_TMP=/run/ingress-release
        export INGRESS_CHECK="$1"
        mkdir -p "$RELEASE_TMP"
        exec ${packages.lilly}/bin/lilly eval 'Code.eval_file("/etc/ingress-check.exs")'
      '')
    ];
  };
  testScript = builtins.readFile ./driver.py;
}
