# Faults below affect transport, service lifetime and physical storage only.
# SQL observes real effects; public actions retain sole authority over intent.
from typing import Protocol


class RelocationMachineLike(MachineLike, Protocol):
    pass


relocation_paths = {
    "keys",
    "source",
    "receive",
    "import",
    "readiness",
    "cleanup",
    "destination_cleanup",
    "snapshot_cleanup",
    "key_retirement",
}
relocation_blocked: set[str] = set()


def relocation_gate(kind: str, blocked: bool) -> None:
    """@cc [owner:ghuntley,label:verification;security] relocation-faults-preserve-real-authority
    Gates MUST only refuse a closed set of real control ops, through Marshall's
    test-only fault gate on every replica. They MUST NOT manufacture receipts,
    mutate database state, advance epochs or release holds.
    """
    assert kind in relocation_paths
    if (kind in relocation_blocked) == blocked:
        return
    if blocked:
        relocation_blocked.add(kind)
    else:
        relocation_blocked.remove(kind)
    ops = "".join("lilly.relocation_" + name + "\n" for name in sorted(relocation_blocked))
    for machine in marshalls:
        machine.succeed(
            "printf %s "
            + shlex.quote(ops)
            + " > /run/marshall-fault-gate/ops.next && "
            + "mv /run/marshall-fault-gate/ops.next /run/marshall-fault-gate/ops"
        )


def relocation_row(move: RelocationMove, expression: str) -> str:
    identifier = str(uuid.UUID(move["id"]))
    return sql(f"SELECT {expression} FROM compute_relocations WHERE id='{identifier}'")


def seed_relocation_guest() -> tuple[str, PlacementCopy]:
    admitted = provision_when_available(m1, "customer")
    identifier = str(admitted["vm_id"])
    await_running(identifier)
    copy = current_copy(identifier)
    guest_assertion(copy, "prepare")
    guest_assertion(copy, "before-stop")
    return identifier, copy


def assert_retained(move: RelocationMove) -> None:
    assert (
        sql(
            f"SELECT count(*) FROM compute_reservations WHERE vm_id='{move['vm_id']}' AND disk_held"
        )
        == "2"
    )
    assert relocation_row(move, "finished_at IS NULL") == "t"
    assert (
        sql(f"SELECT archived_at IS NULL FROM compute_virtual_machines WHERE id='{move['vm_id']}'")
        == "t"
    )
    assert (
        sql(
            "SELECT count(*) FROM compute_network_addresses "
            f"WHERE vm_id='{move['vm_id']}' AND archived_at IS NULL"
        )
        == "1"
    )


def delete_all_copies(identifier: str, copies: list[PlacementRef]) -> None:
    lifecycle(identifier, "delete")
    eventually(
        lambda: (
            sql(
                "SELECT archived_at IS NOT NULL FROM compute_virtual_machines "
                f"WHERE id='{identifier}'"
            )
            == "t"
        ),
        timeout=600,
    )
    assert (
        sql(
            "SELECT count(*) FROM compute_reservations "
            f"WHERE vm_id='{identifier}' AND (disk_held OR compute_held OR temporary_disk_bytes > 0)"
        )
        == "0"
    )
    for copy in copies:
        host_for(copy).fail(
            "zfs list zroot/lilly/vm-" + copy["placement_id"],
            "systemctl is-active lilly-vm-" + copy["placement_id"] + ".service",
        )


def move_target(move: RelocationMove) -> PlacementRef:
    return PlacementRef(
        host_id=move["destination_host_id"],
        placement_id=move["destination_placement_id"],
    )


def restart_endpoint(machine: RelocationMachineLike) -> None:
    previous = machine.succeed("systemctl show -p MainPID --value lilly.service").strip()
    machine.succeed("systemctl restart lilly.service", timeout=120)
    machine.wait_for_unit("lilly.service")
    current = machine.succeed("systemctl show -p MainPID --value lilly.service").strip()
    assert current != "0" and current != previous
    eventually(fresh_hosts)


def private_services_ready(machine: RelocationMachineLike) -> bool:
    """@cc [owner:ghuntley,label:verification;security;recovery] relocation-reboot-private-readiness
    Reboot recovery MUST obtain live host-bound Ziggy readiness and the exact
    private Audi readiness frame before admitting further guests. Service unit
    state or authenticated capacity alone MUST NOT establish these prerequisites.
    Missing or malformed evidence MUST postpone recovery within its setup bound.
    """
    ziggy = (
        "curl --fail --silent --max-time 2 --unix-socket /run/ziggy/proxy.sock "
        "http://localhost/health/ready | jq -e --arg host "
        + shlex.quote(host_bindings[machine.name]["host"])
        + " '(.version == 1) and (.ready == true) and (.role == \"ziggy\") and (.host_id == $host)'"
    )
    code, _output = machine.execute(ziggy, timeout=5)
    if code != 0:
        return False
    audi_probe = (
        "import json\n"
        "import socket\n\n"
        "with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:\n"
        "    channel.settimeout(2)\n"
        '    channel.connect("/run/audi-private/status.sock")\n'
        '    with channel.makefile("rb") as stream:\n'
        "        frame: bytes = stream.readline(4097)\n"
        'assert len(frame) <= 4096 and frame.endswith(b"\\n")\n'
        "value: object = json.loads(frame)\n"
        'assert isinstance(value, dict) and set(value) == {"version", "role", "ready"}\n'
        'assert type(value["version"]) is int and value["version"] == 1\n'
        'assert value["role"] == "private" and value["ready"] is True\n'
    )
    code, _output = machine.execute("python3 -c " + shlex.quote(audi_probe), timeout=5)
    return code == 0


def partial_receive(machine: RelocationMachineLike, dataset: str) -> bool:
    assert dataset.startswith("zroot/lilly/vm-")
    assert str(uuid.UUID(dataset.removeprefix("zroot/lilly/vm-"))) == dataset.removeprefix(
        "zroot/lilly/vm-"
    )
    return (
        machine.execute(
            "token=$(zfs get -H -o value receive_resume_token "
            + dataset
            + ') && test -n "$token" && test "$token" != -'
        )[0]
        == 0
    )


def relocation_diagnostic_object(value: object) -> dict[str, object]:
    """@cc [owner:ghuntley,label:verification] relocation-diagnostic-object-boundary
    Nonobjects or objects with nonstring keys MUST yield no usable evidence.
    Field consumers MUST validate each value before synchronizing a native fault.
    """
    if not isinstance(value, dict):
        return {}
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            return {}
        result[key] = item
    return result


def native_receiving_bytes(move: RelocationMove) -> bool:
    """@cc [owner:ghuntley,label:verification;recovery;observability] native-stream-fault-synchronization
    Midstream faults MUST use the exact destination's local receiving journal and
    a unique native transfer helper's ZFS child input bytes. Marshall diagnostic
    rows MUST NOT synchronize faults. Unknown or ambiguous local evidence MUST
    postpone injection; existing physical receipt/cleanup oracles remain authority.
    """
    target = host_for(move_target(move))
    parsed: object = json.loads(
        target.succeed(
            "fleet-relocation-diagnostics " + shlex.quote(move["destination_placement_id"]),
            timeout=30,
        )
    )
    observation = relocation_diagnostic_object(parsed)
    if observation.get("stream_state") != "receiving":
        return False
    processes = relocation_diagnostic_object(observation.get("transfer_processes"))
    if processes.get("complete") is not True:
        return False
    entries = processes.get("entries")
    if not isinstance(entries, list):
        return False
    rows = [relocation_diagnostic_object(entry) for entry in entries]
    helpers = [
        entry.get("pid") for entry in rows if entry.get("executable") == "lilly-transfer-stream"
    ]
    if len(helpers) != 1 or not isinstance(helpers[0], int):
        return False
    consumers = [
        entry
        for entry in rows
        if entry.get("executable") == "zfs" and entry.get("parent") == helpers[0]
    ]
    if len(consumers) != 1:
        return False
    count = consumers[0].get("read_bytes")
    return isinstance(count, int) and count > 1_048_576


def receiving_bytes(move: RelocationMove) -> bool:
    return (
        native_receiving_bytes(move)
        and relocation_row(move, "source_stop_operation_id IS NOT NULL") == "t"
    )


with subtest("cancellation interrupts a nonempty native stream and restores the source"):
    vm, original = seed_relocation_guest()
    guest_assertion(original, "bulk")
    move = relocate(vm)
    eventually(lambda: receiving_bytes(move), timeout=300)
    result = operator(
        m3, dict(action="cancel-relocation", owner_id=users["owner_id"], relocation_id=move["id"])
    )
    assert result["requested"]
    eventually(lambda: relocation_row(move, "finished_at IS NOT NULL") == "t", timeout=900)
    assert (
        relocation_row(
            move,
            "committed_at IS NULL AND source_restored_at IS NOT NULL "
            "AND source_revoked_at IS NOT NULL AND destination_revoked_at IS NOT NULL",
        )
        == "t"
    )
    await_running(vm)
    restored = current_copy(vm)
    assert restored["placement_id"] == original["placement_id"]
    assert restored["epoch"] == move["destination_epoch"]
    guest_assertion(restored, "verify")
    assert (
        sql(
            "SELECT count(*) FROM compute_transfer_slots "
            f"WHERE (source_relocation_id='{move['id']}' OR destination_relocation_id='{move['id']}') "
            "AND released_at IS NULL"
        )
        == "0"
    )
    host_for(move_target(move)).fail("zfs list zroot/lilly/vm-" + move["destination_placement_id"])
    delete_all_copies(vm, [restored, move_target(move)])


with subtest("durable relocation phases recover across both endpoint daemon restarts"):
    vm, original = seed_relocation_guest()
    gates = ["keys", "source", "receive", "import", "readiness", "cleanup"]
    for phase in gates:
        relocation_gate(phase, True)
    try:
        move = relocate(vm)
        source, target = host_for(original), host_for(move_target(move))
        before = process_snapshot(original)
        restart_endpoint(source)
        restart_endpoint(target)
        assert process_snapshot(original) == before
        relocation_gate("keys", False)
        eventually(lambda: relocation_row(move, "destination_public_key IS NOT NULL") == "t")
        assert_retained(move)

        # With keys in place the connectivity probe passes and Marshall stops
        # the running source for its single copy (ADR-0155). The recorded stop
        # MUST survive both daemon restarts while source requests stay gated.
        eventually(lambda: vm_state(vm) == "stopped", timeout=600)
        assert relocation_phase(move["id"])["stop_requested"]
        restart_endpoint(source)
        restart_endpoint(target)
        source.fail("systemctl is-active lilly-vm-" + original["placement_id"] + ".service")
        relocation_gate("source", False)
        eventually(lambda: relocation_phase(move["id"])["descriptor"], timeout=300)
        assert_retained(move)

        # Receive is still blocked. Restart must recover the durable key and
        # source permit without restarting the stopped source guest.
        restart_endpoint(target)
        source.fail("systemctl is-active lilly-vm-" + original["placement_id"] + ".service")
        relocation_gate("receive", False)
        eventually(
            lambda: relocation_phase(move["id"])["received"],
            timeout=900,
        )
        assert vm_state(vm) == "stopped"
        assert current_copy(vm) == original
        assert_retained(move)

        # Lose database authority after the durable final receipt, while import
        # is gated. Neither endpoint may infer permission to boot from its disk.
        db.succeed("systemctl stop postgresql.service")
        try:
            client.wait_until_succeeds(
                f"test $(curl --silent --cacert {root}/ca.crt https://control.example.test/health/ready "
                "-o /dev/null -w '%{http_code}') = 503"
            )
            for copy in [original, move_target(move)]:
                endpoint = host_for(copy)
                endpoint.fail("systemctl is-active lilly-vm-" + copy["placement_id"] + ".service")
                endpoint.succeed("zfs list zroot/lilly/vm-" + copy["placement_id"])
        finally:
            db.succeed("systemctl start postgresql.service")
        client.wait_until_succeeds(
            f"curl --fail --silent --cacert {root}/ca.crt https://control.example.test/health/ready",
            timeout=120,
        )
        eventually(fresh_hosts)
        assert current_copy(vm) == original
        assert_retained(move)
        assert not relocation_phase(move["id"])["committed"]

        # A real source machine reboot after physical stop must retain its fence.
        source.shutdown()
        source.start()
        source.wait_for_unit("lilly.service")
        source.succeed(
            'test "$(zfs get -H -o value mounted zroot/lilly/vm-'
            + original["placement_id"]
            + ')" = yes'
        )
        source.wait_until_succeeds("chronyc waitsync 1 0.01 0 1", timeout=90)
        eventually(lambda source=source: fresh_hosts() and private_services_ready(source))
        source.fail("systemctl is-active lilly-vm-" + original["placement_id"] + ".service")
        restart_endpoint(target)
        relocation_gate("import", False)
        eventually(lambda: relocation_phase(move["id"])["committed"], timeout=600)
        assert current_copy(vm)["placement_id"] == move["destination_placement_id"]
        assert_retained(move)
        source.fail("systemctl is-active lilly-vm-" + original["placement_id"] + ".service")

        restart_endpoint(target)
        relocation_gate("readiness", False)
        eventually(lambda: relocation_phase(move["id"])["readiness"] == "ready", timeout=300)
        guest_assertion(current_copy(vm), "verify")
        assert_retained(move)
        restart_endpoint(source)
        relocation_gate("cleanup", False)
        moved = await_relocation(move)
        guest_assertion(moved, "verify")
    finally:
        for phase in gates:
            relocation_gate(phase, False)
    delete_all_copies(vm, [original, moved])


# @cc [owner:ghuntley,label:verification;recovery] completed-receive-before-acknowledgement
# This case MUST prove the final native snapshot and completed local journal while
# Marshall still lacks its receipt, then restart the receiver before restoring
# transport. Only real replay may advance handoff; source fencing and both disk
# holds MUST remain intact throughout the gap.
with subtest("completed final receive survives endpoint loss before its control receipt"):
    # Make the single full stream large enough to gate its receipt after
    # streaming has started, while keeping it inside the existing signed lease.
    vm, original = seed_relocation_guest()
    guest_assertion(original, "bulk")
    relocation_gate("import", True)
    move = relocate(vm)
    try:
        eventually(
            lambda: (
                native_receiving_bytes(move) and relocation_row(move, "committed_at IS NULL") == "t"
            ),
            timeout=900,
        )
        relocation_gate("receive", True)
        target = host_for(move_target(move))

        def received_locally() -> bool:
            raw: object = json.loads(
                target.succeed(
                    "fleet-relocation-diagnostics " + shlex.quote(move["destination_placement_id"]),
                    timeout=30,
                )
            )
            return relocation_diagnostic_object(raw).get("stream_state") == "received"

        eventually(received_locally, timeout=180)
        target.succeed("zfs list zroot/lilly/vm-" + move["destination_placement_id"] + "@lilly-b")
        phase = relocation_phase(move["id"])
        assert not phase["received"]
        assert not phase["import_requested"] and not phase["committed"]
        assert current_copy(vm) == original
        assert vm_state(vm) == "stopped"
        assert_retained(move)
        restart_endpoint(target)
        assert received_locally()
        assert not relocation_phase(move["id"])["received"]
        relocation_gate("receive", False)
        eventually(lambda: relocation_phase(move["id"])["received"], timeout=180)
        assert not relocation_phase(move["id"])["committed"]
        relocation_gate("import", False)
        moved = await_relocation(move)
        guest_assertion(moved, "verify")
    finally:
        relocation_gate("receive", False)
        relocation_gate("import", False)
    delete_all_copies(vm, [original, moved])


with subtest("cancellation after physical source stop restores data and fresh authority"):
    vm, original = seed_relocation_guest()
    relocation_gate("import", True)
    try:
        move = relocate(vm)
        eventually(
            lambda: relocation_phase(move["id"])["received"],
            timeout=900,
        )
        assert vm_state(vm) == "stopped"
        assert_retained(move)
        target = host_for(move_target(move))
        target.succeed("systemctl stop lilly.service")
        result = operator(
            m3,
            dict(action="cancel-relocation", owner_id=users["owner_id"], relocation_id=move["id"]),
        )
        assert result["requested"]
        eventually(
            lambda: relocation_row(move, "source_restored_at IS NOT NULL") == "t", timeout=600
        )
        await_running(vm)
        restored = current_copy(vm)
        assert restored["placement_id"] == original["placement_id"]
        assert restored["epoch"] == move["destination_epoch"]
        assert relocation_row(move, "committed_at IS NULL") == "t"
        assert_retained(move)
        guest_assertion(restored, "verify")
        target.succeed("systemctl start lilly.service")
        eventually(lambda: relocation_row(move, "finished_at IS NOT NULL") == "t", timeout=600)
        target.fail("zfs list zroot/lilly/vm-" + move["destination_placement_id"])
    finally:
        relocation_gate("import", False)
    delete_all_copies(vm, [restored, move_target(move)])


with subtest("readiness timeout retains the fenced source and Delete reclaims both copies"):
    vm, original = seed_relocation_guest()
    relocation_gate("readiness", True)
    try:
        move = relocate(vm)
        eventually(lambda: relocation_phase(move["id"])["committed"], timeout=900)
        await_running(vm)
        guest_assertion(current_copy(vm), "break-readiness")
        assert relocation_phase(move["id"])["readiness"] == "pending"
        relocation_gate("readiness", False)
        eventually(lambda: relocation_phase(move["id"])["readiness"] == "failed", timeout=1200)
        assert vm_state(vm) == "running"
        assert relocation_phase(move["id"])["committed"]
        assert_retained(move)
        host_for(original).succeed("zfs list zroot/lilly/vm-" + original["placement_id"])
        host_for(original).fail(
            "systemctl is-active lilly-vm-" + original["placement_id"] + ".service"
        )
        restart_endpoint(host_for(original))
        assert current_copy(vm)["placement_id"] == move["destination_placement_id"]
        host_for(original).fail(
            "systemctl is-active lilly-vm-" + original["placement_id"] + ".service"
        )
        guest_assertion(current_copy(vm), "verify")
        delete_all_copies(vm, [original, move_target(move)])
    finally:
        relocation_gate("readiness", False)


with subtest("Delete while destination cleanup is unavailable retains its disk and address"):
    vm, original = seed_relocation_guest()
    relocation_gate("import", True)
    relocation_gate("destination_cleanup", True)
    try:
        move = relocate(vm)
        eventually(
            lambda: relocation_phase(move["id"])["received"],
            timeout=900,
        )
        result = operator(
            m3,
            dict(action="cancel-relocation", owner_id=users["owner_id"], relocation_id=move["id"]),
        )
        assert result["requested"]
        eventually(
            lambda: relocation_row(move, "source_restored_at IS NOT NULL") == "t", timeout=600
        )
        assert_retained(move)
        lifecycle(vm, "delete")
        eventually(
            lambda: (
                sql(
                    "SELECT NOT disk_held FROM compute_reservations "
                    f"WHERE placement_id='{original['placement_id']}'"
                )
                == "t"
            ),
            timeout=600,
        )
        assert (
            sql(
                "SELECT disk_held FROM compute_reservations "
                f"WHERE placement_id='{move['destination_placement_id']}'"
            )
            == "t"
        )
        assert (
            sql(f"SELECT archived_at IS NULL FROM compute_virtual_machines WHERE id='{vm}'") == "t"
        )
        assert (
            sql(
                "SELECT count(*) FROM compute_network_addresses "
                f"WHERE vm_id='{vm}' AND archived_at IS NULL"
            )
            == "1"
        )
        restart_endpoint(host_for(move_target(move)))
        relocation_gate("destination_cleanup", False)
        eventually(
            lambda: (
                sql(f"SELECT archived_at IS NOT NULL FROM compute_virtual_machines WHERE id='{vm}'")
                == "t"
            ),
            timeout=600,
        )
        assert (
            sql(f"SELECT count(*) FROM compute_reservations WHERE vm_id='{vm}' AND disk_held")
            == "0"
        )
        host_for(move_target(move)).fail(
            "zfs list zroot/lilly/vm-" + move["destination_placement_id"]
        )
    finally:
        relocation_gate("import", False)
        relocation_gate("destination_cleanup", False)


# @cc [owner:ghuntley,label:verification;recovery] relocation-update-native-resume
# Update acceptance MUST interrupt an observed nonempty native transfer, prove a
# destination resume token without logging it, and activate actual new releases
# through the updater on both endpoints. The physically stopped source MUST stay
# stopped and its synced data MUST survive; a daemon restart alone MUST NOT count
# as updater acceptance.
with subtest("actual endpoint updates resume an interrupted native transfer"):
    vm, original = seed_relocation_guest()
    guest_assertion(original, "bulk")
    update_inputs = {machine.name: update_repository(machine) for machine in provisioners}
    move = relocate(vm)
    target = host_for(move_target(move))
    source = host_for(original)

    eventually(lambda: receiving_bytes(move), timeout=300)
    relocation_gate("receive", True)
    try:
        target.succeed("systemctl stop lilly.service", timeout=120)
        dataset = "zroot/lilly/vm-" + move["destination_placement_id"]
        # Token is sensitive authority-adjacent data: inspect only its presence.
        eventually(lambda: partial_receive(target, dataset), timeout=120)
        assert_retained(move)
        for machine in [target, source]:
            repo, candidates = update_inputs[machine.name]
            old_release = machine.succeed(
                "systemctl show -p WorkingDirectory --value lilly.service"
            ).strip()
            revision = update_publish(
                machine, repo, candidates["updated"], "relocation-resume-update"
            )
            update_success(machine)
            assert update_status(machine)["lastHealthy"]["revision"] == revision
            assert (
                machine.succeed("systemctl show -p WorkingDirectory --value lilly.service").strip()
                != old_release
            )
            source.fail("systemctl is-active lilly-vm-" + original["placement_id"] + ".service")
        assert vm_state(vm) == "stopped"
        assert current_copy(vm) == original
        assert_retained(move)
    finally:
        relocation_gate("receive", False)
    moved = await_relocation(move)
    guest_assertion(moved, "verify")
    delete_all_copies(vm, [original, moved])


with subtest("failed destination readiness retries under a new boot without source rollback"):
    vm, original = seed_relocation_guest()
    relocation_gate("readiness", True)
    try:
        move = relocate(vm)
        eventually(lambda: relocation_phase(move["id"])["committed"], timeout=900)
        await_running(vm)
        guest_assertion(current_copy(vm), "break-readiness")
        assert relocation_phase(move["id"])["readiness"] == "pending"
        relocation_gate("readiness", False)
        eventually(lambda: relocation_phase(move["id"])["readiness"] == "failed", timeout=1200)
        assert vm_state(vm) == "running"
        failed = sql_json(
            "SELECT json_build_object('id',id,'deadline',deadline_at,'generation',generation) "
            f"FROM compute_readiness_requests WHERE relocation_id='{move['id']}'"
        )
        assert_retained(move)
        before = current_copy(vm)
        request = dict(
            action="retry-relocation",
            owner_id=users["owner_id"],
            relocation_id=move["id"],
            key=str(uuid.uuid4()),
        )
        retry_result = operator(m2, request)
        assert operator(m3, request)["id"] == retry_result["id"]
        assert current_copy(vm) == before
        host_for(original).fail(
            "systemctl is-active lilly-vm-" + original["placement_id"] + ".service"
        )
        relocation_gate("readiness", False)
        moved = await_relocation(move)
        assert moved == before
        assert (
            sql(f"SELECT status FROM compute_readiness_requests WHERE id='{failed['id']}'")
            == "failed"
        )
        assert (
            sql_json(
                "SELECT json_build_object('id',id,'deadline',deadline_at,'generation',generation) "
                f"FROM compute_readiness_requests WHERE id='{failed['id']}'"
            )
            == failed
        )
        assert (
            sql(
                "SELECT count(*) FROM compute_readiness_requests "
                f"WHERE relocation_id='{move['id']}' AND status='ready' AND generation>{failed['generation']}"
            )
            == "1"
        )
        guest_assertion(moved, "verify")
    finally:
        relocation_gate("readiness", False)
    delete_all_copies(vm, [original, moved])


def reserve_pool_pressure(machine: RelocationMachineLike, headroom: int) -> None:
    """@cc [owner:ghuntley,label:verification;capacity] relocation-pressure-is-physical
    Pressure MUST use a real sibling ZFS reservation outside the owned guest
    root, never fabricated reports or ownership corruption. The guest root's
    quota, policy and GUIDs MUST remain unchanged. Removing pressure grants no
    capacity until authenticated reports observe recovery.
    """
    available = int(machine.succeed("zfs get -Hp -o value available zroot").strip())
    assert available > headroom
    machine.succeed(
        "zfs create -o canmount=off -o mountpoint=none -o refreservation="
        + str(available - headroom)
        + " zroot/relocation-pressure"
    )
    observed = int(machine.succeed("zfs get -Hp -o value available zroot/lilly").strip())
    assert 0 <= observed <= headroom


def release_pool_pressure(machine: RelocationMachineLike) -> None:
    machine.succeed("zfs destroy zroot/relocation-pressure")
    eventually(fresh_hosts)


with subtest("physical source pool pressure does not block the stopped copy or co-resident guests"):
    guests = [seed_relocation_guest() for _ in range(3)]
    # Three publicly placed guests on two hosts give a source with a co-resident
    # workload. Select that source without manufacturing placement or capacity.
    cohosted = next(
        copy["host_id"]
        for _, copy in guests
        if sum(other["host_id"] == copy["host_id"] for _, other in guests) >= 2
    )
    vm, original = next(
        (identifier, copy) for identifier, copy in guests if copy["host_id"] == cohosted
    )
    unrelated = [(identifier, copy) for identifier, copy in guests if identifier != vm]
    before = {identifier: process_snapshot(copy) for identifier, copy in unrelated}
    source = host_for(original)
    # 1.5 GiB free on the source: a stopped source snapshot cannot diverge, so
    # ADR-0155 holds no source headroom and the move MUST still be admitted.
    reserve_pool_pressure(source, 1536 * 1024**2)
    try:
        for identifier, copy in unrelated:
            assert process_snapshot(copy) == before[identifier]
            guest_assertion(copy, "verify")
            guest_assertion(copy, "verify-live")
        host_id = original["host_id"]
        eventually(
            lambda: (
                sql(
                    "SELECT free_bytes < 2147483648 AND reported_at > "
                    "(statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds' "
                    f"FROM compute_storage_pools WHERE host_id='{host_id}'"
                )
                == "t"
            )
        )
        move = relocate(vm)
        moved = await_relocation(move)
        assert moved["slot"] == original["slot"]
        guest_assertion(moved, "verify")
        for identifier, copy in unrelated:
            assert process_snapshot(copy) == before[identifier]
            assert current_copy(identifier) == copy
            guest_assertion(copy, "verify")
            guest_assertion(copy, "verify-live")
    finally:
        release_pool_pressure(source)
    delete_all_copies(vm, [original, moved])
    for identifier, copy in unrelated:
        delete_all_copies(identifier, [copy])


with subtest("destination ENOSPC preserves holds and resumes after physical headroom returns"):
    vm, original = seed_relocation_guest()
    guest_assertion(original, "bulk")
    relocation_gate("receive", True)
    move = relocate(vm)
    target = host_for(move_target(move))
    reserve_pool_pressure(target, 16 * 1024**2)
    try:
        eventually(lambda: relocation_phase(move["id"])["descriptor"], timeout=300)
        relocation_gate("receive", False)
        dataset = "zroot/lilly/vm-" + move["destination_placement_id"]
        eventually(lambda: partial_receive(target, dataset), timeout=300)
        assert_retained(move)
        assert current_copy(vm) == original
        assert vm_state(vm) == "stopped"
        assert (
            relocation_row(move, "committed_at IS NULL AND source_stop_operation_id IS NOT NULL")
            == "t"
        )
    finally:
        relocation_gate("receive", False)
        release_pool_pressure(target)
    moved = await_relocation(move)
    guest_assertion(moved, "verify")
    delete_all_copies(vm, [original, moved])
