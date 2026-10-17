import base64
import json
import shlex


def fixture_object(value: object) -> dict[str, object]:
    """Validate recorded fixture JSON before typed assertions."""
    assert isinstance(value, dict)
    result: dict[str, object] = {}
    for key, item in value.items():
        assert isinstance(key, str)
        result[key] = item
    return result


def fixture_objects(raw: str) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for line in raw.splitlines():
        value: object = json.loads(line)
        records.append(fixture_object(value))
    return records


proxy.start()
proxy.wait_for_unit("ziggy-fixture.service")
proxy.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
proxy.succeed("python3 /etc/ziggy-seal.py")
proxy.succeed("systemctl start ziggy.service")
proxy.wait_for_unit("ziggy.service")
# Rust exporter delivers Ziggy-owned durable terminal outcomes to its isolated collector.
proxy.wait_for_unit("opentelemetry-collector.service")
proxy.succeed("systemctl start ziggy-slo-exporter.service")
proxy.wait_for_unit("ziggy-slo-exporter.service")
curl = "curl --noproxy '*' --silent --show-error --fail --max-time 10 --unix-socket /run/ziggy/proxy.sock"
proxy.wait_until_succeeds(curl + " http://ziggy/health/ready")
metrics = json.loads(proxy.succeed(curl + " http://ziggy/metrics"))
assert metrics["gauges"]["ziggy_catalog_ready"] == 1
host = "11111111-1111-4111-8111-111111111111"
binding = (
    base64.urlsafe_b64encode(
        json.dumps(dict(host_id=host, vm_id=host, placement_id=host, execution_epoch=1)).encode()
    )
    .decode()
    .rstrip("=")
)
headers = (
    " -H " + shlex.quote("x-overalls-binding: " + binding) + " -H 'Content-Type: application/json'"
)
with subtest("empty durable SLO lifetime survives restart before any provider call"):
    proxy.succeed("test $(stat -c %a /var/lib/ziggy/spool/.slo-checkpoint) = 600")
    proxy.wait_until_succeeds("jq -e '.requests == 0' /run/ziggy/slo.json")
    proxy.succeed("cp /run/ziggy/slo.json /run/ziggy-fixture/slo-before-empty-restart.json")
    proxy.succeed("systemctl restart ziggy.service")
    proxy.wait_until_succeeds(curl + " http://ziggy/health/ready")
    proxy.wait_until_succeeds(
        "jq -s -e '.[1].requests == 0 and .[1].successes == 0 and .[1].failures == 0 "
        "and .[1].incarnation == .[0].incarnation "
        "and .[1].started_at_unix_nano == .[0].started_at_unix_nano' "
        "/run/ziggy-fixture/slo-before-empty-restart.json /run/ziggy/slo.json"
    )
    proxy.succeed("test ! -s /run/ziggy-fixture/provider-calls")
for path in ["/v1/responses", "/v1/messages"]:
    body = json.dumps(dict(model="fixture-model", stream=True, input="synthetic-input"))
    response = proxy.succeed(
        curl + headers + " --data-binary " + shlex.quote(body) + " http://llm.internal" + path
    )
    assert "data: " in response
proxy.wait_until_succeeds("test $(wc -l < /run/ziggy-fixture/completions.jsonl) -eq 2")
records = [
    json.loads(line)
    for line in proxy.succeed("cat /run/ziggy-fixture/completions.jsonl").splitlines()
]
for row in records:
    assert row["completion"]["completeness"] == "complete"
    assert row["completion"]["tokens"]["input_tokens"] == 3
    assert row["completion"]["tokens"]["output_tokens"] == 7
proxy.wait_until_succeeds(
    'jq -e \'.service == "ziggy" and .requests == 2 and .successes == 2 '
    "and .failures == 0 and .duration.count == 2' /run/ziggy/slo.json"
)
proxy.wait_until_succeeds(
    "curl -fsS http://127.0.0.1:9464/metrics | "
    'grep -E \'overalls_outer_ziggy_requests_total\\{[^}]*overalls_telemetry_origin="application"[^}]*service_name="ziggy"[^}]*\\} 2\'',
    timeout=45,
)
proxy.succeed(
    "code=$(runuser -u ziggy -- curl --silent --output /dev/null --write-out '%{http_code}' "
    "--unix-socket /run/overalls-otel-ziggy/collector.sock http://localhost/v1/metrics || true); "
    'test "$code" = 000'
)
proxy.wait_until_succeeds("test $(find /var/lib/ziggy/spool -name '*.json' | wc -l) -eq 0")
proxy.fail(curl + " http://llm.internal/v1/models")
proxy.fail("su -s /bin/sh nobody -c 'cat /run/overalls-secrets/ziggy/openai.key'")
proxy.fail("su -s /bin/sh audi -c 'cat /run/overalls-secrets/ziggy/anthropic.key'")
proxy.fail(
    "su -s /bin/sh nobody -c 'curl --unix-socket /run/ziggy/proxy.sock http://ziggy/metrics'"
)
logs = proxy.succeed("journalctl -u ziggy.service --no-pager")
for forbidden in [
    "synthetic-input",
    "synthetic-output",
    "synthetic-openai-private",
    "synthetic-anthropic-private",
]:
    assert forbidden not in logs
with subtest("acknowledged SLO totals survive SIGKILL without provider replay"):
    proxy.succeed("cp /run/ziggy/slo.json /run/ziggy-fixture/slo-before-kill.json")
    proxy.succeed("test $(stat -c %a /var/lib/ziggy/spool/.slo-checkpoint) = 600")
    proxy.fail("runuser -u audi -- cat /var/lib/ziggy/spool/.slo-checkpoint")
    proxy.succeed("systemctl kill --kill-whom=main --signal=KILL ziggy.service")
    proxy.wait_until_succeeds(curl + " http://ziggy/health/ready")
    proxy.wait_until_succeeds(
        "jq -s -e '.[1].sampled_at_unix_nano > .[0].sampled_at_unix_nano "
        "and .[1].requests == 2 and .[1].successes == 2 and .[1].failures == 0 "
        "and .[1].incarnation == .[0].incarnation "
        "and .[1].started_at_unix_nano == .[0].started_at_unix_nano "
        "and .[1].duration == .[0].duration' "
        "/run/ziggy-fixture/slo-before-kill.json /run/ziggy/slo.json"
    )
    proxy.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:9464/metrics | "
        "grep -E 'overalls_outer_ziggy_requests_total\\{[^}]*service_name=\"ziggy\"[^}]*\\} 2'",
        timeout=45,
    )
proxy.wait_until_succeeds(curl + " http://ziggy/health/ready")
assert proxy.succeed("wc -l < /run/ziggy-fixture/provider-calls").strip() == "2"

with subtest("full accounting spool blocks provider effects and recovers without replay"):
    proxy.succeed("touch /run/ziggy-fixture/hold-receipts")
    body = shlex.quote(json.dumps(dict(model="fixture-model", input="synthetic-input")))
    for _ in range(8):
        proxy.succeed(
            curl + headers + " --data-binary " + body + " http://llm.internal/v1/responses"
        )
    proxy.fail(curl + headers + " --data-binary " + body + " http://llm.internal/v1/responses")
    assert proxy.succeed("wc -l < /run/ziggy-fixture/provider-calls").strip() == "10"
    metrics = json.loads(proxy.succeed(curl + " http://ziggy/metrics"))["gauges"]
    assert metrics["ziggy_pending_receipts"] == 8
    proxy.fail(curl + " http://ziggy/health/ready")
    proxy.succeed("rm /run/ziggy-fixture/hold-receipts")
    proxy.wait_until_succeeds("test $(find /var/lib/ziggy/spool -name '*.json' | wc -l) -eq 0")
    proxy.wait_until_succeeds(curl + " http://ziggy/health/ready")

with subtest("authority revocation closes a native stream"):
    proxy.succeed("touch /run/ziggy-fixture/revoke")
    body = shlex.quote(
        json.dumps(dict(model="fixture-model", stream=True, hold=True, input="synthetic-input"))
    )
    stream = (
        curl.replace("--max-time 10", "--max-time 35")
        + headers
        + " --data-binary "
        + body
        + " -o /dev/null http://llm.internal/v1/responses"
    )
    import time

    started = time.monotonic()
    proxy.fail(stream, timeout=40)
    assert time.monotonic() - started < 32
    proxy.succeed("rm /run/ziggy-fixture/revoke")
    proxy.wait_until_succeeds("test $(find /var/lib/ziggy/spool -name '*.json' | wc -l) -eq 0")
    assert proxy.succeed("wc -l < /run/ziggy-fixture/provider-calls").strip() == "11"

with subtest("only the private socket is shared with Audi"):
    assert proxy.succeed("stat -c '%G %a' /run/ziggy").strip() == "ziggy-proxy 750"
    assert proxy.succeed("stat -c '%G %a' /run/ziggy/proxy.sock").strip() == "ziggy-proxy 660"
    proxy.succeed(
        "su -s /bin/sh audi -c 'curl --silent --fail --unix-socket /run/ziggy/proxy.sock http://ziggy/metrics >/dev/null'"
    )
    proxy.fail("su -s /bin/sh audi -c 'cat /run/ziggy/credentials/openai.key'")
    proxy.fail("su -s /bin/sh audi -c 'cat /run/ziggy/credentials/control.token'")

with subtest("host poll executes one model call and returns its content only to Marshall"):
    proxy.succeed("touch /run/ziggy-fixture/agent-ready")
    proxy.wait_until_succeeds("test -s /run/ziggy-fixture/agent-results.jsonl")
    result = json.loads(proxy.succeed("cat /run/ziggy-fixture/agent-results.jsonl").splitlines()[0])
    assert result["response"]["output"][0]["content"][0]["text"] == "synthetic agent reply"
    assert proxy.succeed("tail -n 1 /run/ziggy-fixture/provider-calls").strip() == "/v1/responses"
    assert result["claim_id"] == "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    proxy.wait_until_succeeds("test $(wc -l < /run/ziggy-fixture/completions.jsonl) -eq 12")
    proxy.succeed("systemctl restart ziggy.service")
    proxy.wait_until_succeeds(curl + " http://ziggy/health/ready")
    assert proxy.succeed("wc -l < /run/ziggy-fixture/agent-results.jsonl").strip() == "1"
    logs = proxy.succeed("journalctl -u ziggy.service --no-pager")
    assert "private agent prompt" not in logs
    assert "synthetic agent reply" not in logs

with subtest("unfinished admitted stream becomes one durable failure after SIGKILL"):
    proxy.wait_until_succeeds("test $(find /var/lib/ziggy/spool -name '*.json' | wc -l) -eq 0")
    proxy.wait_until_succeeds("jq -e '.requests == 12' /run/ziggy/slo.json")
    proxy.succeed("cp /run/ziggy/slo.json /run/ziggy-fixture/slo-before-interruption.json")
    proxy.succeed("touch /run/ziggy-fixture/hold-receipts")
    body = shlex.quote(
        json.dumps(dict(model="fixture-model", stream=True, hold=True, input="synthetic-input"))
    )
    stream = (
        curl.replace("--max-time 10", "--max-time 35")
        + headers
        + " --data-binary "
        + body
        + " -o /dev/null http://llm.internal/v1/responses"
    )
    proxy.succeed("systemd-run --unit ziggy-slo-crash-client --collect " + stream)
    proxy.wait_until_succeeds(
        curl + " http://ziggy/metrics | jq -e '.gauges.ziggy_active_requests == 1'"
    )
    proxy.wait_until_succeeds("test $(wc -l < /run/ziggy-fixture/provider-calls) -eq 13")
    proxy.succeed("systemctl kill --kill-whom=main --signal=KILL ziggy.service")
    proxy.wait_until_succeeds(curl + " http://ziggy/health/ready")
    proxy.wait_until_succeeds(
        "jq -s -e '.[1].requests == 13 and .[1].failures == .[0].failures + 1 "
        "and .[1].successes == .[0].successes "
        "and .[1].duration == .[0].duration "
        "and .[1].incarnation == .[0].incarnation "
        "and .[1].started_at_unix_nano == .[0].started_at_unix_nano' "
        "/run/ziggy-fixture/slo-before-interruption.json /run/ziggy/slo.json"
    )
    assert proxy.succeed("wc -l < /run/ziggy-fixture/provider-calls").strip() == "13"
    proxy.succeed("rm /run/ziggy-fixture/hold-receipts")
    proxy.wait_until_succeeds("test $(find /var/lib/ziggy/spool -name '*.json' | wc -l) -eq 0")
    proxy.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:9464/metrics | "
        "grep -E 'overalls_outer_ziggy_requests_total\\{[^}]*service_name=\"ziggy\"[^}]*\\} 13'",
        timeout=45,
    )

with subtest("native Anthropic beta URLs preserve request bytes and query-free accounting"):
    beta_headers = (
        headers
        + " -H 'anthropic-version: 2023-06-01'"
        + " -H 'anthropic-beta: synthetic-fixture-beta'"
        + " -H 'authorization: Bearer guest-sentinel'"
        + " -H 'x-api-key: guest-sentinel'"
        + " -H 'x-unexpected: synthetic-guest-header'"
    )
    beta_body = '{ "model": "fixture-model", "messages": [], "future_field": true }'
    beta_stream_body = (
        '{ "model": "fixture-model", "messages": [], "stream": true, "future_field": true }'
    )
    for path in [
        "/v1/messages",
        "/anthropic/v1/messages",
        "/v1/messages/count_tokens",
        "/anthropic/v1/messages/count_tokens",
    ]:
        native_body = beta_stream_body if path == "/v1/messages" else beta_body
        response = proxy.succeed(
            curl
            + beta_headers
            + " --data-binary "
            + shlex.quote(native_body)
            + " "
            + shlex.quote("http://llm.internal" + path + "?beta=true")
        )
        if path == "/v1/messages":
            expected = "data: "
        elif path.endswith("count_tokens"):
            expected = '{"input_tokens": 3}'
        else:
            expected = "synthetic-output"
        assert expected in response
    proxy.wait_until_succeeds("test $(wc -l < /run/ziggy-fixture/completions.jsonl) -eq 17")
    beta_requests = fixture_objects(
        proxy.succeed("tail -n 4 /run/ziggy-fixture/provider-requests.jsonl")
    )
    assert [request["path"] for request in beta_requests] == [
        "/v1/messages?beta=true",
        "/v1/messages?beta=true",
        "/v1/messages/count_tokens?beta=true",
        "/v1/messages/count_tokens?beta=true",
    ]
    for request, expected_body in zip(
        beta_requests, [beta_stream_body, beta_body, beta_body, beta_body], strict=True
    ):
        assert request["body"] == expected_body
        assert request["anthropic_version"] == "2023-06-01"
        assert request["anthropic_beta"] == "synthetic-fixture-beta"
        assert request["authorization"] is None
        assert request["unexpected"] is None
    beta_admissions = fixture_objects(
        proxy.succeed("tail -n 4 /run/ziggy-fixture/admissions.jsonl")
    )
    assert [admission["operation"] for admission in beta_admissions] == [
        "messages",
        "messages",
        "count_tokens",
        "count_tokens",
    ]
    beta_completions = fixture_objects(
        proxy.succeed("tail -n 4 /run/ziggy-fixture/completions.jsonl")
    )
    for completion in beta_completions:
        fields = fixture_object(completion["completion"])
        assert fields["completeness"] == "complete"
        assert fixture_object(fields["tokens"])["input_tokens"] == 3

with subtest("unsupported query aliases reject before provider effects"):
    for path in [
        "/v1/messages?beta=false",
        "/v1/messages?beta=true&extra=1",
        "/v1/messages?beta=true&beta=true",
        "/v1/messages?%62eta=true",
        "/v1/messages?beta=%74rue",
        "/v1/responses?beta=true",
        "/openai/v1/messages?beta=true",
    ]:
        refusal = proxy.succeed(
            curl.replace(" --fail", "")
            + headers
            + " --data-binary "
            + shlex.quote(beta_body)
            + " --write-out '\\n%{http_code}' "
            + shlex.quote("http://llm.internal" + path)
        )
        assert refusal.strip().endswith("400")
        assert '"invalid_request"' in refusal
    assert proxy.succeed("wc -l < /run/ziggy-fixture/provider-calls").strip() == "17"
