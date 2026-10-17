{ pkgs, packages }:
let
  ca = ../../fixtures/ssh-host-ca;
  inherit (packages) toolchain;
in pkgs.testers.runNixOSTest {
  name = "overalls-native-ssh-host-certificates";
  defaults = { lib, ... }: {
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
  };
  nodes.server = { ... }: {
    networking.firewall.allowedTCPPorts = [ 2222 ];
    environment.systemPackages = [ pkgs.openssh ];
    systemd.services.certificate-server = {
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.openssh ];
      preStart = ''
        install -d -m 0700 /run/certificate-server
        cd /run/certificate-server
        ssh-keygen -q -t ed25519 -N "" -C "" -f ssh_host_ed25519_key
        cp ${ca}/key.pub authorized_keys
        install -m 0600 ${ca}/key ca
        ssh-keygen -q -s ca -I native-test -h -n server -V -5m:+3650d ssh_host_ed25519_key.pub
      '';
      serviceConfig.ExecStart = "${toolchain.elixir}/bin/elixir ${./server.exs}";
    };
  };
  nodes.client = { ... }: {
    environment.systemPackages = [ pkgs.openssh ];
    environment.etc."ssh-ca.pub".source = ca + "/key.pub";
    environment.etc."ssh-test-key".source = ca + "/key";
  };
  testScript = builtins.readFile ./test.py;
}
