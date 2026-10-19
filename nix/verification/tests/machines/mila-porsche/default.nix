{ pkgs, module, packages }:
let
  host = "control.example.test";
  other = "other.example.test";
  trust = ca: name: pkgs.writeText "trust-${name}.json" (builtins.toJSON {
    version = 1;
    inherit ca;
    management_host = name;
    zone = "machines.example.test";
    retirement = 4102444800;
  });
  fixtureCa = pkgs.lib.removeSuffix "\n" (builtins.readFile ../../fixtures/ssh-host-ca/key.pub);
in
pkgs.testers.runNixOSTest {
  name = "overalls-mila-porsche";
  nodes.gateway = { ... }: {
    imports = [ module (import ../../support/ssh-host-certificate.nix { inherit pkgs; role = "porsche"; }) ];
    virtualisation.memorySize = 1536;
    # Porsche owns port 22; administrative OpenSSH moves aside, as deployed.
    services.openssh = { enable = true; ports = [ 2222 ]; };
    services.porsche = {
      enable = true;
      package = packages.porsche;
      controlPlane = "https://localhost:5443";
      publicOrigin = "https://${host}";
      credentialFile = "/run/porsche-fixture/gateway.token";
      secretUnits = [ "porsche-fixture.service" ];
      openFirewall = true;
    };
    systemd.services.porsche-fixture = {
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
      script = ''
        mkdir -p /run/porsche-fixture
        printf '%s\n' 'porsche_gateway_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' > /run/porsche-fixture/gateway.token
      '';
    };
  };
  nodes.client = { nodes, ... }: {
    networking.hosts.${nodes.gateway.networking.primaryIPAddress} = [ host other ];
    environment.systemPackages = [ packages.mila.probe pkgs.openssh pkgs.jq ];
    environment.etc."mila/trust.json".source = trust fixtureCa host;
    # The gateway's certificate names only ${host}; this pin is for a host
    # name the same CA never certified.
    environment.etc."mila/trust-other.json".source = trust fixtureCa other;
  };
  # @cc [owner:ghuntley,label:verification] mila-porsche-test-scope
  # This check MUST drive Mila's production transport (patched dartssh2, host
  # certificate verification, P-256 device key) against the real Porsche
  # release and module. It proves interoperability, refusal before
  # authentication and key custody only: Marshall is absent, so sign-in
  # approval and domain commands are not claimed here.
  testScript = ''
    import json

    def probe(*arguments):
        return json.loads(client.succeed("mila-probe --keys /root/mila-keys " + " ".join(arguments)))

    def authenticated():
        return int(gateway.succeed("journalctl -u porsche.service --no-pager -o cat | grep -c porsche.authenticated || true").strip())

    start_all()
    gateway.wait_for_unit("porsche.service")
    gateway.wait_for_open_port(22, timeout=60)
    client.wait_for_unit("multi-user.target")

    with subtest("the device key is owner-only and P-256"):
        line = client.succeed("mila-probe --keys /root/mila-keys --host ${host} --public-key").strip()
        assert line.startswith("ecdsa-sha2-nistp256 "), line
        assert client.succeed("stat -c %a /root/mila-keys/${host}.json").strip() == "600"
        assert client.succeed("stat -c %a /root/mila-keys").strip() == "700"

    with subtest("a certificate from another CA is refused before authentication"):
        client.succeed("ssh-keygen -q -t ed25519 -N ''' -f /root/rogue-ca")
        client.succeed(
            "jq --arg ca \"$(cut -d' ' -f1-2 /root/rogue-ca.pub)\" '.ca = $ca' /etc/mila/trust.json > /root/trust-rogue.json"
        )
        before = authenticated()
        report = probe("--host ${host} --trust /root/trust-rogue.json --command 'whoami --json'")
        assert report == {"connected": False, "failure": "hostUntrusted"}, report
        assert authenticated() == before

    with subtest("a certificate that does not name the pinned host is refused"):
        before = authenticated()
        report = probe("--host ${other} --trust /etc/mila/trust-other.json --command 'whoami --json'")
        assert report == {"connected": False, "failure": "hostUntrusted"}, report
        assert authenticated() == before

    with subtest("the pinned CA's certificate and the device key reach Porsche"):
        before = authenticated()
        report = probe("--host ${host} --trust /etc/mila/trust.json --command 'whoami --json'")
        print(report)
        assert report["connected"] is True, report
        assert authenticated() == before + 1
        # Marshall is absent: Porsche authenticated the key, then reports its
        # failed Marshall exchange as a decoded authority error envelope.
        assert report["exit"] == "authority", report
        assert report["reply"] == "error:transport_error", report

    with subtest("Porsche never logs the device key"):
        encoded = line.split()[1]
        gateway.fail(f"journalctl --no-pager -o cat | grep -F {encoded[:40]}")
  '';
}
