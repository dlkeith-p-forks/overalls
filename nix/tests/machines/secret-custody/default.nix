{ pkgs, module, packages, hegel }:
let
  inherit (pkgs) lib;
  tools = packages.secretTools;
  names = [
    "DATABASE_URL" "MARSHALL_CLOAK_KEYS" "SECRET_KEY_BASE" "TOKEN_SIGNING_SECRET"
    "MARSHALL_SMTP_HOST" "MARSHALL_SMTP_USERNAME" "MARSHALL_SMTP_PASSWORD"
    "MARSHALL_SMTP_CA_CERTFILE" "MARSHALL_MAIL_FROM"
  ];
  common = { config, ... }: {
    # This suite explicitly exercises SSH daemon restarts during host rotation.
    services.openssh.enable = true;
    services.overallsSecrets = {
      enable = true;
      bundles.marshall = {
        encryptedFile = "/run/overalls-test-sealed/marshall.enc.json";
        outputs.environment = { format = "environment"; secrets = names; };
        outputs."serper.key" = { format = "raw"; secrets = [ "SERPER_API_KEY" ]; };
      };
    };
    environment.systemPackages = [ tools.sops tools.ssh-to-age pkgs.openssh pkgs.python3 ];
    # Hegel chains restart/stop sequences deliberately; default start-rate
    # limits would (correctly) fence the services, which is outside the
    # properties under test. Tame them only inside this check.
    systemd.services.overalls-secrets-marshall.serviceConfig.StartLimitBurst = pkgs.lib.mkForce 0;
    systemd.services.overalls-secrets-marshall.unitConfig.StartLimitIntervalSec = pkgs.lib.mkForce 0;
  };
in
hegel.runTest {
  name = "overalls-secret-custody";
  properties = {
    enable = true;
    profile = "ci";
    testCases = 6;
    statefulStepCount = 18;
    # This check draws synthetic secret values: the Hegel report MUST NOT
    # print drawn values, exception values or reproduce blobs into the
    # driver log. Only failure origins (property/rule locations) are shown.
    redact = true;
  };
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes = {
    primary = { config, ... }: {
      imports = [ common ];
      system.switch.enable = true;
      specialisation.secret-rebuild.configuration.environment.etc."overalls-test-generation".text = "rebuilt";
      services.marshall = {
        enable = true;
        environmentFile = lib.mkForce "${config.services.overallsSecrets.bundles.marshall.directory}/environment";
        serperKeyFile = "${config.services.overallsSecrets.bundles.marshall.directory}/serper.key";
        secretUnits = [ config.services.overallsSecrets.bundles.marshall.unit ];
      };
      users.groups.fixture-readers = {};
      users.users.fixture-reader = { isSystemUser = true; group = "fixture-readers"; };
      users.users.fixture-outsider = { isSystemUser = true; group = "nogroup"; };
      # See the rate-limit note in `common`: the state machine restarts
      # Marshall in chains.
      systemd.services.marshall-primary.serviceConfig.StartLimitBurst = pkgs.lib.mkForce 0;
      systemd.services.marshall-primary.unitConfig.StartLimitIntervalSec = pkgs.lib.mkForce 0;
      services.overallsSecrets.bundles.shared = {
        encryptedFile = "/run/overalls-test-sealed/marshall.enc.json";
        group = "fixture-readers";
        outputs.token = { format = "raw"; secrets = [ "FIXTURE_TOKEN" ]; };
      };
      systemd.services.overalls-test-seal = {
        after = [ "overalls-test-fixture.service" "sshd-keygen.service" ];
        requires = [ "overalls-test-fixture.service" "sshd-keygen.service" ];
        path = [ tools.sops tools.ssh-to-age pkgs.openssh ];
        script = "${pkgs.python3}/bin/python ${./fixture.py} seal";
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      };
      systemd.services.overalls-secrets-marshall = {
        after = [ "overalls-test-seal.service" ];
        requires = [ "overalls-test-seal.service" ];
      };
      systemd.services.overalls-secrets-shared = {
        after = [ "overalls-test-seal.service" ];
        requires = [ "overalls-test-seal.service" ];
      };
    };
    wrong = { imports = [ common ]; };
  };
  testScript = ''
    seal_fixture = ${builtins.toJSON "${./fixture.py}"}
    prepare_module = ${builtins.toJSON "${../../../modules/secrets/prepare.py}"}
    module_boundaries = ${builtins.toJSON "${./properties.py}"}
  '' + builtins.readFile ./driver.py;
}
