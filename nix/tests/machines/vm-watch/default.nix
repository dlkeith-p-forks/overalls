{ pkgs, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-vm-watch";
  nodes.machine = { lib, ... }: {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 768;
    virtualisation.cores = 2;
    virtualisation.qemu.forceAccel = lib.mkForce true;
    systemd.slices.lilly = { };
    environment.systemPackages = [ pkgs.python3 pkgs.procps ];
    environment.etc."vm-watch-probe.py".source = ./probe.py;
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    print(machine.succeed("python3 /etc/vm-watch-probe.py ${packages.hostTools}/bin/lilly-vm-watch", timeout=60))
  '';
}
