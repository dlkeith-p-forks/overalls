{ pkgs, module, packages }:
let
  # A synthetic CA trusted through the operating-system store, as the real
  # Susan certificate would be, plus a leaf for the compiled Susan origin.
  tls = pkgs.runCommand "push-notifications-fixture-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=push-notifications-test-ca \
      -addext 'basicConstraints=critical,CA:TRUE' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -keyout ca.key -out $out/ca.pem 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=notifications.overalls.dev -keyout $out/server.key -out server.csr 2>/dev/null
    printf 'subjectAltName=DNS:notifications.overalls.dev\nextendedKeyUsage=serverAuth\n' > extensions
    openssl x509 -req -in server.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
      -days 3650 -extfile extensions -out $out/server.pem 2>/dev/null
  '';
  susan = ./susan.py;
in pkgs.testers.runNixOSTest {
  name = "overalls-push-notifications";
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes.primary = { config, ... }: {
    environment.systemPackages = [ pkgs.python3 ];
    services.marshall.enable = true;
    networking.hosts."127.0.0.1" = [ "notifications.overalls.dev" ];
    security.pki.certificateFiles = [ "${tls}/ca.pem" ];
    systemd.services.overalls-fake-susan = {
      wantedBy = [ "multi-user.target" ];
      script = "exec ${pkgs.python3}/bin/python ${susan} ${tls}/server.pem ${tls}/server.key";
      serviceConfig = { UMask = "0077"; RuntimeDirectory = "push-fixture"; RuntimeDirectoryPreserve = true; };
    };
    systemd.services.overalls-push-probe = {
      script = ''
        exec ${pkgs.coreutils}/bin/env -u PORT \
          PHX_SERVER=false MARSHALL_INSTANCE_ID=push-probe MARSHALL_DB_TLS=verify \
          MARSHALL_DB_CA_CERTFILE=/run/overalls-test/ca.crt \
          MARSHALL_REPLICA_COUNT=3 MARSHALL_DB_CONNECTION_BUDGET=43 POOL_SIZE=2 \
          MARSHALL_NOTIFICATIONS_ENABLED=${if config.services.marshall.notifications.enable then "true" else "false"} \
          PHX_HOST=control.example.test RELEASE_DISTRIBUTION=none RELEASE_COOKIE=pushtest \
          ERL_CRASH_DUMP=/dev/null ${packages.marshall}/bin/marshall eval \
          'Code.eval_file("${./probe.exs}")'
      '';
      serviceConfig = { Type = "oneshot"; EnvironmentFile = "/run/overalls-test/marshall.env"; UMask = "0077"; };
    };
    specialisation.disabled.configuration.services.marshall.notifications.enable = false;
  };
  testScript = builtins.readFile ./driver.py;
}
