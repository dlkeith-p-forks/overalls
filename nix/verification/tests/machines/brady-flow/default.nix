{ pkgs, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-brady-flow-label";
  nodes.machine = { lib, ... }: {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 768;
    virtualisation.cores = 2;
    virtualisation.qemu.forceAccel = lib.mkForce true;
    environment.systemPackages = [ pkgs.iproute2 pkgs.nftables pkgs.python3 pkgs.util-linux ];
    environment.etc."flow-label.py".source = ../../evaluation/flow-label.py;
    environment.etc."flow-label-test".source = pkgs.writeShellScript "flow-label-test" ''
      set -eu
      ${pkgs.iproute2}/bin/ip link set lo up
      exec ${pkgs.python3}/bin/python3 /etc/flow-label.py ${packages.hostTools}/bin/lilly-flow-label ${pkgs.nftables}/bin/nft
    '';
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("unshare --net bash /etc/flow-label-test", timeout=30)
  '';
}
