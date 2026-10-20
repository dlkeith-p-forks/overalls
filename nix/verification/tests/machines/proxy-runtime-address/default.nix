{ pkgs, module }:
let
  tls = pkgs.runCommand "proxy-runtime-address-disposable-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p "$out"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$out/key.pem" -out "$out/cert.pem" \
      -days 3650 -subj /CN=overalls.test -addext subjectAltName=DNS:overalls.test
    cat "$out/key.pem" "$out/cert.pem" > "$out/full.pem"
  '';
in pkgs.testers.runNixOSTest {
  name = "overalls-proxy-runtime-address";
  nodes.server = { config, lib, ... }: {
    imports = [ module ];
    networking.enableIPv6 = false;
    # The perimeter is covered by fleet-firewall tests; this fixture proves
    # which addresses the listeners bind, so nothing filters the client.
    networking.firewall.enable = false;
    services.marshallProxy = {
      enable = true; publicHost = "overalls.test";
      bindAddressFile = "/run/test-address/ipv4";
      bindAddressUnit = "test-address.service";
      openFirewall = false;
      certificateFile = "/run/test-address/full.pem";
      secretUnits = [ "test-address.service" ];
      backends.local = { address = "127.0.0.1"; serverName = "overalls.test"; };
    };
    # Stands in for the decrypted SOPS address bundle. An override file lets
    # the script publish malformed and wildcard values.
    systemd.services.test-address = {
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; RuntimeDirectory = "test-address"; RuntimeDirectoryPreserve = true; };
      script = ''
        install -m 0640 -g haproxy ${tls}/full.pem /run/test-address/full.pem
        if [ -e /etc/test-address-override ]; then
          cat /etc/test-address-override > /run/test-address/ipv4
        else
          printf '%s\n' ${config.networking.primaryIPAddress} > /run/test-address/ipv4
        fi
      '';
    };
    systemd.sockets.relay-demo = {
      socketConfig.FreeBind = true;
    };
    overalls.runtimeSockets.relay-demo = {
      addressFile = "/run/test-address/ipv4";
      addressUnit = "test-address.service";
      port = 5443;
    };
    systemd.services.relay-demo = {
      requires = [ "relay-demo-backend.service" ];
      after = [ "relay-demo-backend.service" ];
      serviceConfig.ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd 127.0.0.1:8080";
    };
    systemd.services.relay-demo-backend = {
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080 --bind 127.0.0.1 --directory ${pkgs.writeTextDir "index.html" "relay"}";
    };
    environment.systemPackages = [ pkgs.curl ];
  };
  nodes.client = { nodes, ... }: {
    networking.hosts.${nodes.server.networking.primaryIPAddress} = [ "overalls.test" ];
    environment.etc."proxy-test-ca.pem".source = "${tls}/cert.pem";
    environment.systemPackages = [ pkgs.curl ];
  };
  # @cc [owner:ghuntley,label:verification;security] proxy-runtime-address-native-binds
  # Real HAProxy and systemd socket units MUST bind only the validated runtime
  # address. An empty or wildcard runtime value MUST leave the listeners down
  # rather than listening on every address, and a restored value MUST recover.
  testScript = { nodes, ... }: let address = nodes.server.networking.primaryIPAddress; in ''
    address: str = "${address}"

    def listeners(port: int) -> list[str]:
        output: str = server.succeed(f"ss -ltnH 'sport = :{port}' | awk '{{print $4}}'")
        return sorted(set(output.split()))

    def https_reaches() -> None:
        # The fixture backend is absent, so HAProxy answers 503 after TLS.
        client.wait_until_succeeds("test $(curl --cacert /etc/proxy-test-ca.pem -s -o /dev/null -w '%{http_code}' https://overalls.test/) = 503")

    def publish(value: str | None) -> None:
        if value is None:
            server.succeed("rm -f /etc/test-address-override")
        else:
            server.succeed(f"printf '%s' '{value}' > /etc/test-address-override")
        server.execute("systemctl restart test-address.service")

    start_all()
    server.wait_for_unit("haproxy.service")
    server.wait_for_unit("overalls-runtime-socket-relay-demo.service")
    server.wait_until_succeeds("systemctl is-active relay-demo.socket")

    with subtest("haproxy binds only the runtime address"):
        assert listeners(443) == [f"{address}:443"], listeners(443)
        server.succeed("grep -qx 'MARSHALL_PROXY_BIND_IPV4=${address}' /run/marshall-proxy-address/address.env")
        server.succeed("test $(stat -c %a /run/marshall-proxy-address/address.env) = 600")
        server.fail("curl -k --max-time 3 -s https://127.0.0.1/")
        https_reaches()

    with subtest("runtime socket drop-in binds the runtime address"):
        server.succeed("grep -qx 'ListenStream=${address}:5443' /run/systemd/system/relay-demo.socket.d/50-address.conf")
        assert listeners(5443) == [f"{address}:5443"], listeners(5443)
        server.succeed("systemctl show -p FreeBind --value relay-demo.socket | grep -qx yes")
        client.wait_until_succeeds("curl -fsS --max-time 3 http://${address}:5443/ | grep -qx relay")
        server.fail("curl --max-time 3 -s http://127.0.0.1:5443/")

    with subtest("the guard refuses empty and wildcard values"):
        guard: str = "${nodes.server.services.marshallProxy.addressGuard}"
        server.fail(f"env -u MARSHALL_PROXY_BIND_IPV4 {guard}")
        server.fail(f"MARSHALL_PROXY_BIND_IPV4= {guard}")
        server.fail(f"MARSHALL_PROXY_BIND_IPV4=0.0.0.0 {guard}")
        server.fail(f"MARSHALL_PROXY_BIND_IPV4='198.51.100.7 ' {guard}")
        server.succeed(f"MARSHALL_PROXY_BIND_IPV4=198.51.100.7 {guard}")

    for value in ["", "0.0.0.0", "203.0.113.300"]:
        with subtest(f"runtime value {value!r} leaves every listener down"):
            publish(value)
            # Restart propagates through Requires=; wait for the refused restarts.
            server.wait_until_succeeds("systemctl is-failed marshall-proxy-address.service")
            server.wait_until_succeeds("systemctl is-failed overalls-runtime-socket-relay-demo.service")
            server.wait_until_fails("systemctl is-active haproxy.service")
            server.fail("test -e /run/marshall-proxy-address/address.env")
            server.fail("test -e /run/systemd/system/relay-demo.socket.d/50-address.conf")
            server.wait_until_fails("systemctl is-active relay-demo.socket")
            # A start attempt must still refuse rather than bind a wildcard.
            server.fail("systemctl start haproxy.service")
            assert listeners(443) == [], listeners(443)
            assert listeners(5443) == [], listeners(5443)

    with subtest("a restored runtime value recovers both listeners"):
        publish(None)
        server.succeed("systemctl start haproxy.service overalls-runtime-socket-relay-demo.service")
        server.wait_until_succeeds("systemctl is-active relay-demo.socket")
        assert listeners(443) == [f"{address}:443"], listeners(443)
        assert listeners(5443) == [f"{address}:5443"], listeners(5443)
        https_reaches()
        client.wait_until_succeeds("curl -fsS --max-time 3 http://${address}:5443/ | grep -qx relay")
  '';
}
