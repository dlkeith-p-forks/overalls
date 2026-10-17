{ pkgs, module, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-administrative-ssh";
  nodes.host = { lib, ... }: {
    imports = [ module (import ../../support/ssh-host-certificate.nix { inherit pkgs; role = "porsche"; }) ];
    system.switch.enable = true;
    virtualisation.memorySize = 1536;
    services.porsche = {
      controlPlane = "https://localhost:5443";
      publicOrigin = "https://control.example.test";
      credentialFile = "/run/admin-fixture/gateway.token";
      package = packages.porsche;
    };
    specialisation.management.configuration = {
      services.openssh.ports = lib.mkForce [ 2222 2223 ];
      services.porsche.enable = true;
    };
    services.openssh = {
      enable = true;
      ports = [ 22 2222 2223 ];
      authorizedKeysFiles = [ "/run/admin-fixture/client.pub" ];
      settings = { PermitRootLogin = "prohibit-password"; PasswordAuthentication = false; };
    };
    environment.systemPackages = [ pkgs.openssh pkgs.python3 pkgs.nix ];
    environment.etc."admin-port-check.py".text = ''
      import os, shlex, sys
      from types import SimpleNamespace
      sys.path.insert(0, "${../../../../domains/artifacts/host}")
      import cli
      args = SimpleNamespace(target="root@127.0.0.1", identity="/run/admin-fixture/client",
                             known_hosts="/run/admin-fixture/known_hosts", ssh_port=2222)
      assert cli.ssh(args, ["printf", "%s", "administrative-transport"]) == b"administrative-transport"
      environment = dict(os.environ, NIX_SSHOPTS=shlex.join(cli.connection(args)[1:-1]))
      cli.run(["nix", "--extra-experimental-features", "nix-command", "store", "ping", "--store", "ssh-ng://root@127.0.0.1"], env=environment)
      args.ssh_port = 2223
      assert cli.ssh(args, ["printf", "%s", "control-transport"]) == b"control-transport"
      if len(sys.argv) == 1:
          sys.exit(0)
      args.ssh_port = 22
      try:
          cli.ssh(args, ["true"])
      except cli.Failure:
          pass
      else:
          raise AssertionError("administrative port failure must not fall back")
    '';
  };
  # @cc [owner:ghuntley,label:verification] administrative-ssh-real-port-selection
  # The host CLI MUST reach real pinned OpenSSH and Nix store transport on its
  # selected administrative port before and after a staged move of port 22 to
  # Porsche. This fixture does not install or erase a host.
  testScript = ''
    start_all()
    host.wait_for_unit("multi-user.target")
    host.wait_for_unit("sshd.service")
    host.succeed("mkdir -m 0700 /run/admin-fixture; ssh-keygen -q -t ed25519 -N ${pkgs.lib.escapeShellArg ""} -f /run/admin-fixture/client")
    for port in (2222, 2223):
        host.succeed(f"printf '[127.0.0.1]:{port} ' >> /run/admin-fixture/known_hosts; cat /etc/ssh/ssh_host_ed25519_key.pub >> /run/admin-fixture/known_hosts")
    host.succeed("python3 /etc/admin-port-check.py")
    identity = host.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub")
    host.succeed("printf '%s' porsche_gateway_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA > /run/admin-fixture/gateway.token; chmod 0600 /run/admin-fixture/gateway.token")
    host.succeed("/run/current-system/specialisation/management/bin/switch-to-configuration test")
    host.wait_for_unit("porsche.service")
    host.wait_for_open_port(22)
    host.succeed("python3 /etc/admin-port-check.py after-switch")
    assert host.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub") == identity
    management = host.succeed("ssh-keyscan -c -t ed25519 -p 22 127.0.0.1 2>/dev/null")
    assert identity.split()[1] not in management
  '';
}
