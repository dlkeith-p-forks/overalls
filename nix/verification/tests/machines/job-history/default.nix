{ pkgs, module, packages }:
let
  python = pkgs.python3.withPackages (p: [ p.playwright ]);
  tools = packages.secretTools;
  smtpFixture = ../smtp-relay/fixture.py;
  # @cc [owner:ghuntley,label:verification] job-history-browser-subprocess-typing
  # The executed standalone browser artifact MUST pass pinned typing with its
  # actual Python/Playwright closure before native execution.
  checkedBrowser = pkgs.runCommand "job-history-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${./browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
in (pkgs.testers.runNixOSTest {
  name = "overalls-job-history-browser";
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes.web = { config, lib, ... }: {
    virtualisation.memorySize = lib.mkForce 4096;
    services.marshall = {
      enable = true;
      poolSize = lib.mkForce 10;
      databaseConnectionBudget = lib.mkForce 64;
      publicHost = lib.mkForce "localhost";
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
    services.marshallProxy = { enable = true; publicHost = lib.mkForce "localhost"; };
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
    environment.systemPackages = [ python pkgs.chromium pkgs.nssTools tools.sops tools.ssh-to-age ];
    systemd.services.overalls-smtp-fixture = {
      after = [ "overalls-test-fixture.service" "sshd-keygen.service" ];
      requires = [ "overalls-test-fixture.service" "sshd-keygen.service" ];
      path = [ tools.sops tools.ssh-to-age ];
      script = "${pkgs.python3}/bin/python ${smtpFixture} initialize";
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
      script = "${pkgs.python3}/bin/python ${smtpFixture} serve";
      serviceConfig.UMask = "0077";
    };
    systemd.services.job-history-seed = {
      requires = [ "overalls-test-migrate.service" ];
      after = [ "overalls-test-migrate.service" ];
      environment = config.systemd.services.overalls-test-migrate.environment;
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = "/run/overalls-test/marshall.env";
        UMask = "0077";
      };
      script = ''
        exec ${pkgs.coreutils}/bin/env -u PORT MARSHALL_INSTANCE_ID=job-history-seed MARSHALL_DB_TLS=verify \
          ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./seed.exs}")'
      '';
    };
  };
  testScript = ''
    start_all()
    web.wait_for_unit("postgresql-setup.service")
    web.succeed("systemctl start overalls-test-migrate.service")
    web.wait_for_unit("overalls-smtprelay.service")
    web.wait_for_unit("overalls-smtp-upstream.service")
    web.wait_until_succeeds("curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost/health/ready", timeout=120)
    web.succeed("systemctl start job-history-seed.service")
    web.succeed("mkdir -p /root/.pki/nssdb; certutil -N --empty-password -d sql:/root/.pki/nssdb")
    web.succeed("certutil -A -d sql:/root/.pki/nssdb -n overalls-fixture -t C,, -i /run/overalls-test/ca.crt")
    with subtest("Actual failed mail worker, audited browser retry and retained safe history"):
        web.succeed("${python}/bin/python ${checkedBrowser}/browser.py", timeout=240)
  '';
}) // { inherit checkedBrowser; }
