import base64
import hashlib
import json
import time

curl = "curl --silent --show-error --fail"

start_all()
proxy.wait_for_unit("galileo-fixture.service")
proxy.wait_until_succeeds("test -S /run/galileo-fixture/connector.sock")
proxy.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
proxy.succeed("python3 /etc/galileo-seal.py")
proxy.succeed("systemctl restart overalls-secrets-galileo.service")
proxy.succeed("systemctl start galileo.service")
proxy.wait_for_unit("galileo.service")

proxy.wait_until_succeeds(
    f"{curl} --unix-socket /run/galileo/proxy.sock http://galileo/health/ready"
)
proxy.succeed("ip address add 169.254.254.1/32 dev lo")
proxy.succeed("systemctl start audi-private-fixture.service")
proxy.wait_for_unit("audi-private-fixture.service")
gateway = client.succeed("cat /etc/galileo-proxy-address").strip()
client.succeed("ip route add 169.254.254.1/32 via " + gateway)
deployed = (
    "curl --noproxy '*' --silent --show-error --cacert /etc/galileo-ca.pem "
    "--connect-timeout 3 --max-time 45"
)
client.wait_until_succeeds(
    deployed
    + " -o /dev/null -w '%{http_code}' https://esample.integration.internal/api/v3/ready | grep -Fx 200",
    timeout=60,
)

raw_binding = proxy.succeed("cat /etc/galileo-binding.json").strip()
json.loads(raw_binding)
encoded = base64.urlsafe_b64encode(raw_binding.encode()).decode().rstrip("=")
headers = f"-H 'x-overalls-binding: {encoded}'"

metrics = json.loads(
    proxy.succeed(f"{curl} --unix-socket /run/galileo/proxy.sock http://galileo/metrics")
)
assert metrics["gauges"]["galileo_active_requests"] == 0
assert metrics["gauges"]["galileo_total_requests"] >= 0

with subtest("injected credentials reach the origin and never the guest"):
    response = proxy.succeed(
        f"{curl} --unix-socket /run/galileo/proxy.sock -H 'Host: esample.integration.internal' "
        f"-H 'authorization: Bearer guest-attempt' -H 'x-guest-attempt: visible' "
        + headers
        + " --data-binary '{\"hello\":1}' 'http://esample.integration.internal/api/v3/users'"
    )
    served = json.loads(response)
    assert served["path"] == "/users", served
    records = [
        json.loads(line)
        for line in proxy.succeed("cat /run/galileo-fixture/observed.jsonl").splitlines()
    ]
    assert records[-1]["authorization"] == "Bearer sk-origin-secret", records[-1]
    assert records[-1]["x_team"] == "platform", records[-1]
    assert records[-1]["guest_attempt"] == "visible", records[-1]
    assert "sk-origin-secret" not in proxy.succeed("journalctl -u galileo.service --no-pager")
    assert not proxy.succeed("find /var/lib/galileo -type f -print 2>/dev/null || true").strip()

with subtest("authorized Galileo outcome enters only the private cumulative SLO snapshot"):
    proxy.wait_until_succeeds(
        f"{curl} --unix-socket /run/galileo/proxy.sock http://localhost/slo | "
        'jq -e \'.service == "galileo" and .requests >= 1 and .successes >= 1 '
        "and .requests == (.successes + .failures) and "
        ".duration.count == .requests and "
        "([.duration.bucket_counts[]] | add) == .duration.count'"
    )
    proxy.succeed(
        "test $(curl --silent --output /dev/null --write-out '%{http_code}' "
        "--unix-socket /run/galileo/proxy.sock -H 'Host: esample.integration.internal' "
        "http://esample.integration.internal/slo) = 403"
    )

with subtest("Rust exporter delivers Galileo-owned outcomes to the isolated collector"):
    proxy.wait_for_unit("overalls-request-galileo-exporter.service")
    proxy.wait_until_succeeds(
        "jq -e '.service == \"galileo\" and .requests >= 1 and .successes >= 1' "
        "/run/overalls-request-galileo-source/slo.json"
    )
    proxy.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:9464/metrics | "
        'grep -E \'overalls_outer_galileo_requests_total\\{[^}]*overalls_telemetry_origin="application"[^}]*service_name="galileo"[^}]*\\} [1-9][0-9]*\'',
        timeout=45,
    )
    proxy.succeed(
        "code=$(runuser -u galileo -- curl --silent --output /dev/null "
        "--write-out '%{http_code}' --unix-socket "
        "/run/overalls-otel-galileo/collector.sock http://localhost/v1/metrics || true); "
        'test "$code" = 000'
    )

with subtest("strip prefix is segment aligned"):
    response = proxy.succeed(
        f"{curl} --unix-socket /run/galileo/proxy.sock -H 'Host: esample.integration.internal' "
        + headers
        + " 'http://esample.integration.internal/api/v3x/other'"
    )
    assert json.loads(response)["path"] == "/api/v3x/other"

with subtest("deployed Galileo preserves a multi-pull binary upload"):
    payload = bytes(range(256)) * 768 + b"galileo-multi-pull!"
    expected_digest = hashlib.sha256(payload).hexdigest()
    proxy.succeed(
        'python3 -c "from pathlib import Path; '
        "Path('/run/galileo-upload.bin').write_bytes(bytes(range(256)) * 768 + "
        "b'galileo-multi-pull!')\""
    )
    response = proxy.succeed(
        f"{curl} --unix-socket /run/galileo/proxy.sock -H 'Host: esample.integration.internal' "
        + headers
        + " --data-binary @/run/galileo-upload.bin "
        + "'http://esample.integration.internal/api/v3/upload'"
    )
    served = json.loads(response)
    assert served["path"] == "/upload", served
    assert served["body_bytes"] == len(payload), served
    assert served["body_sha256"] == expected_digest, served
    assert served["transfer_encoding"] == "chunked", served
    assert served["transport_chunks"] >= 2, served

for phase in ("lease-blocked-upload", "lease-partial-response"):
    with subtest("renewal refusal interrupts a blocked packaged Bandit upload: " + phase):
        for terminal in ("refused", "invalid", "blocked"):
            proxy.succeed(
                "python3 /etc/galileo-client.py " + phase + " unused " + terminal,
                timeout=15,
            )
            proxy.wait_until_succeeds(
                f"{curl} --unix-socket /run/galileo/proxy.sock http://galileo/metrics | "
                "jq -e '.gauges.galileo_active_requests == 0'",
                timeout=5,
            )

with subtest("packaged Audi forwards GET and POST to packaged Galileo across machines"):
    response = client.succeed(deployed + " 'https://esample.integration.internal/api/v3/users'")
    served = json.loads(response)
    assert served["path"] == "/users", served
    assert served["body_bytes"] == 0, served
    client.succeed(
        'python3 -c "from pathlib import Path; '
        "Path('/run/deployed-upload.bin').write_bytes(bytes(range(256)) * 768 + "
        "b'deployed-audi-galileo!')\""
    )
    client.succeed(
        "python3 /etc/galileo-client.py upload /etc/galileo-ca.pem /run/deployed-upload.bin",
        timeout=30,
    )

with subtest("Audi preserves query strings and ordinary HTTP methods"):
    response = client.succeed(
        deployed + " 'https://esample.integration.internal/api/v3/users?visible=true'"
    )
    served = json.loads(response)
    assert served["path"] == "/users?visible=true", served
    response = client.succeed(
        deployed + " -X PUT 'https://esample.integration.internal/api/v3/users'"
    )
    served = json.loads(response)
    assert served["method"] == "PUT", served
    assert served["path"] == "/users", served

with subtest("a stalled source is closed by the deployed streaming path"):
    client.succeed(
        "python3 /etc/galileo-client.py stalled-source /etc/galileo-ca.pem",
        timeout=20,
    )
    proxy.wait_until_succeeds(
        f"{curl} --unix-socket /run/galileo/proxy.sock http://galileo/metrics | "
        "jq -e '.gauges.galileo_active_requests == 0'"
    )

with subtest("a stalled destination is bounded without a retry"):
    before = sum(
        json.loads(line)["path"].startswith("/stall")
        for line in proxy.succeed("cat /run/galileo-fixture/observed.jsonl").splitlines()
    )
    started = time.monotonic()
    client.fail(
        deployed + " --fail 'https://esample.integration.internal/api/v3/stall'",
        timeout=45,
    )
    elapsed = time.monotonic() - started
    assert 25 <= elapsed <= 38, elapsed
    after = sum(
        json.loads(line)["path"].startswith("/stall")
        for line in proxy.succeed("cat /run/galileo-fixture/observed.jsonl").splitlines()
    )
    assert after == before + 1
    proxy.wait_until_succeeds(
        f"{curl} --unix-socket /run/galileo/proxy.sock http://galileo/metrics | "
        "jq -e '.gauges.galileo_active_requests == 0'"
    )

with subtest("binding change fences an active request and denies the replacement"):
    client.succeed(
        "systemctl reset-failed galileo-relocation.service 2>/dev/null || true; "
        "systemd-run --unit=galileo-relocation /run/current-system/sw/bin/curl "
        "--noproxy '*' --silent --show-error --fail --cacert /etc/galileo-ca.pem "
        "--max-time 45 https://esample.integration.internal/api/v3/stall"
    )
    proxy.wait_until_succeeds(
        f"{curl} --unix-socket /run/galileo/proxy.sock http://galileo/metrics | "
        "jq -e '.gauges.galileo_active_requests == 1'"
    )
    proxy.succeed("printf moved > /run/galileo-fixture/connector-mode")
    client.wait_until_succeeds(
        "systemctl show -p SubState --value galileo-relocation.service | grep -E '^(dead|failed)$'",
        timeout=8,
    )
    assert (
        client.succeed(
            "systemctl show -p ExecMainStatus --value galileo-relocation.service"
        ).strip()
        != "0"
    )
    status = client.succeed(
        deployed
        + " -o /dev/null -w '%{http_code}' 'https://esample.integration.internal/api/v3/users'"
    )
    assert status.strip() == "403", status
    proxy.wait_until_succeeds(
        f"{curl} --unix-socket /run/galileo/proxy.sock http://galileo/metrics | "
        "jq -e '.gauges.galileo_active_requests == 0'",
        timeout=20,
    )
    proxy.succeed("rm /run/galileo-fixture/connector-mode")

with subtest("control authority refusal preserves guest403 before the destination"):
    before = int(proxy.succeed("wc -l < /run/galileo-fixture/observed.jsonl").strip())
    proxy.succeed("printf denied > /run/galileo-fixture/control-mode")
    status = client.succeed(
        deployed
        + " -o /dev/null -w '%{http_code}' 'https://esample.integration.internal/api/v3/users'"
    )
    assert status.strip() == "403", status
    after = int(proxy.succeed("wc -l < /run/galileo-fixture/observed.jsonl").strip())
    assert after == before
    proxy.succeed("rm /run/galileo-fixture/control-mode")

with subtest("control authority outage remains guest503 without destination effects"):
    before = int(proxy.succeed("wc -l < /run/galileo-fixture/observed.jsonl").strip())
    proxy.succeed("printf outage > /run/galileo-fixture/control-mode")
    status = client.succeed(
        deployed
        + " -o /dev/null -w '%{http_code}' 'https://esample.integration.internal/api/v3/users'"
    )
    assert status.strip() == "503", status
    after = int(proxy.succeed("wc -l < /run/galileo-fixture/observed.jsonl").strip())
    assert after == before
    proxy.succeed("rm /run/galileo-fixture/control-mode")

with subtest("bounded concurrent cross-machine load completes without leaked requests"):
    before_metrics = json.loads(
        proxy.succeed(f"{curl} --unix-socket /run/galileo/proxy.sock http://galileo/metrics")
    )
    client.succeed(
        "python3 /etc/galileo-client.py sustained /etc/galileo-ca.pem 64",
        timeout=90,
    )
    proxy.wait_until_succeeds(
        f"{curl} --unix-socket /run/galileo/proxy.sock http://galileo/metrics | "
        "jq -e '.gauges.galileo_active_requests == 0'",
        timeout=20,
    )
    after_metrics = json.loads(
        proxy.succeed(f"{curl} --unix-socket /run/galileo/proxy.sock http://galileo/metrics")
    )
    assert after_metrics["gauges"]["galileo_active_requests"] == 0
    assert (
        after_metrics["gauges"]["galileo_total_requests"]
        == before_metrics["gauges"]["galileo_total_requests"] + 64
    )

with subtest("forged bindings and unknown names deny"):
    proxy.fail(
        f"{curl} --unix-socket /run/galileo/proxy.sock -H 'Host: esample.integration.internal' "
        "-H 'x-overalls-binding: Zm9yZ2Vk' 'http://esample.integration.internal/api/v3/users'"
    )
    proxy.fail(
        f"{curl} --unix-socket /run/galileo/proxy.sock -H 'Host: denied.integration.internal' "
        + headers
        + " 'http://denied.integration.internal/'"
    )
    proxy.fail(
        f"{curl} --unix-socket /run/galileo/proxy.sock -H 'Host: a.b.integration.internal' "
        + headers
        + " 'http://a.b.integration.internal/'"
    )

with subtest("only the private socket is shared and restart preserves denial"):
    assert proxy.succeed("stat -c '%G %a' /run/galileo/proxy.sock").strip() == "galileo-proxy 660"
    proxy.succeed("systemctl restart galileo.service")
    proxy.wait_until_succeeds(
        f"{curl} --unix-socket /run/galileo/proxy.sock http://galileo/health/ready"
    )
    proxy.fail(
        f"{curl} --unix-socket /run/galileo/proxy.sock -H 'Host: denied.integration.internal' "
        + headers
        + " 'http://denied.integration.internal/'"
    )
