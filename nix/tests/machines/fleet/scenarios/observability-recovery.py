"""Native physical receipts and guest survival while independent telemetry is down."""

from typing import TypedDict


class ObserverRecoveryDiagnostics(TypedDict):
    counters: dict[str, int]
    socket_metadata: list[tuple[int, int, int]]
    collector_active: bool
    spool_active: bool


def observer_recovery_diagnostics(machine: MachineLike) -> None:
    """@cc [owner:ghuntley,label:verification;security] observer-failure-finite-diagnostics
    Recovery failure output MUST contain only reviewed numeric counters,
    socket modes/ownership and service availability. Raw trace bodies, journal
    contents, credentials and unvalidated command output MUST NOT be printed.
    Diagnostic reads MUST remain bounded and MUST NOT change observer state.
    Failure to read diagnostics MUST preserve the original recovery assertion.
    """
    report: ObserverRecoveryDiagnostics = {
        "counters": {},
        "socket_metadata": [],
        "collector_active": False,
        "spool_active": False,
    }
    accepted = {
        "accepted_total",
        "refused_total",
        "storage_failures_total",
        "export_failed_total",
        "exported_total",
        "pending_batches",
        "pending_bytes",
        "oldest_pending_seconds",
        "retained_batches",
        "poisoned",
    }
    status, metrics = machine.execute(
        "cat /run/overalls-trace-lilly-source/metrics.prom",
        timeout=5,
    )
    if status == 0:
        for line in metrics.splitlines():
            fields = line.split()
            if len(fields) != 2 or not fields[0].startswith("overalls_trace_spool_"):
                continue
            name = fields[0].removeprefix("overalls_trace_spool_")
            value = fields[1]
            if name in accepted and value.isascii() and value.isdecimal():
                number = int(value)
                if 0 <= number <= 18_446_744_073_709_551_615:
                    report["counters"][name] = number
    status, metadata = machine.execute(
        "stat -c '%a:%u:%g' /run/overalls-otel-traces /run/overalls-otel-traces/collector.sock",
        timeout=5,
    )
    if status == 0:
        for line in metadata.splitlines()[:2]:
            fields = line.split(":")
            if len(fields) != 3 or not all(
                field.isascii() and field.isdecimal() for field in fields
            ):
                continue
            if any(digit not in "01234567" for digit in fields[0]):
                continue
            mode, user, group = int(fields[0], 8), int(fields[1]), int(fields[2])
            if 0 <= mode <= 0o7777 and 0 <= user <= 4_294_967_295 and 0 <= group <= 4_294_967_295:
                report["socket_metadata"].append((mode, user, group))
    for field, unit in [
        ("collector_active", "opentelemetry-collector.service"),
        ("spool_active", "overalls-trace-lilly.service"),
    ]:
        status, _ = machine.execute(
            "systemctl is-active --quiet " + unit,
            timeout=5,
        )
        if field == "collector_active":
            report["collector_active"] = status == 0
        else:
            report["spool_active"] = status == 0
    print("Observer recovery diagnostics: " + json.dumps(report), flush=True)


def ready_receipt(vm: ProfiledPlacement) -> str:
    """Read an exact current-generation physical readiness receipt, without mutation."""
    vm_id = vm["vm_id"]
    return sql(
        "SELECT p.id::text || ':' || p.sequence::text FROM compute_physical_outcomes p "
        "JOIN compute_virtual_machines v ON p.vm_id=v.id "
        "JOIN compute_operations o ON o.id=p.operation_id "
        f"WHERE v.id='{vm_id}' AND p.placement_id=v.current_placement_id "
        "AND p.execution_epoch=v.execution_epoch AND p.generation=v.generation "
        "AND o.kind IN ('provision','start') AND o.status='completed' "
        "AND p.observation->>'state'='running' AND p.observation->>'guest_ready'='true' "
        "ORDER BY p.sequence LIMIT 1"
    )


def spool_counts(machine: MachineLike) -> tuple[int, int]:
    """Bounded read-only counts; diagnostic bytes never enter the driver output."""
    result = machine.succeed(
        "sqlite3 -readonly /var/lib/overalls-trace-lilly/archive.sqlite "
        + shlex.quote("SELECT (SELECT count(*) FROM batches),(SELECT count(*) FROM pending);")
    ).strip()
    fields = result.split("|")
    assert len(fields) == 2 and all(field.isdecimal() for field in fields)
    retained, pending = (int(field) for field in fields)
    assert 0 <= pending <= retained
    return retained, pending


def await_native_transition_trace(vm: ProfiledPlacement) -> None:
    """@cc [owner:ghuntley,label:verification;observability] native-transition-tempo-correlation
    Tempo MUST return a real committed running Execution transition matching
    the exact native journal resource/revision and enrolled host/placement.
    Producer or collector acceptance alone MUST NOT establish sink delivery.
    """
    placement = str(uuid.UUID(vm["placement_id"]))
    host = str(uuid.UUID(vm["host_id"]))
    identity = (
        host_for(vm)
        .succeed(
            'jq -er \'._lifecycle | select(.version==2 and .resource=="Execution" '
            'and .state=="running") | .id + "|" + (.revision|tostring)\' '
            + shlex.quote(f"/var/lib/lilly/control/actors/{placement}/journal.json")
        )
        .strip()
    )
    fields = identity.split("|")
    assert len(fields) == 2 and fields[1].isascii() and fields[1].isdecimal()
    resource = str(uuid.UUID(fields[0]))
    revision = int(fields[1])
    assert 0 < revision <= 9_223_372_036_854_775_807
    query = (
        '{ resource.service.name = "lilly" && resource.host.name = "l2" '
        '&& name = "lilly.lifecycle_transition_committed" '
        '&& span.resource_type = "execution" && span.next_state = "running" '
        f'&& span.host_id = "{host}" && span.placement_id = "{placement}" '
        f'&& span.resource_id = "{resource}" && span.revision = {revision} }}'
    )
    l1.wait_until_succeeds(
        "curl --max-time 5 -fsSG --data-urlencode "
        + shlex.quote("q=" + query)
        + " --data-urlencode 'limit=5' http://127.0.0.1:3200/api/search "
        "| jq -e '.traces | length > 0'",
        timeout=180,
    )


# @cc [owner:ghuntley,label:verification;recovery;observability] native-observability-authority-independent
# Actual configured collector and spool failures MUST leave native VMM identity
# unchanged across Lilly restarts. New public stop/start authority MUST settle
# with exact physical readiness while both diagnostics services are unavailable.
# Reopening MUST preserve physical receipt identity, and recovered independent
# custody MUST retain old archives and drain its pending collector work.
with subtest("collector and spool outages cannot gate native control or physical readiness"):
    victim = next(vm for vm in vms if host_for(vm) is l2)
    survivor = next(vm for vm in vms if host_for(vm) is l1)
    original = process_snapshot(victim)
    untouched = process_snapshot(survivor)
    original_receipt = ready_receipt(victim)
    assert original and untouched and original_receipt
    retained_before, _ = spool_counts(l2)

    try:
        l2.succeed("systemctl stop opentelemetry-collector.service")
        l2.fail("systemctl is-active opentelemetry-collector.service")
        l2.wait_for_unit("overalls-trace-lilly.service")
        l2.succeed("systemctl restart lilly.service")
        l2.wait_until_succeeds("fleet-readiness true", timeout=120)
        assert process_snapshot(victim) == original
        assert ready_receipt(victim) == original_receipt
        eventually(lambda: spool_counts(l2)[1] > 0, timeout=30)

        l2.succeed("systemctl stop overalls-trace-lilly.service")
        l2.fail("systemctl is-active overalls-trace-lilly.service")
        for _ in range(2):
            l2.succeed("systemctl restart lilly.service")
            l2.wait_until_succeeds("fleet-readiness true", timeout=120)
            assert process_snapshot(victim) == original
            assert process_snapshot(survivor) == untouched
            assert ready_receipt(victim) == original_receipt

        lifecycle(victim["vm_id"], "stop")
        eventually(lambda: vm_state(victim["vm_id"]) == "stopped")
        lifecycle(victim["vm_id"], "start")
        await_running(victim["vm_id"])
        eventually(lambda: ready_receipt(victim), timeout=180)
        new_receipt = ready_receipt(victim)
        assert new_receipt != original_receipt
        restarted = process_snapshot(victim)
        assert restarted and restarted != original
        assert process_snapshot(survivor) == untouched
        eventually(lambda: durable_service_level_snapshot(m1, victim["vm_id"]))

        l2.succeed("systemctl restart lilly.service")
        l2.wait_until_succeeds("fleet-readiness true", timeout=120)
        assert process_snapshot(victim) == restarted
        assert ready_receipt(victim) == new_receipt
        assert process_snapshot(survivor) == untouched
    finally:
        l2.succeed("systemctl start opentelemetry-collector.service overalls-trace-lilly.service")
        l2.wait_for_unit("opentelemetry-collector.service")
        l2.wait_for_unit("overalls-trace-lilly.service")

    try:
        eventually(lambda: spool_counts(l2)[1] == 0, timeout=180)
    except AssertionError:
        try:
            observer_recovery_diagnostics(l2)
        except Exception:
            print("Observer recovery diagnostics unavailable", flush=True)
        raise
    retained_after, _ = spool_counts(l2)
    assert retained_after >= retained_before
    assert process_snapshot(victim) == restarted
    assert ready_receipt(victim) == new_receipt
    assert process_snapshot(survivor) == untouched

    # Events produced while the spool was stopped may drop. After recovery,
    # create a new ordinary transition and establish actual central Tempo custody.
    lifecycle(victim["vm_id"], "stop")
    eventually(lambda: vm_state(victim["vm_id"]) == "stopped")
    lifecycle(victim["vm_id"], "start")
    await_running(victim["vm_id"])
    eventually(lambda: ready_receipt(victim), timeout=180)
    assert ready_receipt(victim) != new_receipt
    assert process_snapshot(victim) and process_snapshot(victim) != restarted
    await_native_transition_trace(victim)
    assert process_snapshot(survivor) == untouched
