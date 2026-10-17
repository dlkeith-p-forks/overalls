{ pkgs, module, packages }:
let
  inherit (pkgs) lib;
  python = pkgs.python3.withPackages (p: [ p.cryptography p.dnslib p.websockets ]);
  pebbleConfig = pkgs.writeText "overalls-pebble.json" (builtins.toJSON {
    pebble = {
      listenAddress = "127.0.0.1:14000";
      managementListenAddress = "127.0.0.1:15000";
      certificate = "/run/overalls-test/tls.crt";
      privateKey = "/run/overalls-test/tls.key";
      httpPort = 5002;
      tlsPort = 5001;
      certificateValidityPeriod = 172800;
      retryAfter = { authz = 1; order = 1; };
    };
  });
  fixture = "${python}/bin/python ${../../support/acme-fixture.py}";
in
pkgs.testers.runNixOSTest {
  name = "overalls-acme-route53";
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes.primary = { config, ... }: {
    # Lego resolves the authoritative NS hostname through the system resolver,
    # separately from its explicitly configured recursive DNS queries.
    networking.nameservers = [ "127.0.0.1" ];
    networking.dhcpcd.extraConfig = "nooption domain_name_servers";
    services.marshall.enable = true;
    services.marshallProxy = {
      enable = true;
      acme = {
        enable = true;
        email = "fixture@example.test";
        challengeType = "dns-01";
        route53.hostedZoneId = "ZOVERALLS";
        route53.credentialsFile = "${config.services.overallsSecrets.bundles.route53.directory}/credentials";
        secretUnits = [ config.services.overallsSecrets.bundles.route53.unit "overalls-test-acme-trust.service" ];
        server = "https://localhost:14000/dir";
        route53.endpoint = "https://localhost:8443";
        route53.dnsResolver = "127.0.0.1:53";
        caFile = "/run/overalls-test-acme-public/trust.crt";
      };
    };
    security.acme = {
      acceptTerms = true;
      certs."control.example.test".validMinDays = 3;
    };
    services.overallsSecrets = {
      enable = true;
      bundles.route53 = {
        encryptedFile = "/run/overalls-test-acme/route53.enc.json";
        outputs.credentials = { format = "raw"; secrets = [ "AWS_CREDENTIALS" ]; };
      };
    };
    systemd.services.overalls-test-acme-fixture = {
      after = [ "overalls-test-fixture.service" "sshd-keygen.service" ];
      requires = [ "overalls-test-fixture.service" "sshd-keygen.service" ];
      path = [ packages.secretTools.sops packages.secretTools.ssh-to-age pkgs.openssh ];
      script = "${fixture} setup";
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
    };
    systemd.services.overalls-secrets-route53 = {
      after = [ "overalls-test-acme-fixture.service" ];
      requires = [ "overalls-test-acme-fixture.service" ];
    };
    systemd.services.overalls-test-route53 = {
      after = [ "overalls-test-acme-fixture.service" ];
      requires = [ "overalls-test-acme-fixture.service" ];
      serviceConfig = {
        ExecStart = "${python}/bin/python ${./route53.py}";
        UMask = "0077";
      };
    };
    systemd.services.overalls-test-pebble = {
      after = [ "overalls-test-route53.service" ];
      requires = [ "overalls-test-route53.service" ];
      environment = {
        PEBBLE_VA_NOSLEEP = "1";
        PEBBLE_VA_ALWAYS_VALID = "0";
        PEBBLE_WFE_NONCEREJECT = "0";
        PEBBLE_AUTHZREUSE = "0";
      };
      serviceConfig.ExecStart = "${pkgs.pebble}/bin/pebble -config ${pebbleConfig} -dnsserver 127.0.0.1:53";
    };
    systemd.services.overalls-test-acme-trust = {
      after = [ "overalls-test-pebble.service" ];
      requires = [ "overalls-test-pebble.service" ];
      script = "${fixture} trust";
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
    };
    # A leaked ambient provider configuration would defeat the selected file.
    systemd.services."acme-order-renew-control.example.test".environment = {
      AWS_ACCESS_KEY_ID = "ignored-ambient-input";
      AWS_SECRET_ACCESS_KEY = "ignored-ambient-input";
    };
  };
  testScript = ''
    fixture = ${builtins.toJSON fixture}
  '' + builtins.readFile ./driver.py;
}
