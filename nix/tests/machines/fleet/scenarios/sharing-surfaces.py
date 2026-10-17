# @cc [owner:ghuntley,label:verification;security] sharing-surfaces-composed-fleet-journey
# One ordinary member concurrently holds live Audi SSH, a shared read-only
# browser terminal and private web streams on one nested guest; one direct
# share revocation MUST close all three within the documented bounds (terminal
# within its one-second viewer recheck plus dispatch margin, SSH within the
# five-second guarantee TTL, private web before the next renewal) while the
# guest origin counters prove refused traffic never contacted the guest.
# Re-sharing MUST restore fresh admission with new lease artifacts only.


def sharing_wait_unit(unit: str, marker: str) -> None:
    def ready() -> bool:
        state = client.succeed(
            "systemctl show " + shlex.quote(unit) + " --property=ActiveState --value"
        ).strip()
        assert state != "failed", "Sharing surface fixture failed before readiness: " + unit
        return client.execute("test -f " + shlex.quote(marker))[0] == 0

    eventually(ready, timeout=30)


def sharing_web_counts(ssh_base: list[str]) -> dict[str, int]:
    """Guest-owned counters, read as the never-revoked owner over real SSH."""
    parsed = json.loads(
        client.wait_until_succeeds(
            ssh_environment + shlex.join([*ssh_base, "cat /tmp/private-web-counts.json"]),
            timeout=30,
        )
    )
    assert isinstance(parsed, dict)
    counts: dict[str, int] = {}
    assert set(parsed) == {"http", "stream", "stream_closed", "ws", "ws_closed", "echoes"}
    for name, value in parsed.items():
        assert isinstance(name, str) and isinstance(value, int) and not isinstance(value, bool)
        counts[name] = value
    return counts


with subtest("sharing surfaces: Audi DNS nodes, gateways and fleet certificate"):
    # Same real Audi bootstrap as the audi-fleet journey: runtime credentials,
    # DNS roles, gateway keys and one ACME-issued wildcard certificate.
    for machine in [m2, m3]:
        path = f"{root}/audi-{machine.name}.token"
        operator(
            m1, dict(action="audi-enroll", role="dns", name="audi-" + machine.name, output=path)
        )
        transfer(m1, path, machine, root + "/audi.token")
        machine.wait_for_unit("audi-dns.service")
        machine.wait_for_open_port(53)
    m1.succeed("systemctl start fleet-audi-ca.service")
    m1.wait_for_open_port(14000)
    m1.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt --resolve m1:15000:127.0.0.1 https://m1:15000/roots/0 >{root}/audi-root.pem"
    )
    for machine in provisioners:
        address = client.succeed(
            "python3 -c "
            + shlex.quote("import socket; print(socket.gethostbyname(" + repr(machine.name) + "))")
        ).strip()
        path = f"{root}/audi-{machine.name}.token"
        operator(
            m1,
            dict(
                action="audi-enroll",
                role="gateway",
                name="audi-" + machine.name,
                host_id=host_bindings[machine.name]["host"],
                addresses=[address],
                output=path,
            ),
        )
        transfer(m1, root + "/audi-root.pem", machine, root + "/audi-root.pem")
        transfer(m1, path, machine, root + "/audi.token")
        machine.wait_for_unit("audi.service")
        machine.wait_for_open_port(22)
    transfer(m1, root + "/audi-root.pem", client, root + "/audi-root.pem")
    eventually(
        lambda: sql("SELECT count(*) FROM ingress_fleet_certificates WHERE status='active'") == "1",
        timeout=360,
    )

    def sharing_browser_phase() -> dict[str, object]:
        try:
            parsed = json.loads(client.succeed("cat /var/lib/fleet-sharing/state.json"))
        except Exception:
            return {"phase": "starting"}
        assert isinstance(parsed, dict)
        return parsed

    def sharing_await_browser(phase: str, timeout: int) -> dict[str, object]:
        """Phase waits carry bounded diagnostics: the unit's closed stage event
        only, never page content, URLs, cookies or terminal bytes."""
        try:
            eventually(lambda: sharing_browser_phase()["phase"] == phase, timeout=timeout)
        except AssertionError:
            print(
                "Sharing browser status:",
                client.succeed(
                    "systemctl show sharing-surfaces-browser.service --property=ExecMainStatus --value"
                ).strip(),
            )
            print(
                client.succeed(
                    "journalctl -u sharing-surfaces-browser.service --no-pager -o cat -n 8"
                )
            )
            raise
        return sharing_browser_phase()


with subtest("one member concurrently holds shared terminal, Audi SSH and private web"):
    vm = provision_when_available(m1, "standard")
    await_running(vm["vm_id"])
    before = process_snapshot(vm)
    host_for(vm).wait_until_succeeds(
        "fleet-audi-guest " + shlex.quote(vm["placement_id"]), timeout=180
    )
    policy = operator(
        m1,
        dict(
            action="audi-policy",
            owner_id=users["owner_id"],
            vm_id=vm["vm_id"],
            visibility="private",
        ),
    )
    sharing_label = str(policy["label"])
    sharing_hostname = sharing_label + ".apps.example.test"

    sharing_dir = "/var/lib/fleet-sharing"
    client.succeed(
        "install -d -m 700 -o tester -g users "
        + sharing_dir
        + " /home/tester/.ssh /home/tester/.pki/nssdb"
    )
    client.succeed("install -d -m 755 /var/lib/fleet-audi")
    client.succeed("sudo -u tester certutil -N -d sql:/home/tester/.pki/nssdb --empty-password")
    for name in ("ca.crt", "audi-root.pem"):
        client.succeed(f"install -m 644 {root}/{name} /var/lib/fleet-audi/{name}")
        client.succeed(f"install -m 644 {root}/{name} {sharing_dir}/{name}")
        client.succeed(
            f"sudo -u tester certutil -A -d sql:/home/tester/.pki/nssdb -n sharing-{name} -t 'C,,' -i /var/lib/fleet-audi/{name}"
        )

    ssh_ca = m1.succeed("ssh-keygen -y -f " + root + "/ssh-host-ca").strip()
    client.succeed(
        "printf '%s\\n' "
        + shlex.quote("@cert-authority *.apps.example.test " + ssh_ca)
        + " >"
        + sharing_dir
        + "/guest-known-hosts"
    )
    client.succeed("chown tester:users " + sharing_dir + "/guest-known-hosts")

    # The SSH configuration routes through the packaged overalls client as its
    # ProxyCommand; it needs the fleet origin/zone and the verified trust file.
    # Create ~/.config itself as tester: install -d would leave the parent
    # root-owned, and Chromium's crash reporter then aborts at launch.
    client.succeed(
        "install -d -m 700 -o tester -g users /home/tester/.config /home/tester/.config/overalls"
    )
    client.succeed(
        "printf %s "
        + shlex.quote(
            json.dumps({"origin": "https://control.example.test", "zone": "apps.example.test"})
        )
        + " >/home/tester/.config/overalls/config.json"
    )
    client.succeed(
        f"curl -fsS --cacert {sharing_dir}/ca.crt https://control.example.test/bin/ssh-trust.json "
        ">/home/tester/.ssh/overalls-trust.json"
    )
    client.succeed(
        "chown tester:users /home/tester/.config/overalls/config.json /home/tester/.ssh/overalls-trust.json"
    )

    # The packaged overalls ProxyCommand reads the default id_ed25519 identity,
    # so the owner key lives there; member calls swap identities in place, the
    # same dance as the Audi fleet journey.
    client.succeed("sudo -u tester ssh-keygen -q -t ed25519 -N '' -f /home/tester/.ssh/id_ed25519")
    client.succeed("sudo -u tester ssh-keygen -q -t ed25519 -N '' -f /home/tester/.ssh/member_id")
    owner_public = client.succeed("cat /home/tester/.ssh/id_ed25519.pub").strip()
    member_public = client.succeed("cat /home/tester/.ssh/member_id.pub").strip()
    for user_field, public in (("owner_id", owner_public), ("member_id", member_public)):
        operator(
            m1,
            dict(action="audi-ssh-key", owner_id=users[user_field], public_key=public),
        )

    operator(
        m1,
        dict(
            action="audi-ssh-profile",
            owner_id=users["owner_id"],
            vm_id=vm["vm_id"],
            output=root + "/sharing-ssh.conf",
        ),
    )
    transfer(m1, root + "/sharing-ssh.conf", client, sharing_dir + "/ssh.conf")
    client.succeed("chown tester:users " + sharing_dir + "/ssh.conf")

    operator(
        m1,
        dict(
            action="share",
            owner_id=users["owner_id"],
            vm_id=vm["vm_id"],
            email=users["member_email"],
            role="operator",
            key=str(uuid.uuid4()),
        ),
    )

    host_for(vm).succeed(
        "fleet-audi-guest ssh " + shlex.quote(vm["placement_id"]) + f" {sharing_dir}-host.pub",
        timeout=180,
    )

    owner_id = users["owner_id"]
    member_id = users["member_id"]
    assert isinstance(owner_id, str) and isinstance(member_id, str)
    owner_name = canonical_guest_name(owner_id)
    member_name = canonical_guest_name(member_id)
    ssh_environment = (
        f"sudo -u tester env HOME=/home/tester CURL_CA_BUNDLE={sharing_dir}/ca.crt "
        f"SSL_CERT_FILE={sharing_dir}/ca.crt "
    )

    def sharing_ssh_args(username: str) -> list[str]:
        return [
            "/run/current-system/sw/bin/ssh",
            "-F",
            sharing_dir + "/ssh.conf",
            "-o",
            "BatchMode=yes",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "ConnectTimeout=10",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "GlobalKnownHostsFile=/dev/null",
            "-o",
            "UserKnownHostsFile=" + sharing_dir + "/guest-known-hosts",
            "-i",
            "/home/tester/.ssh/id_ed25519",
            username + "@" + sharing_hostname,
        ]

    def ssh_swap(role: str) -> None:
        """Swap the default identity between the owner and member keypairs."""
        assert role in ("owner", "member")
        if role == "member":
            client.succeed(
                "mv /home/tester/.ssh/id_ed25519 /home/tester/.ssh/owner_id && "
                "mv /home/tester/.ssh/id_ed25519.pub /home/tester/.ssh/owner_id.pub && "
                "cp /home/tester/.ssh/member_id /home/tester/.ssh/id_ed25519 && "
                "cp /home/tester/.ssh/member_id.pub /home/tester/.ssh/id_ed25519.pub && "
                "chown tester:users /home/tester/.ssh/id_ed25519* && "
                "chmod 600 /home/tester/.ssh/id_ed25519"
            )
        else:
            client.succeed(
                "mv /home/tester/.ssh/owner_id /home/tester/.ssh/id_ed25519 && "
                "mv /home/tester/.ssh/owner_id.pub /home/tester/.ssh/id_ed25519.pub"
            )

    owner_args = sharing_ssh_args(owner_name)
    member_args = sharing_ssh_args(member_name)

    assert (
        client.wait_until_succeeds(
            ssh_environment + shlex.join([*owner_args, "id -un"]), timeout=90
        ).strip()
        == owner_name
    )

    origin_source = client.succeed("base64 -w0 " + shlex.quote(sharing_guest_origin)).strip()
    install_origin = (
        "printf %s " + shlex.quote(origin_source) + " | base64 -d >/tmp/private-web-guest.py && "
        "sudo systemd-run --quiet --unit=private-web-origin python3 /tmp/private-web-guest.py && "
        "printf ready"
    )
    client.wait_until_succeeds(
        ssh_environment + shlex.join([*owner_args, install_origin]), timeout=90
    )
    # The origin serves before any member admission: counters begin untouched.
    client.wait_until_succeeds(
        ssh_environment + shlex.join([*owner_args, "cat /tmp/private-web-counts.json"]),
        timeout=30,
    )

    ssh_swap("member")
    assert (
        client.wait_until_succeeds(
            ssh_environment + shlex.join([*member_args, "id -un"]), timeout=90
        ).strip()
        == member_name
    )

    live_ssh = (
        "import os,subprocess,pathlib; os.environ['PATH']='/run/current-system/sw/bin'; "
        f"os.environ['HOME']='/home/tester'; os.environ['CURL_CA_BUNDLE']='{sharing_dir}/ca.crt'; "
        f"os.environ['SSL_CERT_FILE']='{sharing_dir}/ca.crt'; "
        "p=subprocess.Popen("
        + repr([*member_args, "while true; do printf 'sharing-ssh-live\\n'; sleep .1; done"])
        + ",stdout=subprocess.PIPE,stderr=subprocess.DEVNULL); "
        "assert p.stdout.readline() == b'sharing-ssh-live\\n'; "
        f"pathlib.Path('{sharing_dir}/ssh-live-ready').touch(); "
        "p.communicate(timeout=15); assert p.returncode != 0"
    )
    client.succeed(
        "systemd-run --quiet --no-block --unit=sharing-ssh-live --property=User=tester "
        "--property=Type=oneshot --property=RemainAfterExit=yes --property=StandardOutput=null "
        "--property=StandardError=null /run/current-system/sw/bin/python3 -c "
        + shlex.quote(live_ssh)
    )
    sharing_wait_unit("sharing-ssh-live.service", sharing_dir + "/ssh-live-ready")
    # The member's live connection persists; the never-revoked owner identity is
    # restored for guest-origin counter reads.
    ssh_swap("owner")

    operator(
        m1,
        dict(
            action="refresh-browser-tokens",
            source=root + "/users.json",
            output=root + "/sharing-users.json",
        ),
    )
    transfer(m1, root + "/sharing-users.json", client, sharing_dir + "/users.json")
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", prefix="sharing-target-", delete=False, dir=private
    ) as target:
        json.dump({"hostname": sharing_hostname, "vm": vm["vm_id"]}, target)
        target_path = target.name
    client.copy_from_host(target_path, sharing_dir + "/target.json")
    Path(target_path).unlink()
    client.succeed(
        "chown tester:users "
        + sharing_dir
        + "/users.json "
        + sharing_dir
        + "/target.json && chmod 600 "
        + sharing_dir
        + "/users.json "
        + sharing_dir
        + "/target.json"
    )
    initial_state = json.dumps(
        {
            "phase": "starting",
            "terminal_ms": None,
            "fresh_status": None,
            "session": None,
            "web_closed": False,
        }
    )
    client.succeed("printf %s " + shlex.quote(initial_state) + " >" + sharing_dir + "/state.json")
    client.succeed(
        "systemd-run --quiet --no-block --unit=sharing-surfaces-browser --property=User=tester "
        "--property=Environment=HOME=/home/tester --property=WorkingDirectory=/home/tester "
        "--property=TimeoutStartSec=300 "
        "--service-type=oneshot /run/current-system/sw/bin/fleet-sharing-browser"
    )

    live = sharing_await_browser("open", 300)
    live_session = live["session"]
    assert isinstance(live_session, str)
    assert str(uuid.UUID(live_session)) == live_session

    # All three surfaces are live at once, on committed leases only.
    assert (
        sql(
            f"SELECT count(*) FROM ingress_sessions s JOIN ssh_keys k ON k.id=s.key_id "
            f"WHERE s.vm_id='{vm['vm_id']}' AND k.user_id='{users['member_id']}' "
            f"AND s.closed_at IS NULL AND s.expires_at > (statement_timestamp() AT TIME ZONE 'UTC')"
        )
        == "1"
    )
    member_web_live = (
        f"SELECT count(*) FROM ingress_web_streams s JOIN ingress_web_credentials c "
        f"ON c.id=s.credential_id WHERE s.vm_id='{vm['vm_id']}' AND c.user_id='{users['member_id']}' "
        f"AND s.closed_at IS NULL AND s.expires_at > (statement_timestamp() AT TIME ZONE 'UTC')"
    )
    assert sql(member_web_live) == "2"
    assert (
        sql(
            f"SELECT count(*) FROM terminal_grants g JOIN terminal_sessions s ON s.id=g.session_id "
            f"WHERE s.vm_id='{vm['vm_id']}' AND g.user_id='{users['member_id']}' "
            f"AND g.archived_at IS NULL"
        )
        == "1"
    )
    opened_counts = sharing_web_counts(owner_args)
    assert opened_counts["http"] >= 1
    assert opened_counts["stream"] == 1 and opened_counts["ws"] == 1
    assert process_snapshot(vm) == before

with subtest("one direct revocation closes the three member surfaces within documented bounds"):
    first_ssh_session = sql(
        f"SELECT s.id FROM ingress_sessions s JOIN ssh_keys k ON k.id=s.key_id "
        f"WHERE s.vm_id='{vm['vm_id']}' AND k.user_id='{users['member_id']}' ORDER BY s.inserted_at"
    )
    revoke_started = time.monotonic()
    operator(
        m1,
        dict(
            action="share",
            owner_id=users["owner_id"],
            vm_id=vm["vm_id"],
            email=users["member_email"],
            role="revoked",
            key=str(uuid.uuid4()),
        ),
    )
    client.succeed("touch " + sharing_dir + "/revoke-posted")
    revoked_after = time.monotonic() - revoke_started

    # Audi SSH: renewal loses current write membership inside its five-second
    # TTL, so the live guest session closes at that bound.
    client.wait_for_unit("sharing-ssh-live.service", timeout=8)
    assert (
        client.succeed(
            "systemctl show sharing-ssh-live.service --property=ExecMainStatus --value"
        ).strip()
        == "0"
    )
    ssh_swap("member")
    client.fail(
        ssh_environment + shlex.join([*member_args, "true"]) + " >/dev/null 2>&1", timeout=30
    )
    ssh_swap("owner")

    closed_browser = sharing_await_browser("closed", 60)
    closed_browser = sharing_browser_phase()
    terminal_ms = closed_browser["terminal_ms"]
    assert isinstance(terminal_ms, int) and 0 <= terminal_ms <= 10000
    assert closed_browser["web_closed"] is True
    assert closed_browser["fresh_status"] == 403

    # Server-side terminal bound: the shared viewer's detach receipt follows the
    # committed revocation receipt within the one-second recheck plus margin.
    terminal_gap = float(
        sql(
            "SELECT extract(epoch FROM (d.inserted_at - s.inserted_at)) FROM "
            f"(SELECT inserted_at FROM terminal_events WHERE vm_id='{vm['vm_id']}' AND kind='revoked' ORDER BY inserted_at DESC LIMIT 1) s, "
            f"(SELECT inserted_at FROM terminal_events WHERE vm_id='{vm['vm_id']}' AND kind='detached' AND actor_id='{users['member_id']}' ORDER BY inserted_at DESC LIMIT 1) d"
        )
    )
    assert 0 <= terminal_gap <= 2.5

    # The refusal happened before the guest: refused fresh traffic never
    # contacts the origin; only the two already-live transports close.
    revoked_counts = sharing_web_counts(owner_args)
    assert revoked_counts["http"] == opened_counts["http"]
    assert revoked_counts["stream"] == 1 and revoked_counts["ws"] == 1
    assert revoked_counts["stream_closed"] == 1 and revoked_counts["ws_closed"] == 1

    assert sql(member_web_live) == "0"
    assert (
        sql(
            f"SELECT count(*) FROM access_grants WHERE vm_id='{vm['vm_id']}' "
            f"AND user_id='{users['member_id']}' AND archived_at IS NULL"
        )
        == "0"
    )
    assert process_snapshot(vm) == before
    print(
        "Sharing revocation timings: browser terminal "
        + str(terminal_ms)
        + "ms, server terminal gap "
        + str(terminal_gap)
        + "s, revoke commit "
        + str(round(revoked_after, 3))
        + "s",
        flush=True,
    )

with subtest("re-sharing restores fresh admission with new lease artifacts"):
    operator(
        m1,
        dict(
            action="share",
            owner_id=users["owner_id"],
            vm_id=vm["vm_id"],
            email=users["member_email"],
            role="operator",
            key=str(uuid.uuid4()),
        ),
    )
    client.succeed("touch " + sharing_dir + "/reshared")
    _restored = sharing_await_browser("restored", 120)
    client.wait_until_succeeds(
        "systemctl show sharing-surfaces-browser.service --property=ExecMainStatus --value "
        "| grep -qx '0'",
        timeout=120,
    )

    member_sessions = sql(
        f"SELECT count(DISTINCT s.id) FROM ingress_sessions s JOIN ssh_keys k ON k.id=s.key_id "
        f"WHERE s.vm_id='{vm['vm_id']}' AND k.user_id='{users['member_id']}'"
    )
    latest_ssh = sql(
        f"SELECT s.id FROM ingress_sessions s JOIN ssh_keys k ON k.id=s.key_id "
        f"WHERE s.vm_id='{vm['vm_id']}' AND k.user_id='{users['member_id']}' "
        f"ORDER BY s.inserted_at DESC LIMIT 1"
    )
    assert member_sessions == "2"
    assert latest_ssh != first_ssh_session
    ssh_swap("member")
    client.succeed(
        "rm -f "
        + sharing_dir
        + "/reshared-ssh-ready; systemd-run --quiet --no-block --unit=sharing-ssh-restored "
        "--property=User=tester --property=Type=oneshot --property=RemainAfterExit=yes "
        "--property=StandardOutput=null --property=StandardError=null "
        "/run/current-system/sw/bin/python3 -c "
        + shlex.quote(live_ssh.replace("ssh-live-ready", "reshared-ssh-ready"))
    )
    sharing_wait_unit("sharing-ssh-restored.service", sharing_dir + "/reshared-ssh-ready")
    client.succeed("systemctl stop sharing-ssh-restored.service")
    ssh_swap("owner")

    web_identity = sql(
        f"SELECT count(DISTINCT s.id) FROM ingress_web_streams s JOIN ingress_web_credentials c "
        f"ON c.id=s.credential_id WHERE s.vm_id='{vm['vm_id']}' AND c.user_id='{users['member_id']}'"
    )
    assert web_identity == "4"
    restored_counts = sharing_web_counts(owner_args)
    assert restored_counts["http"] > revoked_counts["http"]

    # The terminal viewing grant survived the VM-level revocation; fresh
    # admission still meant a fresh single-use ticket and attachment receipt.
    terminal_attaches = sql(
        f"SELECT count(*) FROM terminal_events WHERE vm_id='{vm['vm_id']}' AND kind='attached' "
        f"AND actor_id='{users['member_id']}'"
    )
    assert terminal_attaches == "2"
    assert (
        sql(
            f"SELECT count(*) FROM terminal_events WHERE vm_id='{vm['vm_id']}' AND kind='revoked' "
            f"AND actor_id='{users['owner_id']}'"
        )
        == "0"
    )
    assert process_snapshot(vm) == before
