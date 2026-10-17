{ pkgs, module, packages }:
let
  tools = packages.secretTools;
  fixture = ./fixture.py;
in pkgs.testers.runNixOSTest {
  name = "overalls-smtp-relay";
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes = {
    primary = { config, lib, ... }: {
      environment.systemPackages = [ pkgs.python3 tools.sops tools.ssh-to-age ];
      services.marshall = {
        enable = true;
        smtpRelay = {
          enable = true;
          from = "noreply@example.test";
          secretUnits = [ config.services.overallsSecrets.bundles.smtp.unit ];
          upstream = {
            host = "localhost";
            port = 1465;
            tls = "implicit";
            caFile = "/run/overalls-test/ca.crt";
            usernameFile = "${config.services.overallsSecrets.bundles.smtp.directory}/username";
            passwordFile = "${config.services.overallsSecrets.bundles.smtp.directory}/password";
          };
        };
      };
      services.overallsSecrets = {
        enable = true;
        bundles.smtp = {
          encryptedFile = "/run/overalls-smtp-fixture/smtp.enc.json";
          outputs = {
            username = { format = "raw"; secrets = [ "SMTP_USERNAME" ]; };
            password = { format = "raw"; secrets = [ "SMTP_PASSWORD" ]; };
          };
        };
      };
      systemd.services.overalls-smtp-fixture = {
        after = [ "overalls-test-fixture.service" "sshd-keygen.service" ];
        requires = [ "overalls-test-fixture.service" "sshd-keygen.service" ];
        path = [ tools.sops tools.ssh-to-age ];
        script = "${pkgs.python3}/bin/python ${fixture} initialize";
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
      };
      systemd.services.overalls-secrets-smtp = {
        after = [ "overalls-smtp-fixture.service" ];
        requires = [ "overalls-smtp-fixture.service" ];
      };
      systemd.services.overalls-smtp-upstream = {
        wantedBy = [ "multi-user.target" ];
        after = [ "overalls-smtp-fixture.service" ];
        requires = [ "overalls-smtp-fixture.service" ];
        script = "${pkgs.python3}/bin/python ${fixture} serve";
        serviceConfig.UMask = "0077";
      };
      systemd.services.overalls-test-mail = {
        script = let mail = import ../../../../domains/system/smtp-relay/environment.nix { inherit lib; cfg = config.services.marshall.smtpRelay; }; in ''
          exec ${pkgs.coreutils}/bin/env -u PORT ${mail} \
            PHX_SERVER=false MARSHALL_INSTANCE_ID=smtp-probe MARSHALL_DB_TLS=verify \
            MARSHALL_DB_CA_CERTFILE=/run/overalls-test/ca.crt \
            MARSHALL_REPLICA_COUNT=3 MARSHALL_DB_CONNECTION_BUDGET=43 POOL_SIZE=2 \
            PHX_HOST=control.example.test RELEASE_DISTRIBUTION=none RELEASE_COOKIE=smtptest \
            ERL_CRASH_DUMP=/dev/null ${packages.marshall}/bin/marshall eval \
            'Code.eval_file("${./probe.exs}")'
        '';
        serviceConfig = { Type = "oneshot"; EnvironmentFile = "/run/overalls-test/marshall.env"; UMask = "0077"; };
      };
      specialisation.starttls.configuration.services.marshall.smtpRelay.upstream = {
        port = lib.mkForce 1587; tls = lib.mkForce "starttls"; auth = lib.mkForce "login";
      };
    };
    outsider = {
      environment.systemPackages = [ pkgs.netcat-openbsd ];
      services.overallsSecrets = {
        enable = true;
        bundles.smtp = {
          encryptedFile = "/run/overalls-smtp-fixture/smtp.enc.json";
          outputs.password = { format = "raw"; secrets = [ "SMTP_PASSWORD" ]; };
        };
      };
    };
  };
  testScript = ''
    fixture = ${builtins.toJSON "${pkgs.python3}/bin/python ${fixture}"}
    updater = ${builtins.toJSON "${../../../../domains/system/auto-update/runtime.py}"}
    secret_helper = ${builtins.toJSON "${../../../../domains/system/secrets/prepare.py}"}
  '' + builtins.readFile ./driver.py;
}
