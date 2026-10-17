"""Native Brady accounting faults after actual real guest HTTP egress."""

from dataclasses import dataclass


@dataclass(frozen=True)
class BradyHistory:
    incarnation: str
    started: int
    coverage: int
    sampled: int
    requests: int
    successes: int
    failures: int
    durations: int

    def completed(self) -> tuple[str, int, int, int, int, int]:
        return (
            self.incarnation,
            self.started,
            self.requests,
            self.successes,
            self.failures,
            self.durations,
        )


def brady_slo_object(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise AssertionError("invalid Brady accounting object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise AssertionError("invalid Brady accounting key")
        result[key] = item
    return result


def brady_slo_integer(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise AssertionError("invalid Brady accounting counter")
    return value


def brady_history() -> BradyHistory:
    """@cc [owner:ghuntley,label:verification] brady-settled-native-history
    Continuity comparisons MUST match durable checkpoint identity, coverage and
    settled terminal totals to the publication; legacy counters cannot prove it.
    """
    l1.wait_until_succeeds(
        "jq --slurpfile snapshot /run/overalls-request-brady-source/slo.json -e "
        "'(.pending | length) == 0 and .totals.requests == $snapshot[0].requests "
        "and .totals.successes == $snapshot[0].successes "
        "and .totals.failures == $snapshot[0].failures "
        "and .totals.duration_count == $snapshot[0].duration.count "
        "and .incarnation == $snapshot[0].incarnation "
        "and .started_at_ns == $snapshot[0].started_at_unix_nano "
        "and .coverage_started_at_ns == $snapshot[0].coverage_started_at_unix_nano' "
        "/var/lib/overalls-request-brady/state.json"
    )
    raw = brady_slo_object(
        json.loads(l1.succeed("cat /run/overalls-request-brady-source/slo.json"))
    )
    incarnation = raw.get("incarnation")
    if raw.get("service") != "brady" or not isinstance(incarnation, str):
        raise AssertionError("invalid Brady accounting source")
    duration = brady_slo_object(raw.get("duration"))
    result = BradyHistory(
        incarnation,
        brady_slo_integer(raw.get("started_at_unix_nano")),
        brady_slo_integer(raw.get("coverage_started_at_unix_nano")),
        brady_slo_integer(raw.get("sampled_at_unix_nano")),
        brady_slo_integer(raw.get("requests")),
        brady_slo_integer(raw.get("successes")),
        brady_slo_integer(raw.get("failures")),
        brady_slo_integer(duration.get("count")),
    )
    assert result.requests == result.successes + result.failures
    assert result.durations <= result.requests
    return result


def brady_fresh_after(previous: BradyHistory) -> BradyHistory:
    l1.wait_until_succeeds(
        "jq -e '.sampled_at_unix_nano > "
        + str(previous.sampled)
        + "' /run/overalls-request-brady-source/slo.json"
    )
    return brady_history()


def brady_slo_faults(placement: str) -> None:
    """@cc [owner:ghuntley,label:verification] brady-native-restart-accounting
    After actual guest requests, recorder loss MUST preserve settled history
    with the producer alive. Clean restart MUST preserve coverage; idle crash
    MUST advance it. A fresh guest HTTP request MUST add one success/duration.
    """
    with subtest("Brady recorder loss preserves history and surviving producer"):
        recorded = brady_history()
        producer = l1.succeed("systemctl show brady.service -p MainPID --value").strip()
        l1.succeed(
            "systemctl kill --signal=SIGKILL --kill-whom=main overalls-request-brady.service"
        )
        l1.wait_for_unit("overalls-request-brady.service")
        l1.wait_until_succeeds(
            "jq -e '.coverage_started_at_unix_nano > "
            + str(recorded.coverage)
            + "' /run/overalls-request-brady-source/slo.json"
        )
        recovered = brady_fresh_after(recorded)
        assert recovered.completed() == recorded.completed()
        assert l1.succeed("systemctl show brady.service -p MainPID --value").strip() == producer

    with subtest("clean Brady restart preserves completed history and coverage"):
        recorded = brady_history()
        l1.succeed("systemctl restart brady.service")
        l1.wait_for_unit("brady.service")
        l1.wait_until_succeeds("jq -e '.gauges.cache_writable == 1' /run/brady/metrics.json")
        recovered = brady_fresh_after(recorded)
        assert recovered.completed() == recorded.completed()
        assert recovered.coverage == recorded.coverage

    with subtest("idle Brady producer loss advances coverage and accepts fresh guest HTTP"):
        recorded = brady_history()
        l1.succeed("systemctl kill --signal=SIGKILL --kill-whom=all brady.service")
        l1.wait_for_unit("brady.service")
        l1.wait_until_succeeds("jq -e '.gauges.cache_writable == 1' /run/brady/metrics.json")
        l1.wait_until_succeeds(
            "jq -e '.coverage_started_at_unix_nano > "
            + str(recorded.coverage)
            + "' /run/overalls-request-brady-source/slo.json"
        )
        recovered = brady_fresh_after(recorded)
        assert recovered.completed() == recorded.completed()
        l1.succeed("fleet-brady-guest http " + placement, timeout=160)
        l1.wait_until_succeeds(
            "jq -e '.requests == "
            + str(recorded.requests + 1)
            + " and .successes == "
            + str(recorded.successes + 1)
            + "' /run/overalls-request-brady-source/slo.json"
        )
        after = brady_history()
        assert after.incarnation == recorded.incarnation
        assert after.started == recorded.started
        assert after.failures == recorded.failures
        assert after.durations == recorded.durations + 1
