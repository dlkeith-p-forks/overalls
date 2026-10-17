import json

start_all()
frontends = [primary, secondary, tertiary]
validator.wait_for_unit("overalls-test-pebble.service")
addresses = json.loads(primary.succeed("cat /etc/http01-addresses.json"))
ca = validator.succeed("cat /run/overalls-test/ca.crt")
issuer = "acme-order-renew-control.example.test.service"
request = (
    "curl --fail --silent --cacert /run/overalls-test-acme-public/trust.crt "
    "--resolve control.example.test:443:127.0.0.1 "
    "https://control.example.test/health/ready"
)


def ingress(selected: list[str]) -> None:
    validator.succeed(
        "cat > /run/overalls-http01-dns/addresses.json <<'JSON'\n" + json.dumps(selected) + "\nJSON"
    )


for machine in frontends:
    machine.wait_for_unit("marshall-acme-http.service")
    machine.wait_for_unit("marshall-acme-lookup.service")
    machine.wait_for_unit("postgresql-setup.service")
    machine.succeed("systemctl start overalls-test-migrate.service")
    machine.succeed("install -d -m 0755 /run/overalls-test-acme-public")
    machine.succeed("cat > /run/overalls-test-acme-public/issuer-ca.crt <<'PEM'\n" + ca + "\nPEM")
    machine.succeed("systemctl start overalls-http01-trust.service")
    machine.wait_for_unit("overalls-http01-trust.service")

with subtest("HTTP works before any certificate and accepts only the configured hostname"):
    for machine, address in zip(frontends, addresses, strict=False):
        machine.fail("test -f /var/lib/overalls-certificates/marshall/full.pem")
        validator.succeed(
            f"test \"$(curl -s -o /dev/null -w '%{{http_code}}' -H 'Host: wrong.test' http://{address}/)\" = 421"
        )
        validator.succeed(
            f"curl -s -D /tmp/redirect -o /dev/null -H 'Host: control.example.test' 'http://{address}/example?keep=value'"
        )
        validator.succeed(
            "grep -qi '^location: https://control.example.test/example?keep=value' /tmp/redirect"
        )
        validator.succeed("grep -q '308' /tmp/redirect")

with subtest("each first certificate is validated entirely through a different frontend"):
    for index, machine in enumerate(frontends):
        ingress([addresses[(index + 1) % 3]])
        machine.succeed(f"systemctl start {issuer}", timeout=180)
        machine.wait_until_succeeds(request, timeout=120)
        machine.succeed("test $(stat -c %a /var/lib/overalls-certificates/marshall/full.pem) = 640")
        machine.succeed("test $(stat -c %a /var/lib/overalls-certificates/marshall) = 750")
    public_keys = [machine.succeed(f"{fixture} public-key").strip() for machine in frontends]
    assert len(set(public_keys)) == 3
    stats = json.loads(validator.succeed("cat /run/overalls-http01-dns/stats.json"))
    assert all(stats.get(address, 0) > 0 for address in addresses)

with subtest("simultaneous renewal through rotating DNS preserves all WebSockets"):
    ingress(addresses)
    pids = []
    for machine in frontends:
        machine.succeed(f"{fixture} snapshot")
        pids.append(
            machine.succeed("systemctl show --property=MainPID --value haproxy.service").strip()
        )
        machine.succeed(f"systemd-run --unit=overalls-test-connection {fixture} connection")
        machine.wait_until_succeeds("test -e /run/overalls-test-acme/connected", timeout=15)
    for machine in frontends:
        machine.succeed(f"systemctl start --no-block {issuer}")
    for machine, pid in zip(frontends, pids, strict=False):
        machine.wait_until_succeeds(f"{fixture} renewed", timeout=120)
        assert (
            machine.succeed("systemctl show --property=MainPID --value haproxy.service").strip()
            == pid
        )
        machine.succeed("touch /run/overalls-test-acme/finish-connection")
        machine.wait_until_succeeds(
            "test -e /run/overalls-test-acme/connection-survived", timeout=15
        )
        machine.succeed(request)

with subtest("failed validation preserves certificates; peers recover without restart"):
    primary.succeed(f"{fixture} snapshot")
    ingress([])
    primary.fail(f"systemctl start {issuer}", timeout=120)
    primary.succeed(f"{fixture} unchanged")
    primary.succeed(request)
    ingress([addresses[1]])
    primary.succeed(f"systemctl reset-failed {issuer}")
    primary.succeed(f"systemctl start {issuer}", timeout=120)
    primary.wait_until_succeeds(f"{fixture} renewed", timeout=30)

with subtest("an unavailable non-owner does not prevent issuance through the other peer"):
    tertiary.succeed("systemctl stop marshall-acme-http.service marshall-acme-lookup.service")
    ingress([addresses[1]])
    primary.succeed(f"{fixture} snapshot")
    primary.succeed(f"systemctl start {issuer}", timeout=120)
    primary.wait_until_succeeds(f"{fixture} renewed", timeout=30)
    tertiary.succeed("systemctl start marshall-acme-lookup.service marshall-acme-http.service")

with subtest("private challenge port rejects a non-peer even while a responder is listening"):
    # A private dummy responder proves rejection is the firewall, not a closed port.
    primary.succeed(
        f"systemd-run --unit=challenge-firewall-probe python3 -m http.server 9080 --bind {addresses[0]} --directory /run/overalls-test-acme-public"
    )
    primary.wait_for_unit("challenge-firewall-probe.service")
    secondary.wait_until_succeeds(
        f"curl --max-time 2 --fail --silent http://{addresses[0]}:9080/ >/dev/null", timeout=15
    )
    validator.fail(f"curl --max-time 2 --fail --silent http://{addresses[0]}:9080/ >/dev/null")
    primary.succeed("systemctl stop challenge-firewall-probe.service")

with subtest("publication retries a failed reload without another issuance"):
    primary.succeed(f"{fixture} snapshot")
    primary.succeed(f"{fixture} reject-reload")
    primary.succeed("systemctl daemon-reload")
    primary.succeed(f"systemctl start {issuer}", timeout=120)
    primary.wait_until_succeeds(f"{fixture} reload-pending", timeout=30)
    primary.succeed(request)
    primary.succeed(f"{fixture} allow-reload")
    primary.succeed("systemctl daemon-reload")
    primary.succeed("systemctl start marshall-certificate.service")
    primary.wait_until_succeeds(f"{fixture} renewed", timeout=30)

with subtest("standalone HTTP issuance requires no peer or DNS credentials"):
    ingress([addresses[0]])
    primary.succeed("$(cat /etc/http01-standalone)/bin/switch-to-configuration test", timeout=120)
    primary.wait_for_unit("marshall-acme-http.service")
    primary.succeed(f"{fixture} snapshot")
    primary.succeed(f"systemctl start {issuer}", timeout=120)
    primary.wait_until_succeeds(f"{fixture} renewed", timeout=30)
    primary.succeed(request)
    primary.succeed(
        "test ! -e /run/credentials/acme-order-renew-control.example.test.service/AWS_SHARED_CREDENTIALS_FILE"
    )

for machine in frontends:
    machine.succeed(f"{fixture} journal")
    machine.succeed(
        "! journalctl --no-pager -u marshall-acme-http -u marshall-acme-lookup | grep -E 'acme-challenge/|keep=value|ignored-http-ambient-input'"
    )
