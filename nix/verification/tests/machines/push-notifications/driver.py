import json

start_all()
primary.wait_for_unit("postgresql-setup.service")
primary.succeed("systemctl start overalls-test-migrate.service")
primary.wait_for_unit("marshall-primary.service")
primary.wait_for_unit("overalls-fake-susan.service")
primary.wait_until_succeeds(
    "curl -fsS --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready", timeout=120
)


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
    primary.succeed("systemctl start overalls-push-probe.service", timeout=180)
    return as_object(json.loads(primary.succeed("cat /run/push-fixture/result.json")))


def recorded() -> list[dict[str, object]]:
    lines = primary.succeed("cat /run/push-fixture/requests.jsonl").splitlines()
    return [as_object(json.loads(line)) for line in lines]


def provider_sends() -> list[str]:
    return primary.succeed("cat /run/push-fixture/provider-sends 2>/dev/null || true").split()


with subtest("the serving wrapper carries the enabled switch"):
    primary.succeed(
        "grep -q MARSHALL_NOTIFICATIONS_ENABLED=true "
        "$(systemctl show -p ExecStart --value marshall-primary.service | grep -o '/nix/store/[^ ;]*' | head -1)"
    )

# The isolated probe runs the real release with queue consumption disabled so
# every attempt is driven deterministically through Oban.drain_queue/1.
primary.succeed("systemctl stop marshall-primary.service")

with subtest("Susan 503, 503, then 200 yields exactly one provider send"):
    primary.succeed("echo '503 503 200 410' > /run/push-fixture/script")
    result = probe("deliver")
    assert result["state"] == "delivered", result["state"]
    assert result["attempts"] == 3, result["attempts"]
    requests = as_objects(result["requests"])
    assert [request["status"] for request in requests] == [503, 503, 200]
    assert {request["delivery"] for request in requests} == {result["delivery"]}
    assert provider_sends() == [result["delivery"]]

with subtest("the poke body is signed ciphertext only"):
    for request in requests:
        assert request["signature"] is True
        assert request["opens"] is True
        assert request["stranger"] is True
        assert request["content_free"] is True
    bodies = [as_object(json.loads(as_text(record["body"]))) for record in recorded()]
    for body in bodies:
        assert sorted(body) == [
            "ciphertext",
            "collapse_id",
            "delivery_id",
            "deployment",
            "issued_at",
            "kind",
            "nonce",
            "push_key",
        ]
        assert body["kind"] == "needs_input"
        assert body["deployment"] == "control.example.test"

with subtest("410 invalidates the device and later pokes are never sent"):
    result = probe("gone")
    assert result["device_state"] == "invalidated", result
    assert result["device_reason"] == "provider_unregistered", result
    assert result["gone"] == ["dropped", "device_inactive"], result
    assert result["later"] == ["dropped", "device_inactive"], result
    assert len(recorded()) == 4
    assert len(provider_sends()) == 1

with subtest("journal holds no push key, ciphertext or route"):
    private = primary.succeed("cat /run/push-fixture/private").strip()
    journal = primary.succeed("journalctl -b --no-pager -o cat")
    assert private not in journal
    assert "7a1c0e44-91f2-4d1e-8a5b-3e2f6c9d0a12" not in journal
    for body in bodies:
        assert as_text(body["ciphertext"]) not in journal
        assert as_text(body["push_key"]) not in journal

with subtest("services.marshall.notifications.enable = false refuses registration"):
    primary.succeed("/run/current-system/specialisation/disabled/bin/switch-to-configuration test")
    primary.succeed("systemctl stop marshall-primary.service")
    result = probe("disabled")
    assert result == {"enabled": False, "refusal": "push_disabled"}, result
