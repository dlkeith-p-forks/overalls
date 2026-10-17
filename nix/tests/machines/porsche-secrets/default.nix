{ pkgs, module, packages }:
let
  tools = packages.secretTools;
  bundle = {
    encryptedFile = "/run/porsche-sealed/gateway.enc.json";
    outputs.token = { format = "raw"; secrets = [ "PORSCHE_GATEWAY_TOKEN" ]; };
  };
  operator = pkgs.writeShellScriptBin "gateway-operator" ''
    exec ${pkgs.systemd}/bin/systemd-run --wait --pipe --collect \
      --unit=porsche-fixture-operator --property=Type=exec \
      --property=EnvironmentFile=/run/overalls-test/marshall.env \
      --setenv=PHX_SERVER=false --setenv=PHX_HOST=control.example.test \
      --setenv=RELEASE_DISTRIBUTION=none --setenv=RELEASE_COOKIE=isolated-operator \
      --setenv=MARSHALL_REPLICA_COUNT=3 --setenv=MARSHALL_DB_CONNECTION_BUDGET=19 \
      --setenv=POOL_SIZE=2 --setenv=MARSHALL_DB_CA_CERTFILE=/run/overalls-test/ca.crt \
      --setenv=MARSHALL_DB_TLS=verify --setenv=MARSHALL_INSTANCE_ID=porsche-operator \
      --setenv=ERL_CRASH_DUMP=/dev/null --setenv=ERL_FLAGS='+S 2:2' \
      ${pkgs.coreutils}/bin/env MARSHALL_DB_TLS=verify \
      ${packages.marshall}/bin/marshall eval 'Marshall.Operations.CLI.main()' "$@"
  '';
in pkgs.testers.runNixOSTest {
  name = "overalls-porsche-secrets";
  nodes = {
    primary = { config, lib, ... }: {
      imports = [ (import ../../support/role-node.nix { inherit module packages; }) ];
      services.marshall.enable = true;
      services.openssh = { enable = true; ports = [ 2222 ]; };
      services.overallsSecrets = { enable = true; bundles.porsche = bundle; };
      services.porsche = {
        enable = true;
        controlPlane = "https://localhost:5443";
        publicOrigin = "https://localhost:4443";
        caFile = "/run/overalls-test/ca.crt";
        credentialFile = "${config.services.overallsSecrets.bundles.porsche.directory}/token";
        secretUnits = [ config.services.overallsSecrets.bundles.porsche.unit ];
      };
      systemd.services.porsche.wantedBy = lib.mkForce [];
      environment.systemPackages = [ tools.sops tools.ssh-to-age pkgs.openssh pkgs.python3 operator ];
      environment.etc."porsche-secret-fixture.py".source = ./fixture.py;
    };
    wrong = { ... }: {
      imports = [ module ];
      services.openssh = { enable = true; ports = [ 2222 ]; };
      services.overallsSecrets = { enable = true; bundles.porsche = bundle; };
    };
  };
  # @cc [owner:ghuntley,label:verification] porsche-automatic-secret-delivery
  # This fixture MUST use real Ash gateway authority, encrypted SecretSpec/SOPS
  # publication and the actual Porsche service. Failed publication MUST preserve
  # the old bundle and block startup; authority rotation requires a fresh runtime
  # credential before readiness. Private values MUST stay outside diagnostics.
  testScript = builtins.readFile ./driver.py;
}
