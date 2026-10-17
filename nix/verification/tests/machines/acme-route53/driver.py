import json

start_all()
primary.wait_for_unit("overalls-test-acme-trust.service")
primary.wait_for_unit("postgresql-setup.service")
primary.succeed("systemctl start overalls-test-migrate.service")
primary.succeed("systemctl start acme-order-renew-control.example.test.service", timeout=180)
request = (
    "curl --fail --silent --cacert /run/overalls-test-acme-public/trust.crt "
    "--resolve control.example.test:443:127.0.0.1 "
    "https://control.example.test/health/ready"
)
with subtest("real DNS issuance starts the actual TLS proxy"):
    primary.wait_until_succeeds(request, timeout=180)
    primary.succeed("test $(stat -c %a /var/lib/overalls-certificates/marshall/full.pem) = 640")
    primary.succeed("test $(stat -c %a /var/lib/overalls-certificates/marshall) = 750")
    stats = json.loads(primary.succeed("cat /run/overalls-test-acme/stats.json"))
    assert stats["upserts"] >= 1 and stats["deletes"] >= 1 and stats["dns_answers"] >= 2
    assert stats["denied"] == 0

with subtest("renewal publishes a new certificate through a graceful reload"):
    primary.succeed(f"{fixture} snapshot")
    pid = primary.succeed("systemctl show --property=MainPID --value haproxy.service").strip()
    primary.succeed(f"systemd-run --unit=overalls-test-connection {fixture} connection")
    primary.wait_until_succeeds("test -e /run/overalls-test-acme/connected", timeout=15)
    primary.succeed("systemctl start acme-order-renew-control.example.test.service", timeout=120)
    primary.wait_until_succeeds(f"{fixture} renewed", timeout=30)
    assert (
        primary.succeed("systemctl show --property=MainPID --value haproxy.service").strip() == pid
    )
    primary.succeed("touch /run/overalls-test-acme/finish-connection")
    primary.wait_until_succeeds("test -e /run/overalls-test-acme/connection-survived", timeout=15)
    primary.succeed(request)

with subtest("provider failure preserves the working certificate and proxy"):
    primary.succeed(f"{fixture} snapshot")
    primary.succeed("touch /run/overalls-test-acme/deny")
    primary.fail("systemctl start acme-order-renew-control.example.test.service", timeout=120)
    primary.succeed(f"{fixture} unchanged")
    primary.succeed(request)
    primary.succeed("rm /run/overalls-test-acme/deny")
    primary.succeed(f"{fixture} journal")

with subtest("publication retries a failed reload without another issuance"):
    primary.succeed(f"{fixture} snapshot")
    primary.succeed(f"{fixture} reject-reload")
    primary.succeed("systemctl daemon-reload")
    primary.succeed("systemctl reset-failed acme-order-renew-control.example.test.service")
    primary.succeed("systemctl start acme-order-renew-control.example.test.service", timeout=120)
    primary.wait_until_succeeds(f"{fixture} reload-pending", timeout=30)
    primary.wait_until_succeeds(
        "test $(systemctl show --property=ReloadResult --value haproxy.service) = exit-code",
        timeout=30,
    )
    primary.succeed(request)
    primary.succeed(f"{fixture} allow-reload")
    primary.succeed("systemctl daemon-reload")
    primary.succeed("systemctl start marshall-certificate.service")
    primary.wait_until_succeeds(f"{fixture} renewed", timeout=30)
    primary.succeed(f"{fixture} snapshot")

with subtest("invalid replacement material cannot replace a served certificate"):
    for kind in ["wrong-name", "mismatched-key", "untrusted", "expired"]:
        primary.succeed(f"{fixture} invalid " + kind)
        primary.succeed("systemctl reset-failed marshall-certificate.service")
        primary.fail("systemctl start marshall-certificate.service")
        primary.succeed(f"{fixture} unchanged")
        # A cold proxy start must reject an invalid persistent cache, then
        # recover with the previous cache even while issuer output is bad.
        primary.succeed("systemctl stop haproxy.service")
        primary.succeed(f"{fixture} corrupt-cache")
        primary.succeed("systemctl reset-failed haproxy.service marshall-certificate.service")
        primary.fail("systemctl start haproxy.service")
        primary.succeed("systemctl stop haproxy.service")
        primary.succeed(f"{fixture} restore-cache")
        primary.succeed("systemctl reset-failed haproxy.service marshall-certificate.service")
        primary.succeed("systemctl start haproxy.service")
        primary.succeed(f"{fixture} unchanged")
        primary.succeed(request)
    primary.succeed(f"{fixture} restore")
    primary.succeed("systemctl reset-failed marshall-certificate.service")
    primary.succeed("systemctl start marshall-certificate.service")
    primary.succeed(request)
    primary.succeed(f"{fixture} journal")
