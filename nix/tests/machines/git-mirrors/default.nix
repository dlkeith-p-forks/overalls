{ pkgs, module, packages }:
let
  python = pkgs.python3.withPackages (p: [ p.playwright ]);
  checkedBrowser = pkgs.runCommand "git-mirrors-browser-typed" { nativeBuildInputs = [ pkgs.ty ]; } ''
    mkdir -p "$out"
    cp ${./browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
  tls = pkgs.runCommand "git-mirrors-local-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=git-mirrors-test-ca -addext 'basicConstraints=critical,CA:TRUE' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -keyout ca.key -out $out/ca.pem 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=enrico.fleet.internal -keyout $out/server.key -out server.csr 2>/dev/null
    printf 'subjectAltName=DNS:enrico.fleet.internal,DNS:github.com\nextendedKeyUsage=serverAuth\n' > extensions
    openssl x509 -req -in server.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
      -days 3650 -extfile extensions -out $out/server.pem 2>/dev/null
  '';
  token = pkgs.writeText "git-mirrors-test-token" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
in (pkgs.testers.runNixOSTest {
  name = "overalls-git-mirrors-browser";
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes.web = { config, lib, ... }: {
    virtualisation.memorySize = lib.mkForce 6144;
    virtualisation.cores = lib.mkForce 4;
    services.marshall = {
      enable = true;
      poolSize = lib.mkForce 10;
      databaseConnectionBudget = lib.mkForce 64;
      memoryMiB = lib.mkForce 3072;
      cpuCores = lib.mkForce 2;
      publicHost = lib.mkForce "localhost";
    };
    services.marshallProxy.enable = true;
    services.marshallProxy.publicHost = lib.mkForce "localhost";
    systemd.services.marshall-web.environment = {
      MARSHALL_ENRICO_URL = "https://enrico.fleet.internal:5445";
      MARSHALL_ENRICO_TOKEN_FILE = "${token}";
      MARSHALL_ENRICO_CA_FILE = "${tls}/ca.pem";
    };
    networking.extraHosts = ''
      127.0.0.1 enrico.fleet.internal
      127.0.0.2 github.com
    '';
    environment.systemPackages = [ python pkgs.chromium pkgs.nssTools pkgs.git ];
    services.nginx.enable = true;
    services.nginx.virtualHosts."github.com" = {
      forceSSL = true;
      sslCertificate = "${tls}/server.pem";
      sslCertificateKey = "${tls}/server.key";
      root = "/var/lib/git-fixture";
      listen = [{ addr = "127.0.0.2"; port = 443; ssl = true; }];
    };
    systemd.tmpfiles.rules = [ "d /var/lib/git-fixture 0755 root root -" ];
    services.enrico = {
      enable = true;
      bindAddress = "127.0.0.1";
      tokenFile = "${token}";
      certificateFile = "${tls}/server.pem";
      keyFile = "${tls}/server.key";
      cpuCores = 2;
      memoryMiB = 1024;
    };
    systemd.services.enrico.environment.GIT_SSL_CAINFO = "${tls}/ca.pem";
    systemd.services.git-mirrors-seed = {
      requires = [ "overalls-test-migrate.service" ];
      after = [ "overalls-test-migrate.service" ];
      environment = config.systemd.services.overalls-test-migrate.environment;
      serviceConfig = { Type = "oneshot"; EnvironmentFile = "/run/overalls-test/marshall.env"; };
      script = ''
        exec ${pkgs.coreutils}/bin/env -u PORT MARSHALL_INSTANCE_ID=git-mirrors-seed MARSHALL_DB_TLS=verify \
          ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./seed.exs}")'
      '';
    };
  };
  # @cc [owner:ghuntley,label:verification] enrico-public-browser-journey
  # Packaged Marshall and Enrico MUST exercise elevated mutations, ordinary
  # browsing/raw reads, retained publication after local HTTPS source failure,
  # and stale-page refusal after removal. GitHub MUST resolve only to the fixture.
  testScript = ''
    start_all()
    web.wait_for_unit("postgresql-setup.service")
    web.succeed("systemctl start overalls-test-migrate.service")
    web.wait_for_unit("nginx.service")
    web.wait_for_unit("enrico.service")
    web.wait_until_succeeds("curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost/health/ready", timeout=120)
    web.succeed("systemctl start git-mirrors-seed.service")
    web.succeed("mkdir -p /root/.pki/nssdb")
    web.succeed("certutil -N --empty-password -d sql:/root/.pki/nssdb")
    web.succeed("certutil -A -d sql:/root/.pki/nssdb -n overalls-fixture -t C,, -i /run/overalls-test/ca.crt")
    with subtest("Ordinary Git browsing and elevated catalog lifecycle"):
        web.succeed("${python}/bin/python ${checkedBrowser}/browser.py", timeout=300)
  '';
}) // { inherit checkedBrowser; }
