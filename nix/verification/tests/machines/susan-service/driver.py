import base64
import hashlib
import json
from typing import TypedDict


class ProviderRequest(TypedDict):
    host: str
    path: str
    http_version: str
    headers: dict[str, str]
    authorization: str
    body: str


client = "python3 /etc/susan-client.py"
operator = "susan-operator"
# The client sends this opaque 22-character id for the "thread-1" collapse group.
collapse_id = base64.urlsafe_b64encode(hashlib.sha256(b"thread-1").digest()).decode()[:22]


def call(command: str) -> dict[str, object]:
    return json.loads(relay.succeed(command).strip().splitlines()[-1])


def key(name: str, provider: str, source: str, reuse: str = "") -> dict[str, object]:
    return call(f"{client} key {name} {provider} {source} {reuse}")


def poke(
    name: str, source: str, delivery: str = "new", installer: str = "a", replay: str = ""
) -> dict[str, object]:
    return call(f"{client} poke {name} {delivery} {source} {installer} {replay}")


def requests() -> list[ProviderRequest]:
    raw = relay.succeed("cat /run/fake-provider/requests.jsonl 2>/dev/null || true")
    return [json.loads(line) for line in raw.splitlines() if line.strip()]


def script(entries: list[dict[str, object]]) -> None:
    relay.succeed(f"echo {json.dumps(json.dumps(entries))} > /run/fake-provider/script.json")


def audit_actions() -> list[str]:
    raw = relay.succeed(
        "sudo -u susan psql -At susan -c 'select action from audit_entries order by seq'"
    )
    return raw.split()


start_all()
relay.wait_for_unit("postgresql.service")
relay.wait_for_unit("fake-provider.service")
relay.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
relay.succeed("python3 /etc/susan-fixture.py seal 1")
relay.succeed("systemctl restart overalls-secrets-susan.service")
relay.succeed("systemctl start susan.service")
relay.wait_for_unit("susan.service")
relay.wait_until_succeeds("curl -sf http://127.0.0.1:4100/healthz | grep -F ok")

with subtest("listener, custody and unprivileged runtime"):
    relay.succeed('test "$(stat -c %U:%a /run/overalls-secrets/susan/DATABASE_URL)" = root:600')
    user = relay.succeed("ps -o user= -C beam.smp | sort -u").split()
    assert user == ["susan"], user
    listening = relay.succeed("ss -Htlnp | grep beam.smp")
    for line in listening.splitlines():
        address = line.split()[3]
        assert address.startswith("127.0.0.1:"), listening
    relay.succeed(
        "test $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4100/admin) = 404"
    )

with subtest("APNs poke is content-free and over HTTP/2 with verified TLS"):
    issued = key("a", "apns", "198.51.100.10")
    assert issued["status"] == 201, issued
    result = poke("a", "198.51.100.11", delivery="11111111-1111-4111-8111-111111111111")
    assert result["status"] == 204, result
    sent = requests()
    assert len(sent) == 1, sent
    apns = sent[0]
    assert apns["host"] == "api.push.apple.com" and apns["http_version"] == "2", apns
    assert apns["authorization"] == "bearer", apns
    assert apns["headers"]["apns-collapse-id"] == collapse_id, apns
    assert apns["headers"]["apns-push-type"] == "alert", apns
    payload = json.loads(apns["body"])
    assert payload["aps"]["mutable-content"] == 1, payload
    assert payload["aps"]["alert"] == {
        "title-loc-key": "MILA_PUSH_NEEDS_INPUT_TITLE",
        "loc-key": "MILA_PUSH_NEEDS_INPUT_BODY",
    }, payload
    assert set(payload["overalls"]) == {"v", "k", "c"}, payload

with subtest("a retried delivery id is answered without a second provider send"):
    result = poke("a", "198.51.100.11", delivery="11111111-1111-4111-8111-111111111111")
    assert result["status"] == 204, result
    assert len(requests()) == 1

with subtest("provider 503 retries once in-request, then a later retry succeeds once"):
    script(
        [
            {"host": "api.push.apple.com", "status": 503, "headers": {"retry-after": "7"}},
            {"host": "api.push.apple.com", "status": 503, "headers": {"retry-after": "7"}},
        ]
    )
    delivery = "22222222-2222-4222-8222-222222222222"
    result = poke("a", "198.51.100.11", delivery=delivery)
    assert result["status"] == 503 and result["retry_after"] == "7", result
    assert len(requests()) == 3
    result = poke("a", "198.51.100.11", delivery=delivery)
    assert result["status"] == 204, result
    assert len(requests()) == 4
    result = poke("a", "198.51.100.11", delivery=delivery)
    assert result["status"] == 204 and len(requests()) == 4, result

with subtest("an exact replay is refused"):
    first = poke("a", "198.51.100.11", replay="replay.json")
    assert first["status"] == 204, first
    again = poke("a", "198.51.100.11", replay="replay.json")
    assert again["status"] == 400, again

with subtest("forged signatures and unknown keys get the malformed body"):
    malformed = call(f"{client} malformed 198.51.100.12")
    assert malformed["status"] == 400, malformed
    forged = poke("a", "198.51.100.12", installer="forged")
    assert forged["status"] == 404 and forged["body"] == malformed["body"], forged
    before = audit_actions()
    poke("a", "198.51.100.12", installer="forged")
    assert audit_actions() == before, "unauthenticated pokes must not write"

with subtest("per-key token bucket admits a burst of ten then answers 429"):
    key("burst", "apns", "198.51.100.20")
    statuses = [poke("burst", "198.51.100.21", installer="b")["status"] for _ in range(10)]
    assert statuses == [204] * 10, statuses
    limited = poke("burst", "198.51.100.21", installer="b")
    assert limited["status"] == 429 and int(str(limited["retry_after"])) > 0, limited

with subtest("operator deny-list refuses the key with the malformed body"):
    denied = key("denied", "apns", "198.51.100.30")
    assert poke("denied", "198.51.100.31", installer="c")["status"] == 204
    output = relay.succeed(
        f"{operator} 'Susan.Operator.denylist_key(\"{denied['key_id']}\", :abuse)'"
    )
    assert "denied" in output, output
    refused = poke("denied", "198.51.100.31", installer="c")
    assert refused["status"] == 404 and refused["body"] == malformed["body"], refused

with subtest("unregistered tokens answer 410 and enter the negative cache"):
    key("gone", "apns", "198.51.100.40")
    script([{"host": "api.push.apple.com", "status": 410, "body": '{"reason":"Unregistered"}'}])
    assert poke("gone", "198.51.100.41", installer="d")["status"] == 410
    count = len(requests())
    assert poke("gone", "198.51.100.41", installer="d")["status"] == 410
    assert len(requests()) == count, "negative cache must avoid provider sends"
    reissue = key("gone2", "apns", "198.51.100.42", reuse="gone")
    assert reissue["status"] == 410, reissue

with subtest("FCM v1 data-only message after a service-account OAuth exchange"):
    key("android", "fcm", "198.51.100.50")
    count = len(requests())
    assert poke("android", "198.51.100.51", installer="e")["status"] == 204
    new = requests()[count:]
    hosts = [entry["host"] for entry in new]
    assert hosts == ["oauth2.googleapis.com", "fcm.googleapis.com"], hosts
    fcm = new[1]
    assert fcm["path"] == "/v1/projects/overalls-relay-test/messages:send", fcm
    assert fcm["authorization"] == "Bearer", fcm
    message = json.loads(fcm["body"])["message"]
    assert "notification" not in message, message
    assert set(message["data"]) == {
        "overalls_v",
        "overalls_k",
        "overalls_c",
        "overalls_title_loc_key",
        "overalls_body_loc_key",
    }, message
    assert message["android"]["collapse_key"] == collapse_id, message

with subtest("install identity states and audit chain"):
    fingerprint = relay.succeed(f"{client} fingerprint b").strip()
    state = relay.succeed(
        "sudo -u susan psql -At susan -c "
        f"\"select state from install_identities where fingerprint = '{fingerprint}'\""
    ).strip()
    assert state in ("trusted", "rate_limited"), state
    actions = set(audit_actions())
    for action in (
        "key_issued",
        "install_first_seen",
        "poke_accepted",
        "poke_rejected",
        "provider_sent",
        "provider_failed",
        "provider_unregistered",
        "rate_limited",
        "key_denylisted",
        "key_rotated",
    ):
        assert action in actions, (action, actions)
    assert "intact" in relay.succeed(f"{operator} 'Susan.Operator.audit_verify()'")
    tail = relay.succeed(f"{operator} 'Susan.Operator.audit_tail(5)'")
    assert len([line for line in tail.splitlines() if line.startswith("{")]) == 5, tail
    exported = relay.succeed(
        f"{operator} 'Susan.Operator.audit_export(\"/var/lib/susan/audit-export.jsonl\")'"
    )
    assert "exported" in exported, exported
    relay.succeed('test "$(stat -c %U:%a /var/lib/susan/audit-export.jsonl)" = susan:600')

with subtest("audit rows are append-only in the database"):
    for statement in (
        "update audit_entries set outcome = 'ok'",
        "delete from audit_entries",
        "truncate audit_entries",
    ):
        status, output = relay.execute(
            f'sudo -u susan psql -v ON_ERROR_STOP=1 susan -c "{statement}" 2>&1'
        )
        assert status != 0 and "append-only" in output, (statement, output)
    assert "intact" in relay.succeed(f"{operator} 'Susan.Operator.audit_verify()'")

with subtest("no tokens, keys, ciphertext or source addresses in DB, journal or exports"):
    relay.succeed("sudo -u postgres pg_dump susan > /root/susan.sql")
    relay.succeed("journalctl --no-pager -o cat > /root/journal.txt")
    relay.succeed(
        "python3 /etc/susan-fixture.py scan /root/susan.sql /root/journal.txt "
        "/var/lib/susan/audit-export.jsonl"
    )
    relay.fail("grep -E '198\\.51\\.100\\.' /root/susan.sql /root/journal.txt")
