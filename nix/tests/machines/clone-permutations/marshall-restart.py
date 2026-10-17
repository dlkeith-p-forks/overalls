"""Real control-plane restart mid-copy and one-slot-per-host arbitration."""


# @cc [owner:ghuntley,label:verification;recovery] clone-marshall-restart-mid-copy
# Restarting every Marshall replica after the physical receive has begun MUST
# NOT fabricate, duplicate or lose clone progress: the same durable request
# completes exactly one independent copy whose guest carries the pre-clone
# marker; source and copy datasets keep empty origins and distinct GUIDs.


# @cc [owner:ghuntley,label:verification;capacity] clone-transfer-slot-arbitration
# Two running sources on different hosts cloning concurrently MUST let exactly
# one activation own both hosts' transfer slots; the loser fails with a durable,
# retryable admission refusal and MAY complete only through an explicit retry
# after the winning request releases its physical commitments.


def clone_placement_of(vm_id: str) -> dict[str, str]:
    assert str(uuid.UUID(vm_id)) == vm_id
    value: object = sql_json(
        "SELECT json_build_object('vm_id',v.id,'placement_id',p.id,'host_id',p.host_id) "
        "FROM compute_virtual_machines v JOIN compute_workload_placements p "
        f"ON p.id=v.current_placement_id WHERE v.id='{vm_id}'"
    )
    assert isinstance(value, dict)
    fields: dict[str, object] = {key: item for key, item in value.items() if isinstance(key, str)}
    placement_id = fields.get("placement_id")
    host_id = fields.get("host_id")
    assert isinstance(placement_id, str) and isinstance(host_id, str)
    assert str(uuid.UUID(placement_id)) == placement_id
    assert str(uuid.UUID(host_id)) == host_id
    return {"host_id": host_id, "placement_id": placement_id}


def clone_server_for(destination: dict[str, str]) -> MachineLike:
    return next(
        machine
        for machine in provisioners
        if host_bindings[machine.name]["host"] == destination["host_id"]
    )


# @cc [owner:ghuntley,label:verification;capacity] clone-marshall-restart-cross-host-shape
# Clone placement is first-fit by host id and same-host copies are admissible,
# so a cross-host copy MUST follow from real admission arithmetic, not from
# incidental CPU noise. Fleet hosts enroll 6 cores with 1 overhead core; a
# running source's restart hold plus a same-host copy of three vCPUs needs 6 of
# the 5 schedulable cores, while one three-vCPU copy fits an otherwise idle peer.
CLONE_SOURCE_VCPU = 3


def provision_guest(memory_profile: str) -> str:
    request = dict(
        action="provision",
        owner_id=users["owner_id"],
        image_id=users["image_id"],
        profile=memory_profile,
        vcpu=CLONE_SOURCE_VCPU,
        key=str(uuid.uuid4()),
    )
    placed: dict[str, object] = {}

    def ready() -> bool:
        result = operator(m1, dict(request))
        reason = result.get("reason")
        assert reason in (None, "insufficient_capacity"), result
        placed.update(result)
        return bool(result.get("accepted"))

    eventually(ready, timeout=180)
    guest = str(placed["vm_id"])
    assert str(uuid.UUID(guest)) == guest
    await_running(guest)
    return guest


def submit_clone(vm_id: str) -> tuple[str, str]:
    admission: object = operator(
        m1,
        dict(action="clone", owner_id=users["owner_id"], vm_id=vm_id, key=str(uuid.uuid4())),
    )
    assert isinstance(admission, dict)
    request_id = str(admission["id"])
    destination = str(admission["destination_vm_id"])
    assert str(uuid.UUID(request_id)) == request_id
    assert str(uuid.UUID(destination)) == destination
    return request_id, destination


def clone_phase(request_id: str) -> str:
    assert str(uuid.UUID(request_id)) == request_id
    return sql(f"SELECT phase FROM compute_clone_requests WHERE id='{request_id}'")


def clone_completed(request_id: str) -> bool:
    return clone_phase(request_id) == "complete"


def receive_begun(destination: str) -> bool:
    placed = clone_placement_of(destination)
    status, _ = clone_server_for(placed).execute(
        "zfs list zroot/lilly/vm-" + placed["placement_id"]
    )
    return status == 0


def archived(vm_id: str) -> bool:
    return (
        sql(f"SELECT archived_at IS NOT NULL FROM compute_virtual_machines WHERE id='{vm_id}'")
        == "t"
    )


def delete_guest(vm_id: str) -> None:
    lifecycle(vm_id, "delete")
    eventually(lambda: archived(vm_id), timeout=600)


def verify_copy(source_vm: str, copy_vm: str) -> None:
    """@cc [owner:ghuntley,label:verification] clone-copy-guest-evidence
    Every completed copy MUST boot with the source's pre-clone marker present,
    carry empty origins and distinct GUIDs on both hosts, and keep post-copy
    divergent writes invisible from the peer guest's own console.
    """
    source = clone_placement_of(source_vm)
    copy = clone_placement_of(copy_vm)
    source_server = clone_server_for(source)
    copy_server = clone_server_for(copy)
    source_child = "zroot/lilly/vm-" + source["placement_id"]
    copy_child = "zroot/lilly/vm-" + copy["placement_id"]
    assert vm_state(copy_vm) == "running"
    copy_server.wait_until_succeeds(
        "fleet-relocation-guest clone-inherit "
        + copy["placement_id"]
        + " "
        + source["placement_id"],
        timeout=240,
    )
    assert source_server.succeed(f"zfs get -Hp -o value origin {source_child}").strip() == "-"
    assert copy_server.succeed(f"zfs get -Hp -o value origin {copy_child}").strip() == "-"
    assert (
        source_server.succeed(f"zfs get -Hp -o value guid {source_child}").strip()
        != copy_server.succeed(f"zfs get -Hp -o value guid {copy_child}").strip()
    )
    source_server.succeed(
        "fleet-relocation-guest clone-write-post " + source["placement_id"], timeout=120
    )
    copy_server.succeed(
        "fleet-relocation-guest clone-write-post " + copy["placement_id"], timeout=120
    )
    source_server.succeed(
        "fleet-relocation-guest clone-check " + source["placement_id"] + " " + copy["placement_id"],
        timeout=120,
    )
    copy_server.succeed(
        "fleet-relocation-guest clone-check " + copy["placement_id"] + " " + source["placement_id"],
        timeout=120,
    )
    copy_server.fail("zfs list " + source_child)
    source_server.fail("zfs list " + copy_child)


with subtest("Marshall restart mid-copy resumes the admitted request exactly once"):
    origin_vm = provision_guest("standard")
    origin = clone_placement_of(origin_vm)
    origin_server = clone_server_for(origin)
    # The marker enters the real guest and syncs to its disk before the copy.
    origin_server.succeed(
        "fleet-relocation-guest clone-write " + origin["placement_id"], timeout=180
    )
    first_request, first_copy = submit_clone(origin_vm)

    def copying_with_effects() -> bool:
        return clone_phase(first_request) in ("copying", "publishing") and receive_begun(first_copy)

    eventually(copying_with_effects, timeout=600)
    first_placement = clone_placement_of(first_copy)
    assert first_placement["host_id"] != clone_placement_of(origin_vm)["host_id"]
    first_child = "zroot/lilly/vm-" + first_placement["placement_id"]
    # The receive is physically live when the control plane disappears.
    first_server = clone_server_for(first_placement)
    assert (
        first_server.succeed(f"zfs get -Hp -o value guid {first_child}").strip()
        != origin_server.succeed(
            f"zfs get -Hp -o value guid zroot/lilly/vm-{origin['placement_id']}"
        ).strip()
    )
    for machine in marshalls:
        machine.succeed(f"systemctl restart marshall-{machine.name}.service")
    for machine in marshalls:
        machine.wait_for_unit(f"marshall-{machine.name}.service")
        machine.wait_until_succeeds(
            f"curl --fail --silent --cacert {root}/ca.crt https://{machine.name}:4443/health/ready",
            timeout=120,
        )
    eventually(lambda: clone_completed(first_request), timeout=600)
    row = sql_json(
        "SELECT jsonb_build_object('active',active,'finished',finished_at IS NOT NULL,"
        "'published',published_at IS NOT NULL,"
        "'captures',(SELECT count(*) FROM compute_clone_effects e "
        "WHERE e.clone_request_id=r.id AND e.kind='capture'),"
        "'slots_held',(SELECT count(*) FROM compute_transfer_slots s "
        "WHERE s.clone_request_id=r.id AND s.released_at IS NULL)) "
        f"FROM compute_clone_requests r WHERE r.id='{first_request}'"
    )
    assert row == {
        "active": False,
        "captures": 1,
        "finished": True,
        "published": True,
        "slots_held": 0,
    }
    verify_copy(origin_vm, first_copy)
    lifecycle(origin_vm, "stop")
    eventually(lambda: vm_state(origin_vm) == "stopped", timeout=120)
    lifecycle(first_copy, "stop")
    eventually(lambda: vm_state(first_copy) == "stopped", timeout=120)
    delete_guest(first_copy)
    delete_guest(origin_vm)

with subtest("one transfer slot per host arbitrates two-source simultaneous copies"):
    source_b = provision_guest("standard")
    source_b_placement = clone_placement_of(source_b)
    other_binding = next(
        binding
        for machine, binding in host_bindings.items()
        if binding["host"] != source_b_placement["host_id"]
    )
    # Force the second source onto the other provisioner with a real host
    # enable/disable edge, then restore it before any clone admission.
    operator(m1, dict(action="enable", host_id=source_b_placement["host_id"], enabled=False))
    source_c = provision_guest("standard")
    operator(m1, dict(action="enable", host_id=source_b_placement["host_id"], enabled=True))
    source_c_placement = clone_placement_of(source_c)
    assert source_c_placement["host_id"] != source_b_placement["host_id"]
    clone_server_for(source_b_placement).succeed(
        "fleet-relocation-guest clone-write " + source_b_placement["placement_id"], timeout=180
    )
    clone_server_for(source_c_placement).succeed(
        "fleet-relocation-guest clone-write " + source_c_placement["placement_id"], timeout=180
    )
    winner_request, winner_copy = submit_clone(source_b)

    def winner_active() -> bool:
        return (
            sql("SELECT active FROM compute_clone_requests WHERE id=" + f"'{winner_request}'")
            == "t"
        )

    eventually(winner_active, timeout=300)
    loser_request, loser_copy = submit_clone(source_c)

    def loser_failed() -> bool:
        row = sql_json(
            "SELECT jsonb_build_object('phase',phase,'failure',failure,'active',active) "
            f"FROM compute_clone_requests WHERE id='{loser_request}'"
        )
        assert isinstance(row, dict)
        if row["phase"] == "failed":
            assert row["active"] is False
            assert row["failure"] in ("source_unavailable", "insufficient_capacity")
            return True
        return False

    eventually(loser_failed, timeout=300)
    assert sql(f"SELECT count(*) FROM compute_virtual_machines WHERE id='{loser_copy}'") == "0"
    eventually(lambda: clone_completed(winner_request), timeout=900)
    # The failed loser never reserved identity resources beyond its queue row.
    assert (
        sql(f"SELECT count(*) FROM compute_clone_effects WHERE clone_request_id='{loser_request}'")
        == "0"
    )
    requeued = operator(
        m1,
        dict(action="retry-clone", owner_id=users["owner_id"], request_id=loser_request),
    )
    assert isinstance(requeued, dict)
    assert str(requeued["id"]) == loser_request
    eventually(lambda: clone_completed(loser_request), timeout=900)
    # Exactly one clone per request, and every released slot is accounted.
    assert (
        sql(
            "SELECT count(*) FROM compute_transfer_slots "
            "WHERE clone_request_id IN "
            f"('{winner_request}','{loser_request}') AND released_at IS NULL"
        )
        == "0"
    )
    winner_row = sql_json(
        f"SELECT jsonb_build_object('snapshot',snapshot IS NOT NULL,'copy',destination_vm_id) "
        f"FROM compute_clone_requests WHERE id='{winner_request}'"
    )
    loser_row = sql_json(
        f"SELECT jsonb_build_object('snapshot',snapshot IS NOT NULL,'copy',destination_vm_id) "
        f"FROM compute_clone_requests WHERE id='{loser_request}'"
    )
    assert winner_row["snapshot"] is True and loser_row["snapshot"] is True
    assert str(winner_row["copy"]) == winner_copy
    assert str(loser_row["copy"]) == loser_copy
    verify_copy(source_b, winner_copy)
    verify_copy(source_c, loser_copy)
    winner_row_snapshot = sql_json(
        f"SELECT snapshot FROM compute_clone_requests WHERE id='{winner_request}'"
    )
    loser_row_snapshot = sql_json(
        f"SELECT snapshot FROM compute_clone_requests WHERE id='{loser_request}'"
    )
    assert winner_row_snapshot != loser_row_snapshot
    lifecycle(source_b, "stop")
    eventually(lambda: vm_state(source_b) == "stopped", timeout=120)
    lifecycle(source_c, "stop")
    eventually(lambda: vm_state(source_c) == "stopped", timeout=120)
    lifecycle(winner_copy, "stop")
    eventually(lambda: vm_state(winner_copy) == "stopped", timeout=120)
    lifecycle(loser_copy, "stop")
    eventually(lambda: vm_state(loser_copy) == "stopped", timeout=120)
    delete_guest(winner_copy)
    delete_guest(loser_copy)
    delete_guest(source_b)
    delete_guest(source_c)
