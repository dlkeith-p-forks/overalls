{ pkgs, module, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-porsche-crash-dumps";
  nodes = {
    gateway = { lib, ... }: {
      imports = [ module (import ../../support/ssh-host-certificate.nix { inherit pkgs; role = "porsche"; }) ];
      virtualisation.memorySize = 1536;
      services.openssh = { enable = true; ports = [ 2222 ]; };
      services.porsche = {
        enable = true;
        controlPlane = "https://localhost:5443";
        publicOrigin = "https://control.example.test";
        credentialFile = "/run/porsche-fixture/gateway.token";
        crashDumps = { enable = true; publicKeyFile = "/run/porsche-fixture/public.pem"; };
      };
      systemd.services.porsche = {
        wantedBy = lib.mkForce [];
        serviceConfig.Restart = lib.mkForce "no";
        startLimitBurst = lib.mkForce 20;
      };
      environment.systemPackages = [ pkgs.python3 ];
      environment.etc."check-dumps.py".source = ./check-dumps.py;
    };
    analyst = { ... }: {
      environment.systemPackages = [ pkgs.openssl packages.toolchain.erlang pkgs.python3 ];
    };
  };
  # @cc [owner:ghuntley,label:verification] porsche-encrypted-service-capture
  # This check MUST capture from the actual Porsche service, decrypt on a separate
  # node holding the private key, and verify bounds, retention and metadata-only
  # diagnostics. No decrypted bytes or private key may enter gateway logs/exports.
  testScript = builtins.readFile ./driver.py;
}
