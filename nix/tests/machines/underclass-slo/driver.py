import shlex


def snapshot(requests: int, successes: int, failures: int) -> None:
    machine.wait_until_succeeds(
        f"jq -e '.requests == {requests} and .successes == {successes} "
        f"and .failures == {failures}' /run/underclass/slo/slo.json"
    )


def request(case: str) -> None:
    body: str = '{"model":"gpt-5.5","stream":true,"slo_case":"' + case + '"}'
    machine.succeed(
        "curl --noproxy '*' -fsS --max-time 30 "
        "-H 'Authorization: Bearer synthetic-proxy-key' "
        "-H 'Content-Type: application/json' --data "
        + shlex.quote(body)
        + " http://127.0.0.1:8080/v1/responses >/dev/null"
    )


machine.start()
machine.wait_for_unit("underclass.service")
machine.wait_for_open_port(8080, timeout=30)
machine.wait_for_unit("underclass-proxy-slo-exporter.service")
snapshot(0, 0, 0)

with subtest("empty lifetime and private custody survive restart"):
    machine.succeed("test $(stat -c %a /run/underclass/slo/slo.json) = 640")
    machine.succeed("cp /run/underclass/slo/slo.json /tmp/underclass-before-restart.json")
    machine.succeed("systemctl restart underclass.service")
    machine.wait_for_unit("underclass.service")
    snapshot(0, 0, 0)
    machine.succeed(
        "jq -s -e '.[0].incarnation == .[1].incarnation and "
        ".[0].started_at_unix_nano == .[1].started_at_unix_nano' "
        "/tmp/underclass-before-restart.json /run/underclass/slo/slo.json"
    )
    machine.fail("runuser -u nobody -- cat /run/underclass/slo/slo.json")
    machine.fail("runuser -u nobody -- test -w /run/overalls-otel-underclass-proxy/collector.sock")
    machine.succeed("test ! -e /run/underclass-fixture/calls")

with subtest("authorization and parsing refusals remain outside the denominator"):
    for credential in ["synthetic-admin-token", "synthetic-invalid-key"]:
        machine.succeed(
            "test $(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' "
            f"-H 'Authorization: Bearer {credential}' -H 'Content-Type: application/json' "
            '--data \'{"model":"gpt-5.5","stream":true}\' '
            "http://127.0.0.1:8080/v1/responses) = 401"
        )
    machine.succeed(
        "test $(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' "
        "-H 'Authorization: Bearer synthetic-proxy-key' -H 'Content-Type: application/json' "
        "--data '{broken' http://127.0.0.1:8080/v1/responses) = 400"
    )
    snapshot(0, 0, 0)
    machine.succeed("test ! -e /run/underclass-fixture/calls")

with subtest("completed and failed provider streams have durable terminal outcomes"):
    request("complete")
    snapshot(1, 1, 0)
    request("unterminated")
    snapshot(2, 1, 1)
    request("error")
    snapshot(3, 1, 2)
    machine.succeed("test $(cat /run/underclass-fixture/calls) = 3")
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:9464/metrics | "
        "grep -E 'overalls_outer_underclass_proxy_requests_total\\{[^}]*service_name=\"underclass_proxy\"[^}]*\\} 3'"
    )

with subtest("one totals journal carries the 15-bound histogram for long durations"):
    machine.succeed(
        "test -f /var/lib/underclass/slo-totals.sqlite && test ! -e /var/lib/underclass/slo.sqlite"
    )
    machine.succeed(
        'test "$(sqlite3 /var/lib/underclass/slo-totals.sqlite '
        "\"SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_master "
        "WHERE type='table' ORDER BY name)\")\" = slo_pending,slo_totals"
    )
    request("slow")
    snapshot(4, 2, 2)
    machine.succeed(
        'jq -e \'(keys | map(select(startswith("latency"))) | length) == 0 and '
        ".duration.count == 4 and (.duration.explicit_bounds_us | length) == 15 and "
        ".duration.explicit_bounds_us[14] == 86400000000 and "
        "(.duration.bucket_counts | length) == 16 and .duration.bucket_counts[7] == 1' "
        "/run/underclass/slo/slo.json"
    )
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:9464/metrics | "
        "grep -E 'overalls_outer_underclass_proxy_duration_seconds_bucket\\{[^}]*le=\"30\"[^}]*\\} 4'"
    )
    machine.succeed(
        "curl -fsS http://127.0.0.1:9464/metrics | "
        "grep -E 'overalls_outer_underclass_proxy_duration_seconds_bucket\\{[^}]*le=\"10\"[^}]*\\} 3'"
    )
    machine.fail("curl -fsS http://127.0.0.1:9464/metrics | grep -q latency_v2")

with subtest("SIGKILL finalizes one admitted interruption without provider replay"):
    machine.succeed(
        "curl --noproxy '*' -sS --max-time 60 "
        "-H 'Authorization: Bearer synthetic-proxy-key' -H 'Content-Type: application/json' "
        '--data \'{"model":"gpt-5.5","stream":true,"slo_case":"hold"}\' '
        "http://127.0.0.1:8080/v1/responses >/dev/null 2>/dev/null &"
    )
    machine.wait_until_succeeds("test -e /run/underclass-fixture/holding")
    machine.succeed("systemctl kill --kill-whom=main --signal=KILL underclass.service")
    machine.wait_for_unit("underclass.service")
    machine.wait_for_open_port(8080)
    snapshot(5, 2, 3)
    machine.succeed("test $(cat /run/underclass-fixture/calls) = 5")
    machine.succeed(
        "jq -e '.duration.count == 4 and .requests == 5 and "
        "(.duration.bucket_counts | add) == 4' /run/underclass/slo/slo.json"
    )
    machine.succeed(
        "jq -s -e '.[0].incarnation == .[1].incarnation and "
        ".[0].started_at_unix_nano == .[1].started_at_unix_nano' "
        "/tmp/underclass-before-restart.json /run/underclass/slo/slo.json"
    )

with subtest("exporter cannot read provider state or credentials"):
    machine.succeed(
        "pid=$(systemctl show underclass-proxy-slo-exporter.service -p MainPID --value); "
        "test $pid -gt 0; nsenter -t $pid -m -- runuser -u otel-underclass-exporter -- sh -c "
        "'test ! -r /var/lib/underclass/pool.db && test ! -r /etc/underclass-test.env'"
    )
    machine.succeed(
        "producer=$(systemctl show underclass.service -p MainPID --value); "
        "exporter=$(systemctl show underclass-proxy-slo-exporter.service -p MainPID --value); "
        "test $producer -gt 0; test $exporter -gt 0; "
        "test $(stat -c %u /proc/$producer) != $(stat -c %u /proc/$exporter); "
        "runuser -u otel-underclass-exporter -- sh -c 'test ! -r /proc/'$producer'/environ'"
    )

with subtest("collector retains a stopped source clock without making it current"):
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:9464/metrics | "
        "grep '^overalls_outer_underclass_proxy_source_sample_time{'"
    )
    machine.succeed("systemctl stop underclass-proxy-slo-exporter.service")
    machine.sleep(46)
    machine.succeed(
        "curl -fsS http://127.0.0.1:9464/metrics | "
        "awk '/^overalls_outer_underclass_proxy_source_sample_time\\{/ "
        "{seen=1; if (systime()-$NF <= 45) exit 1} END {if (!seen) exit 1}'"
    )
