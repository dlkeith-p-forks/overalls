start_all()
primary.wait_for_unit("postgresql-setup.service")
primary.succeed("systemctl start overalls-test-migrate.service")
primary.wait_for_unit("overalls-smtprelay.service")
primary.wait_for_unit("overalls-smtp-upstream.service")
primary.wait_until_succeeds(
    "curl -fsS --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready", timeout=120
)


def probe(action: str) -> None:
    primary.succeed(f"echo {action} > /run/overalls-smtp-fixture/action")
    primary.succeed("systemctl start overalls-test-mail.service", timeout=60)


with subtest("loopback isolation and credential separation"):
    outsider.fail("nc -z -w 2 primary 2525")
    outsider.fail("nc -z -w 2 primary 9469")
    primary.succeed("curl -fsS http://127.0.0.1:9469/metrics >/dev/null")
    for unit in ("marshall-primary", "overalls-smtprelay"):
        uid = primary.succeed(
            f"stat -c %u /proc/$(systemctl show -p MainPID --value {unit})"
        ).strip()
        assert uid != "0"
        primary.fail(
            f"setpriv --reuid={uid} --regid={uid} --clear-groups head -c0 /etc/ssh/ssh_host_ed25519_key"
        )
        primary.fail(
            f"setpriv --reuid={uid} --regid={uid} --clear-groups head -c0 /run/overalls-secrets/smtp/password"
        )
    primary.succeed(f"{fixture} check")
with subtest("SMTP ciphertext is bound to its intended host identity"):
    primary.copy_from_machine("/run/overalls-smtp-fixture/smtp.enc.json", "encrypted-smtp")
    outsider.succeed("install -d -m 0700 /run/overalls-smtp-fixture")
    outsider.copy_from_host(
        str(primary.out_dir / "encrypted-smtp/smtp.enc.json"),
        "/run/overalls-smtp-fixture/smtp.enc.json",
    )
    outsider.fail("systemctl start overalls-secrets-smtp.service")
    outsider.succeed(
        "test ! -e /run/overalls-secrets/smtp/password && test ! -e /run/overalls-secrets-smtp/identity"
    )

# The isolated probe starts the real application with automatic queue consumption
# disabled, allowing deterministic inspection between actual delivery attempts.
primary.succeed("systemctl stop marshall-primary.service")
with subtest("upstream acceptance precedes local success"):
    primary.succeed(f"{fixture} delayed", timeout=20)
with subtest("provider rejection retains the encrypted outbox and stable Message-ID"):
    probe("enqueue")
    primary.succeed("echo reject > /run/overalls-smtp-fixture/behavior")
    probe("fail")
    primary.succeed(
        "cp /run/overalls-smtp-fixture/last-message /run/overalls-smtp-fixture/rejected-message"
    )
    primary.succeed(f"{fixture} check")
    primary.succeed("echo accept > /run/overalls-smtp-fixture/behavior")
    probe("deliver")
    primary.succeed(
        'python -c \'from pathlib import Path; import email; p=Path("/run/overalls-smtp-fixture"); assert email.message_from_bytes((p/"last-message").read_bytes())["Message-ID"] == email.message_from_bytes((p/"rejected-message").read_bytes())["Message-ID"]\''
    )
with subtest("relay outage and restart retain durable work"):
    probe("enqueue")
    primary.succeed("systemctl stop overalls-smtprelay.service")
    probe("fail")
    primary.succeed("systemctl start overalls-smtprelay.service")
    probe("deliver")
with subtest("stalled upstream remains bounded"):
    probe("enqueue")
    primary.succeed("echo stall > /run/overalls-smtp-fixture/behavior")
    probe("fail")
    primary.succeed("echo accept > /run/overalls-smtp-fixture/behavior")
    probe("deliver")
with subtest("missing secret preserves previous bundle and blocks relay startup"):
    primary.succeed(
        "cp /run/overalls-secrets/smtp/password /run/overalls-smtp-fixture/previous-password"
    )
    primary.succeed(f"{fixture} missing")
    primary.succeed("systemctl stop overalls-smtprelay.service")
    primary.fail("systemctl restart overalls-secrets-smtp.service")
    primary.fail("systemctl start overalls-smtprelay.service")
    primary.succeed(
        "cmp /run/overalls-secrets/smtp/password /run/overalls-smtp-fixture/previous-password"
    )
    primary.succeed(f"{fixture} seal")
    primary.succeed("systemctl restart overalls-secrets-smtp.service")
    primary.succeed("systemctl start overalls-smtprelay.service")
with subtest("provider credentials rotate through the existing secret bundle"):
    primary.succeed(f"{fixture} rotate")
    probe("enqueue")
    probe("fail")
    primary.succeed("systemctl stop overalls-smtprelay.service")
    primary.succeed("systemctl restart overalls-secrets-smtp.service")
    primary.succeed("systemctl start overalls-smtprelay.service")
    probe("deliver")
with subtest("STARTTLS and LOGIN work after a NixOS switch"):
    primary.succeed(
        "/run/current-system/specialisation/starttls/bin/switch-to-configuration test >/run/overalls-smtp-fixture/switch.log 2>&1",
        timeout=120,
    )
    primary.succeed("systemctl stop marshall-primary.service")
    primary.wait_for_unit("overalls-smtprelay.service")
    probe("enqueue")
    probe("deliver")
    primary.succeed(f"{fixture} check")

with subtest("candidate migration and descriptor-bound secret handoff"):
    primary.succeed(f"{fixture} migration", timeout=90)
    primary.succeed(f"{fixture} stage {updater} {secret_helper}")
    primary.succeed(f"{fixture} rotate")
    primary.succeed("systemctl stop overalls-smtprelay.service")
    primary.succeed(f"{fixture} handoff")
    primary.succeed("systemctl restart overalls-secrets-smtp.service")
    primary.succeed(f"{fixture} check-staged")
    primary.succeed("systemctl start overalls-smtprelay.service")
    probe("enqueue")
    probe("fail")
    primary.succeed("rm /run/overalls-auto-update/handoff.json")
    primary.succeed("systemctl stop overalls-smtprelay.service")
    primary.succeed("systemctl restart overalls-secrets-smtp.service")
    primary.succeed("systemctl start overalls-smtprelay.service")
    probe("deliver")
    primary.succeed(f"{fixture} check")
