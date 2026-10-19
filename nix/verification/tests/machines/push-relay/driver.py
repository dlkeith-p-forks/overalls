import json
from pathlib import Path


def as_object(value: object) -> dict[str, object]:
    """Narrows parsed JSON to a string-keyed object."""
    assert isinstance(value, dict)
    narrowed: dict[str, object] = {}
    for key, item in value.items():
        assert isinstance(key, str)
        narrowed[key] = item
    return narrowed


def as_objects(value: object) -> list[dict[str, object]]:
    """Narrows parsed JSON to a list of string-keyed objects."""
    assert isinstance(value, list)
    return [as_object(item) for item in value]


def as_text(value: object) -> str:
    assert isinstance(value, str)
    return value


def probe(action: str) -> dict[str, object]:
    primary.succeed(f"echo {action} > /run/push-fixture/action")
    primary.succeed("systemctl start overalls-push-probe.service", timeout=240)
    return as_object(json.loads(primary.succeed("cat /run/push-fixture/result.json")))


def script(entries: list[dict[str, object]]) -> None:
    relay.succeed(f"echo {json.dumps(json.dumps(entries))} > /run/fake-provider/script.json")


def apple_requests() -> list[dict[str, object]]:
    raw = relay.succeed("cat /run/fake-provider/requests.jsonl 2>/dev/null || true")
    rows = [as_object(json.loads(line)) for line in raw.splitlines() if line.strip()]
    return [row for row in rows if row["host"] == "api.push.apple.com"]


def audit_actions() -> list[str]:
    raw = relay.succeed(
        "sudo -u susan psql -At susan -c 'select action from audit_entries order by seq'"
    )
    return raw.split()


def handover(source: str, target: str) -> None:
    """Copies a fixture file between nodes through the driver, never through a logged command."""
    relay.copy_from_vm(source, "handover")
    local = Path(relay.out_dir) / "handover" / Path(source).name
    primary.copy_from_host(str(local), target)
    local.unlink()


start_all()
relay.wait_for_unit("postgresql.service")
relay.wait_for_unit("fake-provider.service")
relay.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
relay.succeed("python3 /etc/susan-fixture.py seal 1")
relay.succeed("systemctl restart overalls-secrets-susan.service")
relay.succeed("systemctl start susan.service")
relay.wait_for_unit("susan.service")
relay.wait_until_succeeds("curl -sf http://127.0.0.1:4100/healthz | grep -F ok")
relay.wait_for_unit("nginx.service")

primary.wait_for_unit("postgresql-setup.service")
primary.succeed("systemctl start overalls-test-migrate.service")
primary.wait_for_unit("marshall-primary.service")
primary.wait_until_succeeds(
    "curl -fsS --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready", timeout=120
)
# The isolated probe drives every attempt deterministically through Oban.
primary.succeed("systemctl stop marshall-primary.service")

with subtest("Marshall reaches the compiled Susan origin over verified TLS"):
    primary.succeed("curl -sf https://notifications.overalls.dev/healthz | grep -F ok")

with subtest("Mila's push key from the real Susan registers a device"):
    issued = as_object(
        json.loads(relay.succeed("python3 /etc/susan-client.py key mila apns 203.0.113.7"))
    )
    assert issued["status"] == 201, issued
    relay.succeed(
        "jq -r .push_key /run/susan-fixture/key-mila.json > /run/susan-fixture/push-key"
        " && chmod 600 /run/susan-fixture/push-key"
    )
    handover("/run/susan-fixture/push-key", "/run/push-fixture/push-key")

with subtest("provider 503 twice, then 200: Susan accepts Marshall's signature and sends once"):
    script(
        [
            {"host": "api.push.apple.com", "status": 503},
            {"host": "api.push.apple.com", "status": 503},
        ]
    )
    result = probe("deliver")
    assert result["state"] == "delivered", result
    assert result["attempts"] == 2, result
    assert len(apple_requests()) == 3, apple_requests()
    actions = audit_actions()
    assert actions.count("provider_sent") == 1, actions
    assert "poke_accepted" in actions, actions

with subtest("only the device can open what the provider received"):
    relay.succeed("cp /run/fake-provider/requests.jsonl /run/susan-fixture/provider.jsonl")
    handover("/run/susan-fixture/provider.jsonl", "/run/push-fixture/provider.jsonl")
    opened = as_objects(probe("open")["opened"])
    assert len(opened) == 3, opened
    for row in opened:
        assert row == {"opens": True, "stranger": True, "content_free": True}, row

with subtest("provider 410 invalidates the device and later pokes are never sent"):
    script([{"host": "api.push.apple.com", "status": 410, "body": '{"reason":"Unregistered"}'}])
    result = probe("gone")
    assert result["device_state"] == "invalidated", result
    assert result["device_reason"] == "provider_unregistered", result
    assert result["gone"] == "dropped", result
    assert result["later"] == ["dropped", "device_inactive"], result
    assert len(apple_requests()) == 4, apple_requests()
    assert "provider_unregistered" in audit_actions()

with subtest("neither journal holds the push key, the device key or a poke"):
    push_key = relay.succeed("cat /run/susan-fixture/push-key").strip()
    private = primary.succeed("cat /run/push-fixture/private").strip()
    ciphertexts = [
        as_text(as_object(as_object(json.loads(as_text(row["body"])))["overalls"])["c"])
        for row in apple_requests()
    ]
    for node in (relay, primary):
        journal = node.succeed("journalctl -b --no-pager -o cat")
        assert push_key not in journal
        assert private not in journal
        assert "7a1c0e44-91f2-4d1e-8a5b-3e2f6c9d0a12" not in journal
        for ciphertext in ciphertexts:
            assert ciphertext not in journal
