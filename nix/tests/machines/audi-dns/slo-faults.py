"""Native DNS producer/recorder continuity; no production credentials or routes."""

from dataclasses import dataclass


@dataclass(frozen=True)
class DnsHistory:
    incarnation: str
    started: int
    coverage: int
    sampled: int
    requests: int
    successes: int
    failures: int
    durations: int
    duration_sum: int
    buckets: tuple[int, ...]

    def completed(self) -> tuple[str, int, int, int, int, int, int, tuple[int, ...]]:
        return (
            self.incarnation,
            self.started,
            self.requests,
            self.successes,
            self.failures,
            self.durations,
            self.duration_sum,
            self.buckets,
        )


def dns_object(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise AssertionError("invalid DNS SLO object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise AssertionError("invalid DNS SLO key")
        result[key] = item
    return result


def dns_integer(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise AssertionError("invalid DNS SLO counter")
    return value


def dns_history() -> DnsHistory:
    """@cc [owner:ghuntley,label:verification] dns-native-durable-history
    Comparisons MUST use a fresh validated durable publication matching settled
    checkpoint totals; legacy in-memory counters MUST NOT prove continuity.
    """
    server.wait_until_succeeds(
        "jq --slurpfile snapshot /run/overalls-request-audi-dns-source/slo.json -e "
        "'(.pending | length) == 0 and .totals.requests == $snapshot[0].requests "
        "and .totals.successes == $snapshot[0].successes "
        "and .totals.failures == $snapshot[0].failures "
        "and .totals.duration_count == $snapshot[0].duration.count "
        "and .totals.duration_sum_us == $snapshot[0].duration.sum_us "
        "and .totals.bucket_counts == $snapshot[0].duration.bucket_counts "
        "and .incarnation == $snapshot[0].incarnation "
        "and .started_at_ns == $snapshot[0].started_at_unix_nano "
        "and .coverage_started_at_ns == $snapshot[0].coverage_started_at_unix_nano' "
        "/var/lib/overalls-request-audi-dns/state.json"
    )
    raw = dns_object(
        json.loads(server.succeed("cat /run/overalls-request-audi-dns-source/slo.json"))
    )
    incarnation = raw.get("incarnation")
    if raw.get("service") != "audi_dns" or not isinstance(incarnation, str):
        raise AssertionError("invalid DNS SLO source")
    duration = dns_object(raw.get("duration"))
    buckets = duration.get("bucket_counts")
    if not isinstance(buckets, list) or len(buckets) != 8:
        raise AssertionError("invalid DNS duration buckets")
    result = DnsHistory(
        incarnation,
        dns_integer(raw.get("started_at_unix_nano")),
        dns_integer(raw.get("coverage_started_at_unix_nano")),
        dns_integer(raw.get("sampled_at_unix_nano")),
        dns_integer(raw.get("requests")),
        dns_integer(raw.get("successes")),
        dns_integer(raw.get("failures")),
        dns_integer(duration.get("count")),
        dns_integer(duration.get("sum_us")),
        tuple(dns_integer(item) for item in buckets),
    )
    assert result.requests == result.successes + result.failures
    assert result.durations <= result.requests
    assert sum(result.buckets) == result.durations
    return result


def dns_fresh_after(previous: DnsHistory) -> DnsHistory:
    server.wait_until_succeeds(
        "jq -e '.sampled_at_unix_nano > "
        + str(previous.sampled)
        + "' /run/overalls-request-audi-dns-source/slo.json"
    )
    return dns_history()


def dns_wait_ready() -> None:
    server.wait_until_succeeds(
        'python3 -c "import socket,json; s=socket.socket(socket.AF_UNIX); '
        "s.settimeout(7); s.connect('/run/audi-dns/status.sock'); "
        "v:object=json.loads(s.recv(4096)); "
        "assert isinstance(v,dict) and v.get('ready') is True; s.close()\""
    )


def dns_admitted_loss() -> None:
    """@cc [owner:ghuntley,label:verification;accounting] dns-native-admitted-loss
    A real eligible DNS request MUST obtain an acknowledged durable ticket before
    the hold is marked and its producer is killed; its worker is held from its
    admission call, so it can never answer first. Exactly one failure MUST
    settle before the original deadline, without adding a duration or changing
    completed history/identity. The recorder MUST survive and fresh DNS recover.
    The client MUST exit unsuccessfully, not be killed by its fixture timeout.
    """
    recorded = dns_history()
    recorder = server.succeed(
        "systemctl show overalls-request-audi-dns.service -p MainPID --value"
    ).strip()
    producer = server.succeed("systemctl show audi-dns.service -p MainPID --value").strip()
    server.succeed(
        "audi rpc 'Code.compiler_options(warnings_as_errors: true); "
        'Code.require_file("/etc/dns-native-hold.exs"); :ok = NativeDnsHold.arm()\' '
        ">/dev/null",
        timeout=20,
    )
    client_started = int(server.succeed("date +%s%N"))
    server.succeed(
        "systemd-run --no-block --unit=dns-admitted-client --property=Type=oneshot "
        "--property=TimeoutStartSec=30 --property=StandardOutput=null "
        "--property=StandardError=null /run/current-system/sw/bin/dig "
        f"@127.0.0.1 {label} A +tcp +time=25 +tries=1"
    )
    server.wait_until_succeeds("test -f /run/audi-dns/native-admission-held", timeout=20)
    checkpoint = "/var/lib/overalls-request-audi-dns/state.json"
    server.succeed(
        f"jq -e '(.pending | length) == 1 and .totals.requests == {recorded.requests}' {checkpoint}"
    )
    deadline = int(server.succeed("jq -er '[.pending[].deadline_ns][0]' " + checkpoint))
    assert int(server.succeed("date +%s%N")) < deadline
    assert server.succeed("systemctl show audi-dns.service -p MainPID --value").strip() == producer
    server.succeed("systemctl kill --signal=SIGKILL --kill-whom=all audi-dns.service")
    server.wait_until_succeeds(
        "jq -e '(.pending | length) == 0 "
        f"and .totals.requests == {recorded.requests + 1} "
        f"and .totals.failures == {recorded.failures + 1}' {checkpoint}"
    )
    assert int(server.succeed("date +%s%N")) < deadline
    recovered = dns_fresh_after(recorded)
    assert recovered.incarnation == recorded.incarnation
    assert recovered.started == recorded.started
    assert recovered.successes == recorded.successes
    assert recovered.durations == recorded.durations
    assert recovered.duration_sum == recorded.duration_sum
    assert recovered.buckets == recorded.buckets
    assert recovered.coverage > recorded.coverage
    assert (
        server.succeed(
            "systemctl show overalls-request-audi-dns.service -p MainPID --value"
        ).strip()
        == recorder
    )
    server.wait_until_succeeds(
        'test "$(systemctl show dns-admitted-client.service -p Result --value)" = exit-code'
    )
    assert (
        server.succeed("systemctl show dns-admitted-client.service -p ExecMainCode --value").strip()
        == "1"
    )
    assert (
        int(server.succeed("systemctl show dns-admitted-client.service -p ExecMainStatus --value"))
        > 0
    )
    assert int(server.succeed("date +%s%N")) - client_started < 25_000_000_000
    server.wait_for_unit("audi-dns.service")
    dns_wait_ready()
    assert "192.0.2.9" in server.succeed(f"dig @127.0.0.1 {label} A +short +tcp +time=2 +tries=1")
    server.wait_until_succeeds(
        "jq -e '.requests == "
        + str(recorded.requests + 2)
        + " and .successes == "
        + str(recorded.successes + 1)
        + "' /run/overalls-request-audi-dns-source/slo.json"
    )
    after = dns_history()
    assert after.incarnation == recorded.incarnation and after.started == recorded.started
    assert after.failures == recorded.failures + 1
    assert after.durations == recorded.durations + 1


with subtest("DNS recorder SIGKILL preserves completed history with producer alive"):
    recorded = dns_history()
    producer = server.succeed("systemctl show audi-dns.service -p MainPID --value").strip()
    server.succeed(
        "systemctl kill --signal=SIGKILL --kill-whom=main overalls-request-audi-dns.service"
    )
    server.wait_for_unit("overalls-request-audi-dns.service")
    server.wait_until_succeeds(
        "jq -e '.coverage_started_at_unix_nano > "
        + str(recorded.coverage)
        + "' /run/overalls-request-audi-dns-source/slo.json"
    )
    recovered = dns_fresh_after(recorded)
    assert recovered.completed() == recorded.completed()
    assert recovered.coverage > recorded.coverage
    assert server.succeed("systemctl show audi-dns.service -p MainPID --value").strip() == producer

with subtest("clean DNS restart preserves settled history and coverage"):
    recorded = dns_history()
    server.succeed("systemctl restart audi-dns.service")
    server.wait_for_unit("audi-dns.service")
    dns_wait_ready()
    recovered = dns_fresh_after(recorded)
    assert recovered.completed() == recorded.completed()
    assert recovered.coverage == recorded.coverage

with subtest("unclean DNS restart withholds coverage without resetting completed history"):
    recorded = dns_history()
    server.succeed("systemctl kill --signal=SIGKILL --kill-whom=all audi-dns.service")
    server.wait_for_unit("audi-dns.service")
    server.wait_until_succeeds(
        "jq -e '.coverage_started_at_unix_nano > "
        + str(recorded.coverage)
        + "' /run/overalls-request-audi-dns-source/slo.json"
    )
    recovered = dns_fresh_after(recorded)
    assert recovered.completed() == recorded.completed()
    dns_wait_ready()
    assert "192.0.2.9" in server.succeed(f"dig @127.0.0.1 {label} A +short +tcp +time=2 +tries=1")
    server.wait_until_succeeds(
        "jq -e '.requests == "
        + str(recorded.requests + 1)
        + " and .successes == "
        + str(recorded.successes + 1)
        + "' /run/overalls-request-audi-dns-source/slo.json"
    )
    after_query = dns_history()
    assert after_query.incarnation == recorded.incarnation
    assert after_query.started == recorded.started
    assert after_query.failures == recorded.failures
    assert after_query.durations == recorded.durations + 1

with subtest("admitted DNS producer loss settles one unknown-duration failure"):
    dns_admitted_loss()
