{ pkgs, module, packages }:
let
  relay = import ../susan-service/relay.nix { inherit pkgs packages; };
  # A synthetic CA that the Marshall node trusts through the operating-system
  # store, as it would trust the real Susan certificate, plus a leaf for the
  # compiled Susan origin served by the relay node's TLS proxy.
  tls = pkgs.runCommand "push-relay-fixture-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=push-relay-test-ca \
      -addext 'basicConstraints=critical,CA:TRUE' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -keyout ca.key -out $out/ca.pem 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=notifications.overalls.dev -keyout $out/server.key -out server.csr 2>/dev/null
    printf 'subjectAltName=DNS:notifications.overalls.dev\nextendedKeyUsage=serverAuth\n' > extensions
    openssl x509 -req -in server.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
      -days 3650 -extfile extensions -out $out/server.pem 2>/dev/null
  '';
in pkgs.testers.runNixOSTest {
  name = "overalls-push-relay";
  # @cc [owner:ghuntley,label:verification] push-relay-fixture-scope
  # The packaged Marshall release delivers through the packaged Susan release
  # over verify_peer TLS at the compiled origin, and Susan forwards to local
  # fake APNs/OAuth/FCM origins. The fake origins MUST NOT be represented as
  # Apple or Google acceptance, and the fixture MUST NOT print push keys,
  # private keys or poke bodies.
  nodes.relay = { config, ... }: {
    imports = [ module relay.node ];
    networking.firewall.allowedTCPPorts = [ 443 ];
    # The fake providers own 127.0.0.1:443, so the Susan proxy listens on the
    # test network address only.
    services.nginx = {
      enable = true;
      virtualHosts."notifications.overalls.dev" = {
        listen = [ { addr = config.networking.primaryIPAddress; port = 443; ssl = true; } ];
        onlySSL = true;
        sslCertificate = "${tls}/server.pem";
        sslCertificateKey = "${tls}/server.key";
        locations."/".proxyPass = "http://127.0.0.1:4100";
      };
    };
  };
  nodes.primary = { nodes, ... }: {
    imports = [ (import ../../support/role-node.nix { inherit module packages; }) ];
    environment.systemPackages = [ pkgs.python3 ];
    services.marshall.enable = true;
    networking.hosts.${nodes.relay.networking.primaryIPAddress} = [ "notifications.overalls.dev" ];
    security.pki.certificateFiles = [ "${tls}/ca.pem" ];
    systemd.tmpfiles.rules = [ "d /run/push-fixture 0700 root root -" ];
    systemd.services.overalls-push-probe = {
      script = ''
        exec ${pkgs.coreutils}/bin/env -u PORT \
          PHX_SERVER=false MARSHALL_INSTANCE_ID=push-relay-probe MARSHALL_DB_TLS=verify \
          MARSHALL_DB_CA_CERTFILE=/run/overalls-test/ca.crt \
          MARSHALL_REPLICA_COUNT=3 MARSHALL_DB_CONNECTION_BUDGET=43 POOL_SIZE=2 \
          MARSHALL_NOTIFICATIONS_ENABLED=true \
          PHX_HOST=control.example.test RELEASE_DISTRIBUTION=none RELEASE_COOKIE=pushrelay \
          ERL_CRASH_DUMP=/dev/null ${packages.marshall}/bin/marshall eval \
          'Code.eval_file("${./probe.exs}")'
      '';
      serviceConfig = { Type = "oneshot"; EnvironmentFile = "/run/overalls-test/marshall.env"; UMask = "0077"; };
    };
  };
  testScript = builtins.readFile ./driver.py;
}
