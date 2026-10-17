"""Native Porsche accounting faults after actual approved-key SSH dispatch."""

from dataclasses import dataclass


@dataclass(frozen=True)
class PorscheHistory:
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


def porsche_slo_object(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise AssertionError("invalid Porsche accounting object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise AssertionError("invalid Porsche accounting key")
        result[key] = item
    return result


def porsche_slo_integer(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise AssertionError("invalid Porsche accounting counter")
    return value


def porsche_history() -> PorscheHistory:
    """@cc [owner:ghuntley,label:verification] porsche-settled-native-history
    Continuity comparisons MUST match durable checkpoint identity, coverage and
    settled terminal totals to the publication; legacy counters cannot prove it.
    """
    m1.wait_until_succeeds(
        "jq --slurpfile snapshot /run/overalls-request-porsche-source/slo.json -e "
        "'(.pending | length) == 0 and .totals.requests == $snapshot[0].requests "
        "and .totals.successes == $snapshot[0].successes "
        "and .totals.failures == $snapshot[0].failures "
        "and .totals.duration_count == $snapshot[0].duration.count "
        "and .incarnation == $snapshot[0].incarnation "
        "and .started_at_ns == $snapshot[0].started_at_unix_nano "
        "and .coverage_started_at_ns == $snapshot[0].coverage_started_at_unix_nano' "
        "/var/lib/overalls-request-porsche/state.json"
    )
    raw = porsche_slo_object(
        json.loads(m1.succeed("cat /run/overalls-request-porsche-source/slo.json"))
    )
    incarnation = raw.get("incarnation")
    if raw.get("service") != "porsche" or not isinstance(incarnation, str):
        raise AssertionError("invalid Porsche accounting source")
    duration = porsche_slo_object(raw.get("duration"))
    result = PorscheHistory(
        incarnation,
        porsche_slo_integer(raw.get("started_at_unix_nano")),
        porsche_slo_integer(raw.get("coverage_started_at_unix_nano")),
        porsche_slo_integer(raw.get("sampled_at_unix_nano")),
        porsche_slo_integer(raw.get("requests")),
        porsche_slo_integer(raw.get("successes")),
        porsche_slo_integer(raw.get("failures")),
        porsche_slo_integer(duration.get("count")),
    )
    assert result.requests == result.successes + result.failures
    assert result.durations <= result.requests
    return result


def porsche_fresh_after(previous: PorscheHistory) -> PorscheHistory:
    m1.wait_until_succeeds(
        "jq -e '.sampled_at_unix_nano > "
        + str(previous.sampled)
        + "' /run/overalls-request-porsche-source/slo.json"
    )
    return porsche_history()


with subtest("Porsche recorder loss preserves history and surviving producer"):
    recorded = porsche_history()
    producer = m1.succeed("systemctl show porsche.service -p MainPID --value").strip()
    m1.succeed("systemctl kill --signal=SIGKILL --kill-whom=main overalls-request-porsche.service")
    m1.wait_for_unit("overalls-request-porsche.service")
    m1.wait_until_succeeds(
        "jq -e '.coverage_started_at_unix_nano > "
        + str(recorded.coverage)
        + "' /run/overalls-request-porsche-source/slo.json"
    )
    recovered = porsche_fresh_after(recorded)
    assert recovered.completed() == recorded.completed()
    assert m1.succeed("systemctl show porsche.service -p MainPID --value").strip() == producer

with subtest("clean Porsche restart preserves completed history and coverage"):
    recorded = porsche_history()
    m1.succeed("systemctl restart porsche.service")
    m1.wait_for_unit("porsche.service")
    m1.wait_for_open_port(22)
    recovered = porsche_fresh_after(recorded)
    assert recovered.completed() == recorded.completed()
    assert recovered.coverage == recorded.coverage

with subtest("idle Porsche producer loss advances coverage and accepts fresh SSH"):
    recorded = porsche_history()
    m1.succeed("systemctl kill --signal=SIGKILL --kill-whom=all porsche.service")
    m1.wait_for_unit("porsche.service")
    m1.wait_for_open_port(22)
    m1.wait_until_succeeds(
        "jq -e '.coverage_started_at_unix_nano > "
        + str(recorded.coverage)
        + "' /run/overalls-request-porsche-source/slo.json"
    )
    recovered = porsche_fresh_after(recorded)
    assert recovered.completed() == recorded.completed()
    assert porsche_command("whoami")["status"] == "succeeded"
    m1.wait_until_succeeds(
        "jq -e '.requests == "
        + str(recorded.requests + 1)
        + " and .successes == "
        + str(recorded.successes + 1)
        + "' /run/overalls-request-porsche-source/slo.json"
    )
    after = porsche_history()
    assert after.incarnation == recorded.incarnation
    assert after.started == recorded.started
    assert after.failures == recorded.failures
    assert after.durations == recorded.durations + 1
