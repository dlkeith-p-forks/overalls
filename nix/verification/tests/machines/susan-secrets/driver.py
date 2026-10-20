import json

client = "python3 /etc/susan-client.py"
operator = "susan-operator"
as_susan = "setpriv --reuid=susan --regid=susan --init-groups"


def call(command: str) -> dict[str, object]:
    return json.loads(relay.succeed(command).strip().splitlines()[-1])


def psql(query: str) -> str:
    return relay.succeed(f'sudo -u susan psql -At susan -c "{query}"').strip()


def publish() -> None:
    relay.succeed("systemctl stop susan.service")
    relay.succeed("systemctl restart overalls-secrets-susan.service")
    relay.succeed("systemctl start susan.service")
    relay.wait_until_succeeds("curl -sf http://127.0.0.1:4100/healthz | grep -F ok", timeout=90)


start_all()
relay.wait_for_unit("postgresql.service")
relay.wait_for_unit("fake-provider.service")
relay.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
relay.succeed("python3 /etc/susan-fixture.py seal 1")
publish()

with subtest("bundle and credential custody"):
    for name in (
        "APNS_KEY_P8",
        "APNS_KEY_ID",
        "APNS_TEAM_ID",
        "FCM_SERVICE_ACCOUNT_JSON",
        "WNS_TENANT_ID",
        "WNS_CLIENT_ID",
        "WNS_CLIENT_SECRET",
        "SUSAN_PUSH_KEY_SIGNING_KEY",
        "DATABASE_URL",
    ):
        relay.succeed(f'test "$(stat -c %U:%a /run/overalls-secrets/susan/{name})" = root:600')
        relay.fail(f"{as_susan} head -c0 /run/overalls-secrets/susan/{name}")
    relay.fail(f"{as_susan} head -c0 /etc/ssh/ssh_host_ed25519_key")
    pid = relay.succeed("systemctl show -p MainPID --value susan.service").strip()
    environment = relay.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ")
    assert "CREDENTIALS_DIRECTORY=/run/credentials/susan.service" in environment
    for line in environment.splitlines():
        assert not line.startswith(("APNS_", "FCM_", "WNS_", "SUSAN_PUSH", "DATABASE_URL")), line
    relay.wait_until_succeeds(
        'sudo -u susan psql -At susan -c "select count(*) from audit_entries '
        "where action = 'key_rotated' and keyring_id = 1\" | grep -Fx 1"
    )

with subtest("the Config custody checks refuse unsafe credential files natively"):
    relay.succeed("install -d -o susan -g susan -m 0700 /run/susan-custody")
    relay.succeed("cp -a /run/credentials/susan.service/. /run/susan-custody/")
    relay.succeed("chown -R susan:susan /run/susan-custody && chmod 0400 /run/susan-custody/*")
    config_file = relay.succeed(
        "systemctl show -p Environment --value susan.service | tr ' ' '\\n' "
        "| sed -n 's/^SUSAN_CONFIG_FILE=//p'"
    ).strip()
    check = (
        f"{as_susan} env RELEASE_DISTRIBUTION=none RELEASE_COOKIE=custody-check RELEASE_TMP=/tmp "
        "/etc/susan-release/bin/susan eval "
        f'\'IO.puts(elem(Susan.Config.load("{config_file}", "/run/susan-custody"), 0))\''
    )
    assert relay.succeed(check).strip().endswith("ok")
    relay.succeed("chmod 0644 /run/susan-custody/APNS_KEY_P8")
    assert relay.succeed(check).strip().endswith("error")
    relay.succeed("chmod 0400 /run/susan-custody/APNS_KEY_P8")
    relay.succeed("ln /run/susan-custody/APNS_TEAM_ID /run/susan-custody/linked")
    assert relay.succeed(check).strip().endswith("error")
    relay.succeed("rm /run/susan-custody/linked")
    relay.succeed(
        "mv /run/susan-custody/APNS_KEY_ID /run/susan-custody/real && "
        "ln -s real /run/susan-custody/APNS_KEY_ID"
    )
    assert relay.succeed(check).strip().endswith("error")
    relay.succeed("rm -rf /run/susan-custody")

with subtest("another host identity cannot publish the Susan bundle"):
    wrong.wait_for_unit("sshd.service")
    relay.copy_from_machine("/run/susan-sealed/susan.enc.json", "sealed")
    wrong.succeed("mkdir -m 0700 /run/susan-sealed")
    wrong.copy_from_host(
        str(relay.out_dir / "sealed/susan.enc.json"), "/run/susan-sealed/susan.enc.json"
    )
    wrong.fail("systemctl start overalls-secrets-susan.service")
    wrong.succeed("test ! -e /run/overalls-secrets/susan")
    wrong.fail("systemctl start susan.service")

with subtest("keyring rotation is audited and older push keys still open"):
    old = call(f"{client} key old apns 198.51.100.60")
    assert old["status"] == 201, old
    relay.succeed("python3 /etc/susan-fixture.py seal 2")
    publish()
    relay.wait_until_succeeds(
        'sudo -u susan psql -At susan -c "select count(*) from audit_entries '
        "where action = 'key_rotated' and keyring_id = 2\" | grep -Fx 1"
    )
    new = call(f"{client} key new apns 198.51.100.61")
    assert new["status"] == 201, new
    assert (
        psql(
            f"select keyring_id from audit_entries where action = 'key_issued' and key_id = '{new['key_id']}'"
        )
        == "2"
    )
    assert call(f"{client} poke old new 198.51.100.62 a")["status"] == 204
    assert call(f"{client} poke new new 198.51.100.62 a")["status"] == 204
    # A restart with the same active keyring does not append another rotation.
    publish()
    assert psql("select count(*) from audit_entries where action = 'key_rotated'") == "2"
    assert "intact" in relay.succeed(f"{operator} 'Susan.Operator.audit_verify()'")

with subtest("failed publication retains the previous bundle and fences startup"):
    relay.succeed("cp /run/overalls-secrets/susan/APNS_KEY_ID /root/previous")
    relay.succeed("python3 /etc/susan-fixture.py seal-missing 2 APNS_KEY_ID")
    relay.succeed("systemctl stop susan.service")
    relay.fail("systemctl restart overalls-secrets-susan.service")
    relay.succeed("cmp /root/previous /run/overalls-secrets/susan/APNS_KEY_ID")
    relay.fail("systemctl start susan.service")
    relay.fail("curl -sf http://127.0.0.1:4100/healthz")

with subtest("an invalid keyring is refused with a fixed diagnostic"):
    relay.succeed("python3 /etc/susan-fixture.py seal-invalid 2")
    relay.succeed("systemctl restart overalls-secrets-susan.service")
    relay.fail("systemctl start susan.service")
    relay.wait_until_succeeds(
        # The migration pre-start command refuses first, with one fixed message.
        "journalctl -u susan.service --no-pager -o cat "
        "| grep -F 'invalid Susan runtime configuration'"
    )
    relay.succeed("python3 /etc/susan-fixture.py seal 2")
    publish()
    assert call(f"{client} poke old new 198.51.100.63 a")["status"] == 204

with subtest("no private values in the journal or database"):
    relay.succeed("sudo -u postgres pg_dump susan > /root/susan.sql")
    relay.succeed("journalctl --no-pager -o cat > /root/journal.txt")
    relay.succeed("python3 /etc/susan-fixture.py scan /root/susan.sql /root/journal.txt")
