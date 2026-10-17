{ pkgs, module }:
pkgs.testers.runNixOSTest {
  name = "overalls-sysctl";
  defaults = {
    imports = [ module ];
    system.stateVersion = "26.05";
    virtualisation.memorySize = 512;
    virtualisation.qemu.forceAccel = pkgs.lib.mkForce true;
    networking.firewall.allowedTCPPorts = [ 8123 ];
    environment.systemPackages = [ pkgs.iproute2 pkgs.procps ];
    systemd.services.tcp-probe = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python ${./probe.py} server";
    };
  };
  nodes = {
    enabled.overalls.sysctl.enable = true;
    disabled = {};
  };
  testScript = ''
    probe = "${pkgs.python3}/bin/python ${./probe.py}"
  '' + builtins.readFile ./driver.py;
}
