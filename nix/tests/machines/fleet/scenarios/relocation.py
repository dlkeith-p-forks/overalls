def assert_relocation_audit(vm: str, move: RelocationMove) -> None:
    """@cc [owner:ghuntley,label:verification;observability] relocation-independent-diagnostics
    A completed fresh-fixture move MUST retain its transactional successful
    Relocation audit and MUST NOT ingest Lilly's native diagnostic events.
    Native guest data, placement, fencing and cleanup assertions remain required.
    """
    assert str(uuid.UUID(vm)) == vm
    assert (
        sql(
            "SELECT count(*) FROM compute_lifecycle_events "
            f"WHERE vm_id='{vm}' AND actor_kind='provisioner'"
        )
        == "0"
    )
    assert (
        sql(
            "SELECT EXISTS(SELECT 1 FROM compute_lifecycle_events "
            f"WHERE vm_id='{vm}' AND resource_type='Relocation' "
            f"AND resource_id='{move['id']}' AND actor_kind IN ('user','system') "
            "AND next_state='complete' AND measurement_outcome='succeeded')"
        )
        == "t"
    )


def hold_without_stop(identifier: str, seconds: float = 30.0) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] relocation-no-stop-without-probe
    While the source transfer endpoint is unreachable the relocation MUST wait in
    checking_transfer with no stop operation and no native transfer snapshot:
    ADR-0155 stops a running source only after fresh destination connectivity proof.
    """
    eventually(lambda: relocation_phase(identifier)["phase"] == "checking_transfer", timeout=300)
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        phase = relocation_phase(identifier)
        assert phase["phase"] == "checking_transfer" and not phase["stop_requested"], phase
        time.sleep(2)


def await_stop_requested(identifier: str) -> None:
    eventually(lambda: relocation_phase(identifier)["stop_requested"], timeout=600)


with subtest("Marshall moves a running guest only after connectivity proof, then stops it"):
    egress.wait_for_unit("fleet-egress.service")
    egress.wait_for_unit("dnsmasq.service")
    for machine in provisioners:
        machine.succeed("curl --fail --silent http://11.0.0.1:8080/ -o /dev/null")
    admitted = operator(m1, provision("customer"))
    assert admitted["accepted"]
    vm = str(admitted["vm_id"])
    await_running(vm)
    original = current_copy(vm)
    source = host_for(original)
    guest_assertion(original, "prepare")
    guest_assertion(original, "customer-network")
    # Without the source transfer endpoint the destination probe cannot succeed,
    # so the guest MUST keep running untouched. Guest execution and
    # authenticated HTTPS control remain available.
    source.succeed("systemctl stop lilly-transfer-sshd.service")
    move = relocate(vm)
    assert move["source_placement_id"] == original["placement_id"]
    hold_without_stop(move["id"])
    source.fail("zfs list -t snapshot zroot/lilly/vm-" + original["placement_id"] + "@lilly-b")
    assert current_copy(vm) == original
    state = vm_state(vm)
    if state != "running":
        # Read-only bounded control facts; no guest console or credentials.
        print(
            sql_json(
                "SELECT json_build_object('state',observed_state,'desired',desired_state,"
                "'reason',failure_reason,'generation',generation) "
                f"FROM compute_virtual_machines WHERE id='{vm}'"
            )
        )
    assert state == "running", "source observation changed before connectivity proof: " + state
    guest_assertion(original, "before-stop")
    source.succeed("systemctl start lilly-transfer-sshd.service")
    destination = await_relocation(move)
    assert destination["host_id"] != original["host_id"]
    assert destination["slot"] == original["slot"]
    guest_assertion(destination, "verify")
    assert_relocation_audit(vm, move)
    guest_assertion(destination, "customer-network")

with subtest("returning to a former host creates a new placement and retains final data"):
    back = relocate(vm)
    returned = await_relocation(back)
    # The imported placement was the source: its disk was reclaimed.
    eventually(
        lambda: (
            host_for(destination).execute("zfs list zroot/lilly/vm-" + destination["placement_id"])[
                0
            ]
            != 0
        ),
        timeout=600,
    )
    assert returned["host_id"] == original["host_id"]
    assert returned["placement_id"] not in [original["placement_id"], destination["placement_id"]]
    assert returned["epoch"] == original["epoch"] + 2
    assert returned["slot"] == original["slot"]
    guest_assertion(returned, "verify")
    guest_assertion(returned, "customer-network")

with subtest("an initially stopped guest moves without destination boot"):
    lifecycle(vm, "stop")
    eventually(lambda: vm_state(vm) == "stopped")
    stopped_move = relocate(vm)
    stopped = await_relocation(stopped_move, expected_state="stopped")
    assert stopped["host_id"] != returned["host_id"]
    assert stopped["slot"] == original["slot"]
    assert sql(f"SELECT desired_state FROM compute_virtual_machines WHERE id='{vm}'") == "stopped"
    host_for(stopped).fail("systemctl is-active lilly-vm-" + stopped["placement_id"] + ".service")
    group = "/sys/fs/cgroup/lilly.slice/lilly-vm-" + stopped["placement_id"] + ".service"
    check_empty = (
        "from pathlib import Path; p=Path(" + repr(group) + "); "
        "assert all(not f.read_text().strip() for f in p.rglob('cgroup.procs'))"
    )
    host_for(stopped).succeed("python3 -c " + shlex.quote(check_empty))
    lifecycle(vm, "start")
    await_running(vm)
    guest_assertion(stopped, "verify")
    guest_assertion(stopped, "customer-network")

with subtest(
    "pre-handoff cancellation restarts the stopped source while destination is unavailable"
):
    retained = current_copy(vm)
    source = host_for(retained)
    cancelled = relocate(vm)
    relocation_id = str(uuid.UUID(cancelled["id"]))
    remote = host_for(dict(host_id=cancelled["destination_host_id"]))
    # The probe succeeds and the running source is stopped for its single copy.
    # Cut both the source transfer endpoint and the destination daemon as soon
    # as the stop is recorded, so no import or handoff can commit.
    await_stop_requested(relocation_id)
    source.succeed("systemctl stop lilly-transfer-sshd.service")
    remote.succeed("systemctl stop lilly.service")
    assert not relocation_phase(relocation_id)["committed"], "handoff raced the cancellation window"
    reply = operator(
        m3,
        dict(action="cancel-relocation", owner_id=users["owner_id"], relocation_id=relocation_id),
    )
    assert reply["requested"]
    eventually(
        lambda: (
            sql(
                "SELECT source_restored_at IS NOT NULL AND committed_at IS NULL "
                f"AND finished_at IS NULL FROM compute_relocations WHERE id='{relocation_id}'"
            )
            == "t"
        ),
        timeout=600,
    )
    await_running(vm)
    restored = current_copy(vm)
    assert restored["placement_id"] == retained["placement_id"]
    assert restored["epoch"] == cancelled["destination_epoch"]
    assert restored["slot"] == retained["slot"]
    guest_assertion(restored, "verify")
    assert (
        sql(
            "SELECT disk_held FROM compute_reservations "
            f"WHERE placement_id='{cancelled['destination_placement_id']}'"
        )
        == "t"
    )
    remote.fail(
        "systemctl is-active lilly-vm-" + cancelled["destination_placement_id"] + ".service"
    )
    remote.succeed("systemctl start lilly.service")
    eventually(
        lambda: (
            sql(
                "SELECT finished_at IS NOT NULL AND committed_at IS NULL "
                f"FROM compute_relocations WHERE id='{relocation_id}'"
            )
            == "t"
        ),
        timeout=600,
    )
    remote.fail("zfs list zroot/lilly/vm-" + cancelled["destination_placement_id"])
    source.fail("zfs list -t snapshot zroot/lilly/vm-" + restored["placement_id"] + "@lilly-b")
    assert sql(f"SELECT count(*) FROM compute_reservations WHERE vm_id='{vm}' AND disk_held") == "1"
    source.succeed("systemctl start lilly-transfer-sshd.service")
    guest_assertion(restored, "verify")

with subtest("logical Delete releases the final retained copy"):
    lifecycle(vm, "delete")
    eventually(
        lambda: (
            sql(f"SELECT archived_at IS NOT NULL FROM compute_virtual_machines WHERE id='{vm}'")
            == "t"
        )
    )
    assert sql(f"SELECT count(*) FROM compute_reservations WHERE vm_id='{vm}' AND disk_held") == "0"
