{ pkgs, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-audi-ingress-network";
  nodes.connector = { config, lib, ... }: {
    system.stateVersion = "26.05";
    networking.firewall.allowedTCPPorts = [ 8080 ];
    networking.firewall.allowedUDPPorts = [ 53 ];
    virtualisation.memorySize = 1536;
    virtualisation.cores = 2;
    virtualisation.qemu.forceAccel = lib.mkForce true;
    users.users.lilly = { isSystemUser = true; uid = 377; group = "lilly"; };
    users.groups.lilly.gid = 377;
    environment.etc."ingress-check.exs".source = ./probe.exs;
    environment.etc."ingress-echo.py".source = ./echo.py;
    environment.etc."ingress-egress.py".source = ./egress.py;
    environment.etc."ingress-denied.py".source = ./denied.py;
    environment.systemPackages = [ packages.lilly pkgs.iproute2 pkgs.nftables pkgs.python3 pkgs.util-linux pkgs.iputils
      (pkgs.writeShellScriptBin "ingress-check" ''
        # @cc [owner:ghuntley,label:verification] ingress-packaged-hostd
        # The connector MUST use the release's real hostd for namespace sockets;
        # the fixture cannot replace it with a direct privileged socket fallback.
        export PATH="${packages.lilly}/host-tools/bin:$PATH"
        # The root probe's private hostd drops bridge workers to the service uid.
        export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}
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
