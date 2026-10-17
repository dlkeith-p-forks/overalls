{ pkgs, module, packages }:
let
  python = pkgs.python3.withPackages (p: [ p.playwright ]);
  # @cc [owner:ghuntley,label:verification] mfa-browser-subprocess-typing
  # The browser subprocess MUST pass its own type check outside repository source
  # exclusions, using the same packaged Python and Playwright as its execution.
  checkedBrowser = pkgs.runCommand "mfa-login-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${./browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  replicas = { first = 4443; second = 4444; third = 4445; };
in (pkgs.testers.runNixOSTest {
  name = "overalls-mfa-login-browser";
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes.web = { config, lib, ... }: {
    virtualisation.memorySize = lib.mkForce 6144;
    virtualisation.cores = lib.mkForce 4;
    services.marshall = {
      enable = true;
      poolSize = lib.mkForce 10;
      databaseConnectionBudget = lib.mkForce 64;
      memoryMiB = lib.mkForce 4096;
      cpuCores = lib.mkForce 3;
      publicHost = lib.mkForce "localhost";
      instances = lib.mkForce (lib.mapAttrs (_: port: {
        inherit port;
        certificateFile = "/run/overalls-test/tls.crt";
        keyFile = "/run/overalls-test/tls.key";
      }) replicas);
    };
    services.marshallProxy = {
      enable = true;
      publicHost = lib.mkForce "localhost";
      backends = lib.mkForce (lib.mapAttrs (_: port: {
        inherit port;
        address = "127.0.0.1";
        serverName = "localhost";
      }) replicas);
    };
    # @cc [owner:ghuntley,label:security;verification] mfa-fixture-replica-routing
    # The fixture selector MUST preserve one HTTPS origin/RP and verified backend
    # TLS. Observations MUST identify the actual serving backend, including the
    # WebSocket handshake, without logging URLs, cookies or ceremony payloads.
    services.haproxy.config = lib.mkForce ''
      global
        ssl-default-bind-options ssl-min-ver TLSv1.2
        ssl-default-server-options ssl-min-ver TLSv1.2
      defaults
        mode http
        timeout connect 5s
        timeout client 60s
        timeout server 60s
        timeout tunnel 1h
        timeout check 3s
      frontend fixture
        bind 127.0.0.1:443 ssl crt /run/overalls-test-proxy/full.pem alpn h2,http/1.1
        acl public_host hdr(host),lower -m str localhost localhost:443
        http-request deny deny_status 421 unless public_host
        http-request del-header Forwarded
        http-request set-header X-Forwarded-Proto https
        http-request set-header X-Forwarded-Host localhost
        http-request set-header X-Forwarded-For %[src]
        default_backend replicas
      backend replicas
        option httpchk
        http-check send meth GET uri /health/ready ver HTTP/1.1 hdr Host localhost
        http-check expect status 200
        default-server inter 1s fall 2 rise 2
        use-server second if { req.cook(fixture_replica) -m str second }
        use-server third if { req.cook(fixture_replica) -m str third }
        use-server first if { req.cook(fixture_replica) -m str first }
        http-response set-header X-Fixture-Replica %[srv_name]
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: port:
          "server ${name} 127.0.0.1:${toString port} ssl verify required verifyhost localhost sni str(localhost) check check-ssl check-sni localhost ca-file /run/overalls-test-proxy/ca.crt") replicas)}
    '';
    environment.systemPackages = [ python pkgs.chromium pkgs.nssTools ];
    systemd.services.mfa-login-seed = {
      requires = [ "overalls-test-migrate.service" ];
      after = [ "overalls-test-migrate.service" ];
      environment = config.systemd.services.overalls-test-migrate.environment;
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = "/run/overalls-test/marshall.env";
      };
      script = ''
        exec ${pkgs.coreutils}/bin/env -u PORT MARSHALL_INSTANCE_ID=mfa-login-seed MARSHALL_DB_TLS=verify \
          ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./seed.exs}")'
      '';
    };
  };
  testScript = ''
    start_all()
    web.wait_for_unit("postgresql-setup.service")
    web.succeed("systemctl start overalls-test-migrate.service")
    for replica, port in [("first", 4443), ("second", 4444), ("third", 4445)]:
        web.wait_for_unit(f"marshall-{replica}.service")
        web.wait_until_succeeds(f"curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:{port}/health/ready", timeout=120)
    web.wait_until_succeeds("curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost/health/ready", timeout=120)
    web.succeed("systemctl start mfa-login-seed.service")
    web.succeed("mkdir -p /root/.pki/nssdb; certutil -N --empty-password -d sql:/root/.pki/nssdb")
    web.succeed("certutil -A -d sql:/root/.pki/nssdb -n overalls-fixture -t C,, -i /run/overalls-test/ca.crt")
    with subtest("Ordinary and remembered logins, inline admin step-up, cross-replica revocation and expired-ceremony refusal"):
        web.succeed("${python}/bin/python ${checkedBrowser}/browser.py", timeout=420)
  '';
}) // { inherit checkedBrowser; }
