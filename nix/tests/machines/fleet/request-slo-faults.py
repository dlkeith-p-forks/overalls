"""Native accounting faults for real Galileo and Audi transport producers."""

from dataclasses import dataclass
from typing import Literal

RequestSource = Literal["galileo", "audi_private", "audi_ssh"]


@dataclass(frozen=True)
class TransportHistory:
    incarnation: str
    started: int
    coverage: int
    sampled: int
    requests: int
    successes: int
    failures: int
    durations: int
    buckets: tuple[int, ...]

    def completed(self) -> tuple[str, int, int, int, int, int, tuple[int, ...]]:
        return (
            self.incarnation,
            self.started,
            self.requests,
            self.successes,
            self.failures,
            self.durations,
            self.buckets,
        )


def transport_binding(source: RequestSource) -> tuple[str, str]:
    match source:
        case "galileo":
            return "galileo", "galileo.service"
        case "audi_private":
            return "audi-private", "audi-private.service"
        case "audi_ssh":
            return "audi-ssh", "audi.service"
    raise AssertionError("unknown native transport source")


def transport_object(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise AssertionError("invalid transport accounting object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise AssertionError("invalid transport accounting key")
        result[key] = item
    return result


def transport_integer(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise AssertionError("invalid transport accounting counter")
    return value


def transport_buckets(value: object) -> tuple[int, ...]:
    if not isinstance(value, list) or len(value) != 8:
        raise AssertionError("invalid transport duration buckets")
    return tuple(transport_integer(item) for item in value)


def transport_history(machine: MachineLike, source: RequestSource) -> TransportHistory:
    """@cc [owner:ghuntley,label:verification] transport-settled-checkpoint-history
    Continuity comparisons MUST match settled checkpoint identity, coverage,
    terminal totals and histogram buckets to the durable source publication.
    """
    instance, _ = transport_binding(source)
    publication = f"/run/overalls-request-{instance}-source/slo.json"
    checkpoint = f"/var/lib/overalls-request-{instance}/state.json"
    machine.wait_until_succeeds(
        f"jq --slurpfile snapshot {publication} -e "
        "'(.pending | length) == 0 and .totals.requests == $snapshot[0].requests "
        "and .totals.successes == $snapshot[0].successes "
        "and .totals.failures == $snapshot[0].failures "
        "and .totals.duration_count == $snapshot[0].duration.count "
        "and .totals.bucket_counts == $snapshot[0].duration.bucket_counts "
        "and .incarnation == $snapshot[0].incarnation "
        "and .started_at_ns == $snapshot[0].started_at_unix_nano "
        "and .coverage_started_at_ns == $snapshot[0].coverage_started_at_unix_nano' " + checkpoint
    )
    raw = transport_object(json.loads(machine.succeed("cat " + publication)))
    incarnation = raw.get("incarnation")
    if raw.get("service") != source or not isinstance(incarnation, str) or not incarnation:
        raise AssertionError("invalid transport accounting source")
    duration = transport_object(raw.get("duration"))
    result = TransportHistory(
        incarnation,
        transport_integer(raw.get("started_at_unix_nano")),
        transport_integer(raw.get("coverage_started_at_unix_nano")),
        transport_integer(raw.get("sampled_at_unix_nano")),
        transport_integer(raw.get("requests")),
        transport_integer(raw.get("successes")),
        transport_integer(raw.get("failures")),
        transport_integer(duration.get("count")),
        transport_buckets(duration.get("bucket_counts")),
    )
    assert result.requests == result.successes + result.failures
    assert sum(result.buckets) == result.durations <= result.requests
    return result


def transport_fresh_after(
    machine: MachineLike, source: RequestSource, previous: TransportHistory
) -> TransportHistory:
    instance, _ = transport_binding(source)
    machine.wait_until_succeeds(
        "jq -e '.sampled_at_unix_nano > "
        + str(previous.sampled)
        + f"' /run/overalls-request-{instance}-source/slo.json"
    )
    return transport_history(machine, source)


def transport_probe_after(
    machine: MachineLike,
    source: RequestSource,
    previous: TransportHistory,
    probe: Callable[[], None],
) -> TransportHistory:
    probe()
    instance, _ = transport_binding(source)
    machine.wait_until_succeeds(
        "jq -e '.requests == "
        + str(previous.requests + 1)
        + " and .successes == "
        + str(previous.successes + 1)
        + f"' /run/overalls-request-{instance}-source/slo.json"
    )
    after = transport_history(machine, source)
    assert after.incarnation == previous.incarnation
    assert after.started == previous.started
    assert after.failures == previous.failures
    assert after.durations == previous.durations + 1
    return after


def transport_restart_faults(
    machine: MachineLike,
    source: RequestSource,
    ready: Callable[[], None],
    probe: Callable[[], None],
) -> None:
    """@cc [owner:ghuntley,label:verification] transport-native-restart-accounting
    Real request sources MUST preserve settled history through recorder loss
    with the producer alive. Clean producer restart MUST preserve coverage;
    idle SIGKILL MUST advance it. Each recovery MUST accept one actual request
    adding exactly one successful outcome and duration. No in-flight loss claim.
    """
    instance, unit = transport_binding(source)
    publication = f"/run/overalls-request-{instance}-source/slo.json"
    with subtest(f"{source}: recorder loss preserves history with producer alive"):
        recorded = transport_history(machine, source)
        producer = int(machine.succeed(f"systemctl show {unit} -p MainPID --value").strip())
        assert producer > 0
        machine.succeed(
            f"systemctl kill --signal=SIGKILL --kill-whom=main overalls-request-{instance}.service"
        )
        machine.wait_for_unit(f"overalls-request-{instance}.service")
        machine.wait_until_succeeds(
            "jq -e '.coverage_started_at_unix_nano > " + str(recorded.coverage) + "' " + publication
        )
        recovered = transport_fresh_after(machine, source, recorded)
        assert recovered.completed() == recorded.completed(), (recorded, recovered)
        assert (
            int(machine.succeed(f"systemctl show {unit} -p MainPID --value").strip()) == producer
        ), (
            "producer changed during recorder-only fault",
            source,
        )
        transport_probe_after(machine, source, recovered, probe)

    with subtest(f"{source}: clean restart preserves completed history and coverage"):
        recorded = transport_history(machine, source)
        machine.succeed(f"systemctl restart {unit}")
        machine.wait_for_unit(unit)
        ready()
        recovered = transport_fresh_after(machine, source, recorded)
        assert recovered.completed() == recorded.completed()
        assert recovered.coverage == recorded.coverage
        after = transport_probe_after(machine, source, recovered, probe)
        assert after.coverage == recovered.coverage

    with subtest(f"{source}: idle producer loss advances coverage and restores requests"):
        recorded = transport_history(machine, source)
        machine.succeed(f"systemctl kill --signal=SIGKILL --kill-whom=all {unit}")
        machine.wait_for_unit(unit)
        ready()
        machine.wait_until_succeeds(
            "jq -e '.coverage_started_at_unix_nano > " + str(recorded.coverage) + "' " + publication
        )
        recovered = transport_fresh_after(machine, source, recorded)
        assert recovered.completed() == recorded.completed()
        transport_probe_after(machine, source, recovered, probe)


def transport_inflight_fault(
    machine: MachineLike,
    source: RequestSource,
    ready: Callable[[], None],
    start_request: Callable[[], None],
    disconnected: Callable[[], None],
    probe: Callable[[], None],
) -> None:
    """@cc [owner:ghuntley,label:verification] transport-admitted-producer-loss
    Killing a real producer with exactly one admitted request MUST settle one
    failure without inventing its duration or resetting completed history.
    The independent recorder MUST survive; recovery MUST admit a fresh request.
    """
    instance, unit = transport_binding(source)
    checkpoint = f"/var/lib/overalls-request-{instance}/state.json"
    publication = f"/run/overalls-request-{instance}-source/slo.json"
    with subtest(f"{source}: admitted producer loss settles one unknown-duration failure"):
        recorded = transport_history(machine, source)
        recorder = int(
            machine.succeed(
                f"systemctl show overalls-request-{instance}.service -p MainPID --value"
            ).strip()
        )
        assert recorder > 0
        start_request()
        machine.succeed(
            "timeout 10 bash -c "
            + shlex.quote(
                f"until jq -e '(.pending | length) == 1' {checkpoint} >/dev/null; "
                "do sleep 0.01; done; "
                f"systemctl kill --signal=SIGKILL --kill-whom=all {unit}"
            )
        )
        disconnected()
        machine.wait_for_unit(unit)
        ready()
        machine.wait_until_succeeds(
            "jq -e '.requests == "
            + str(recorded.requests + 1)
            + " and .failures == "
            + str(recorded.failures + 1)
            + " and .coverage_started_at_unix_nano > "
            + str(recorded.coverage)
            + "' "
            + publication
        )
        recovered = transport_history(machine, source)
        assert recovered.incarnation == recorded.incarnation
        assert recovered.started == recorded.started
        assert recovered.successes == recorded.successes
        assert recovered.durations == recorded.durations
        assert recovered.buckets == recorded.buckets
        assert (
            int(
                machine.succeed(
                    f"systemctl show overalls-request-{instance}.service -p MainPID --value"
                ).strip()
            )
            == recorder
        )
        transport_probe_after(machine, source, recovered, probe)
