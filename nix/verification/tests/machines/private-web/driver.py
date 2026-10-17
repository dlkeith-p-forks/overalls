"""Private guest web withdrawal following the shared native team resource setup."""


class WebCounts(TypedDict):
    http: int
    stream: int
    stream_closed: int
    ws: int
    ws_closed: int
    echoes: int


def web_counts() -> WebCounts:
    # Counters are read as owner after withdrawal: the removed member cannot SSH.
    guest_command(shared_vm, "owner", "cat /tmp/private-web-counts.json", None, inspect_output=True)
    parsed: object = json.loads(client.succeed("cat " + browser_root + "/guest.out"))
    fields = object_fields(parsed)
    checked: dict[str, int] = {}
    assert set(fields) == {"http", "stream", "stream_closed", "ws", "ws_closed", "echoes"}
    for name, value in fields.items():
        assert isinstance(value, int) and not isinstance(value, bool) and value >= 0
        checked[name] = value
    return {
        "http": checked["http"],
        "stream": checked["stream"],
        "stream_closed": checked["stream_closed"],
        "ws": checked["ws"],
        "ws_closed": checked["ws_closed"],
        "echoes": checked["echoes"],
    }


def web_marker(name: str) -> bool:
    assert name in ("open", "refused", "complete")
    status = client.succeed(
        "systemctl show private-web-browser.service --property=ExecMainStatus --value"
    ).strip()
    assert status == "0", "Private browser failed; closed stage retained in journal"
    return client.execute("test -e " + browser_root + "/private-" + name)[0] == 0


with subtest("current team member opens private HTTP and WebSocket traffic through actual Audi"):
    # The guest program is an independent origin, installed through ordinary
    # authorized SSH. It cannot create platform authority or forge lease rows.
    origin_source = client.succeed("base64 -w0 " + shlex.quote(private_web_origin)).strip()
    guest_command(
        shared_vm,
        "owner",
        "printf %s "
        + shlex.quote(origin_source)
        + " | base64 -d >/tmp/private-web-guest.py && sudo systemd-run --quiet --unit=private-web-origin python3 /tmp/private-web-guest.py && printf ready",
        "ready",
    )
    endpoint = operator(
        dict(
            action="audi-policy",
            owner_id=users["owner"]["id"],
            vm_id=shared_vm,
            visibility="private",
        )
    )
    hostname = endpoint["label"]
    assert isinstance(hostname, str)
    hostname += ".apps.example.test"
    assert sql(f"SELECT visibility FROM ingress_endpoints WHERE vm_id='{shared_vm}'") == "private"
    assert (
        sql(
            f"SELECT count(*) FROM access_grants WHERE vm_id='{shared_vm}' AND user_id='{users['member']['id']}'"
        )
        == "0"
    )
    transfer(m1, root + "/audi-root.pem", client, browser_root + "/audi-root.pem")
    client.succeed(
        f"sudo -u tester certutil -A -d sql:/home/tester/.pki/nssdb -n private-web-root -t 'C,,' -i {browser_root}/audi-root.pem"
    )
    operator(
        dict(
            action="refresh-browser-tokens",
            source=root + "/users.json",
            output=root + "/private-users.json",
        )
    )
    transfer(m1, root + "/private-users.json", client, browser_root + "/private-users.json")
    with TemporaryDirectory(prefix="private-web-target-") as directory:
        target = Path(directory) / "target.json"
        target.write_text(json.dumps({"hostname": hostname}))
        client.copy_from_host(str(target), browser_root + "/private-target.json")
    client.succeed(
        f"chown tester:users {browser_root}/private-*.json && chmod 600 {browser_root}/private-*.json"
    )
    client.succeed(
        "systemd-run --quiet --no-block --unit=private-web-browser --property=User=tester --property=Environment=HOME=/home/tester --property=TimeoutStartSec=240 --property=RemainAfterExit=yes fleet-private-web-browser"
    )
    eventually(lambda: web_marker("open"), timeout=90)
    # Both original durable rows must independently advance past their initial
    # five-second deadline. Browser data and guest counters must remain live.
    member_id = users["member"]["id"]
    live_query = f"SELECT count(*) FROM ingress_web_streams s JOIN ingress_web_credentials c ON c.id=s.credential_id WHERE s.vm_id='{shared_vm}' AND c.user_id='{member_id}' AND s.closed_at IS NULL AND s.expires_at > (statement_timestamp() AT TIME ZONE 'UTC') AND s.expires_at > s.inserted_at + interval '6 seconds'"
    eventually(lambda: sql(live_query) == "2", timeout=15)
    before = web_counts()
    assert before["stream"] == before["ws"] == 1
    assert before["stream_closed"] == before["ws_closed"] == 0 and before["echoes"] > 2

with subtest(
    "ordinary owner membership removal closes original streams and refuses fresh browser traffic"
):
    porsche("team member remove native-resources " + member_email)
    assert (
        sql(
            f"SELECT count(*) FROM team_members WHERE team_id='{team_id}' AND user_id='{member_id}' AND archived_at IS NULL"
        )
        == "0"
    )
    client.succeed("touch " + browser_root + "/private-withdrawn")
    eventually(lambda: web_marker("refused"), timeout=15)
    eventually(
        lambda: web_counts()["stream_closed"] == 1 and web_counts()["ws_closed"] == 1, timeout=15
    )
    closed_counts = web_counts()
    assert closed_counts["http"] == before["http"]
    assert closed_counts["stream"] == closed_counts["ws"] == 1
    assert sql(live_query) == "0"

with subtest("re-addition permits a fresh request while original browser transports stay closed"):
    porsche("team member add native-resources " + member_email + " member")
    client.succeed("touch " + browser_root + "/private-restored")
    eventually(lambda: web_marker("complete"), timeout=30)
    client.wait_for_unit("private-web-browser.service", timeout=30)
    assert (
        client.succeed(
            "systemctl show private-web-browser.service --property=ExecMainStatus --value"
        ).strip()
        == "0"
    )
    recovered = web_counts()
    assert recovered["http"] > closed_counts["http"]
    assert {key: value for key, value in recovered.items() if key != "http"} == {
        key: value for key, value in closed_counts.items() if key != "http"
    }
    ordinary_accounts()
