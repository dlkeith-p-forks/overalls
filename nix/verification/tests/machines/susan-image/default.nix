{ pkgs, packages }:
let
  python = pkgs.python3.withPackages (ps: [ ps.cryptography ]);
  config = pkgs.writeText "susan-image-config.json" (builtins.toJSON {
    version = 1;
    bind = "127.0.0.1";
    port = 4100;
    trusted_proxies = [ "127.0.0.1" ];
    apns_topics = [ "dev.overalls.mila" ];
    fcm_app_ids = [ ];
  });
in pkgs.testers.runNixOSTest {
  name = "overalls-susan-image";
  nodes.host = { pkgs, ... }: {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;
    virtualisation.podman.enable = true;
    services.postgresql = {
      enable = true;
      enableTCPIP = true;
      authentication = "host susan susan 127.0.0.1/32 scram-sha-256\n";
      ensureDatabases = [ "susan" ];
      ensureUsers = [{ name = "susan"; ensureDBOwnership = true; }];
    };
    environment.etc."susan-image-stream".source = packages.susanImage;
    environment.etc."susan-image-config.json".source = config;
    environment.etc."susan-fixture.py".source = ../susan-service/fixture.py;
    environment.systemPackages = [ python pkgs.curl pkgs.jq ];
  };
  # @cc [owner:ghuntley,label:verification] susan-image-fixture-scope
  # The streamLayeredImage artifact under rootful podman: non-root numeric
  # user, read-only root filesystem with tmpfs /tmp, no shell, runtime-only
  # credential files, a separate migration command and no secret bytes in any
  # image layer or container filesystem export.
  testScript = builtins.readFile ./driver.py;
}
