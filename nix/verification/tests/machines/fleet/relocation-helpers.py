# @cc [owner:ghuntley,label:verification] fleet-relocation-real-control-and-stopped-copy
# Relocation MUST use public Marshall admission and both real Lilly services.
# The before-stop marker MUST be written while the source still runs, before
# connectivity proof lets Marshall stop it for the single full copy (ADR-0155).
# Both markers MUST survive destination boot and return to
# the former host under a new placement. Initially stopped guests MUST retain
# stopped intent and an empty destination execution cgroup until explicit Start.
# Cancellation MUST restore verified source data under a fresh epoch while the
# destination daemon is stopped, retaining its disk hold until confirmed cleanup.
# SQL may observe but MUST NOT fabricate
# relocation progress, receipts, reservations or execution authority.
from typing import TypedDict


class PlacementCopy(PlacementRef, TypedDict):
    vm_id: str
    epoch: int
    slot: int


class RelocationMove(TypedDict):
    id: str
    vm_id: str
    source_host_id: str
    source_placement_id: str
    destination_host_id: str
    destination_placement_id: str
    destination_epoch: int


class PhaseReport(TypedDict):
    phase: str
    desired: str
    observed: str
    reason: object
    generation: int
    committed: bool
    finished: bool
    cancelled: bool
    stop_requested: bool
    source_revoked: bool
    destination_revoked: bool
    permit_revision: object
    permit_status: object
    descriptor: bool
    received: bool
    import_requested: bool
    imported: bool
    readiness: object
    readiness_failure: object
    cleanup_complete: object


def current_copy(vm: str) -> PlacementCopy:
    assert str(uuid.UUID(vm)) == vm
    placement = sql_json(
        "SELECT json_build_object('vm_id',v.id,'placement_id',p.id,"
        "'host_id',p.host_id,'epoch',v.execution_epoch,'slot',a.slot) "
        "FROM compute_virtual_machines v JOIN compute_workload_placements p "
        "ON p.id=v.current_placement_id JOIN compute_network_addresses a ON a.vm_id=v.id "
        f"WHERE v.id='{vm}' AND a.archived_at IS NULL"
    )
    assert isinstance(placement, dict)
    epoch = placement["epoch"]
    slot = placement["slot"]
    assert isinstance(epoch, int) and isinstance(slot, int)
    return PlacementCopy(
        vm_id=str(placement["vm_id"]),
        placement_id=str(placement["placement_id"]),
        host_id=str(placement["host_id"]),
        epoch=epoch,
        slot=slot,
    )


def guest_assertion(copy: PlacementRef, action: str) -> None:
    # A restored VMM can report Running before Lilly has recreated the
    # guest-vsock listener. Keep the user-visible assertion pending through
    # that narrow handoff window instead of treating a transient connect
    # refusal as a failed memory oracle.
    host_for(copy).wait_until_succeeds(
        "fleet-relocation-guest " + shlex.quote(action) + " " + shlex.quote(copy["placement_id"]),
        timeout=240,
    )


def relocate(vm: str) -> RelocationMove:
    """@cc [owner:ghuntley,label:verification] relocation-admission-bounded-retry
    Setup may retry only explicit physical-capacity or source-freshness refusals
    for at most 180 seconds with the same request key. Other refusals MUST fail;
    no retry may fabricate freshness or alter production admission policy.
    """
    request = dict(action="relocate", owner_id=users["owner_id"], vm_id=vm, key=str(uuid.uuid4()))
    accepted = []

    def attempt() -> bool:
        if not fresh_hosts():
            return False
        result = operator(m2, request)
        if result["accepted"]:
            accepted.append(result)
            return True
        assert result["reason"] in ["insufficient_capacity", "source_unavailable"], result
        print("relocation_admission_refused: " + str(result["reason"]), flush=True)
        return False

    eventually(attempt, timeout=180)
    result = accepted[0]
    assert isinstance(result, dict)
    destination_epoch = result["destination_epoch"]
    assert isinstance(destination_epoch, int)
    return RelocationMove(
        id=str(uuid.UUID(str(result["id"]))),
        vm_id=str(uuid.UUID(str(result["vm_id"]))),
        source_host_id=str(uuid.UUID(str(result["source_host_id"]))),
        source_placement_id=str(uuid.UUID(str(result["source_placement_id"]))),
        destination_host_id=str(uuid.UUID(str(result["destination_host_id"]))),
        destination_placement_id=str(uuid.UUID(str(result["destination_placement_id"]))),
        destination_epoch=destination_epoch,
    )


# @cc [owner:ghuntley,label:verification;security] relocation-wait-bounded-phase-diagnostics
# A stalled relocation MUST expose only whitelisted control phase enums, revisions,
# completion booleans. Diagnostics MUST NOT include descriptors, credentials,
# keys, guest console bytes or job arguments. Observations MUST NOT mutate authority
# or substitute for the existing completion and physical cleanup assertions.
def relocation_phase(identifier: str) -> PhaseReport:
    return sql_json(
        "SELECT json_build_object("
        "'phase',r.phase,'desired',v.desired_state,'observed',v.observed_state,"
        "'reason',v.failure_reason,"
        "'generation',v.generation,'committed',r.committed_at IS NOT NULL,"
        "'finished',r.finished_at IS NOT NULL,'cancelled',r.cancellation_requested_at IS NOT NULL,"
        "'stop_requested',r.source_stop_operation_id IS NOT NULL,"
        "'source_revoked',r.source_revoked_at IS NOT NULL,"
        "'destination_revoked',r.destination_revoked_at IS NOT NULL,"
        "'permit_revision',p.revision,'permit_status',p.status,"
        "'descriptor',p.descriptor IS NOT NULL,'received',p.destination_dataset_guid IS NOT NULL,"
        "'import_requested',p.import_requested_at IS NOT NULL,"
        "'imported',p.destination_imported_at IS NOT NULL,"
        "'readiness',(SELECT status FROM compute_readiness_requests WHERE relocation_id=r.id ORDER BY inserted_at DESC LIMIT 1),"
        "'readiness_failure',(SELECT failure_reason FROM compute_readiness_requests "
        "WHERE relocation_id=r.id ORDER BY inserted_at DESC LIMIT 1),"
        "'cleanup_complete',(SELECT completed_at IS NOT NULL FROM compute_cleanup_requests "
        "WHERE id=r.id)) "
        "FROM compute_relocations r JOIN compute_virtual_machines v ON v.id=r.vm_id "
        "LEFT JOIN LATERAL (SELECT revision,status,descriptor,destination_dataset_guid,"
        "import_requested_at,destination_imported_at FROM compute_source_permit_requests "
        "WHERE relocation_id=r.id ORDER BY revision DESC LIMIT 1) p ON true "
        f"WHERE r.id='{identifier}'"
    )


def await_relocation(
    move: RelocationMove,
    expected_state: str = "running",
    abort_on_readiness_failure: bool = False,
) -> PlacementCopy:
    """@cc [owner:ghuntley,label:verification] relocation-wait-bounds-real-stages
    Native completion MUST retain a total deadline and a per-stage deadline.
    Lease revisions and byte counters MUST NOT reset either deadline. Only actual
    control milestones may start the next stage's wait; completion still requires
    handoff, readiness and verified physical cleanup.
    """
    identifier = str(uuid.UUID(move["id"]))
    previous = None
    next_observation = 0.0
    stage = None
    stage_started = time.monotonic()

    def complete() -> bool:
        nonlocal previous, next_observation, stage, stage_started
        now = time.monotonic()
        if now < next_observation:
            return False
        next_observation = now + 10
        phase = relocation_phase(identifier)
        current_stage = (
            "cleanup"
            if phase["committed"]
            else "import"
            if phase["import_requested"]
            else "copy"
            if phase["stop_requested"]
            else "probe"
        )
        if current_stage != stage:
            stage, stage_started = current_stage, now
        assert now - stage_started < 900, "Relocation stage timed out: " + stage
        if phase != previous:
            print("relocation_phase: " + json.dumps(phase, sort_keys=True), flush=True)
            previous = phase
        if abort_on_readiness_failure:
            assert phase["readiness"] != "failed", "Relocation guest readiness failed"
        return phase["finished"] and phase["committed"]

    try:
        eventually(complete, timeout=1800)
    except AssertionError:
        for side, copy in (
            (
                "source",
                PlacementRef(
                    host_id=move["source_host_id"], placement_id=move["source_placement_id"]
                ),
            ),
            (
                "destination",
                PlacementRef(
                    host_id=move["destination_host_id"],
                    placement_id=move["destination_placement_id"],
                ),
            ),
        ):
            observation = host_for(copy).succeed(
                "fleet-relocation-diagnostics " + shlex.quote(copy["placement_id"]), timeout=30
            )
            print("relocation_local_" + side + ": " + observation, flush=True)
        raise
    if expected_state == "running":
        await_running(move["vm_id"])
    else:
        assert vm_state(move["vm_id"]) == expected_state
    current = current_copy(move["vm_id"])
    assert current["placement_id"] == move["destination_placement_id"]
    assert current["epoch"] == move["destination_epoch"]
    old = PlacementRef(
        host_id=move["source_host_id"],
        placement_id=move["source_placement_id"],
    )
    host_for(old).fail(
        "zfs list zroot/lilly/vm-" + old["placement_id"],
        "systemctl is-active lilly-vm-" + old["placement_id"] + ".service",
    )
    assert (
        sql(
            f"SELECT count(*) FROM compute_reservations WHERE vm_id='{move['vm_id']}' AND disk_held"
        )
        == "1"
    )
    return current
