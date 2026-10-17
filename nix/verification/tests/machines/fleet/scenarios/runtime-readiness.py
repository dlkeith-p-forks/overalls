"""Native status-socket and guest-survival histories driven by Hegel."""

from hegel import TestCase, given, sampled_from, tuples


# The action menu is first/repeated incarnation restart on each host; exact
# report-age boundaries remain in the direct Runtime property, not this wall clock test.
@given(restarts=tuples(sampled_from([1, 2]), sampled_from([1, 2])))
def runtime_readiness_restarts(tc: TestCase, restarts: tuple[int, int]) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] readiness-native-runtime-incarnation
    Restored journals MUST NOT produce readiness without a newly delivered report
    and authenticated runtime. Under database outage, each restarted daemon MUST
    refuse readiness while the exact preexisting VMM process snapshots survive.
    """
    probe = "fleet-readiness "
    # A previous generated case may have been interrupted after killing a daemon.
    # Restore the shared fixture to its authenticated baseline before drawing the
    # next history; this also makes shrinking/replay independent of case order.
    for machine in provisioners:
        machine.succeed("systemctl start lilly.service")
    db.succeed("systemctl start postgresql.service")
    eventually(fresh_hosts)
    before = {vm["vm_id"]: process_snapshot(vm) for vm in vms}
    epochs = {
        binding["host"]: int(
            sql(f"SELECT connection_epoch FROM compute_hosts WHERE id='{binding['host']}'")
        )
        for binding in host_bindings.values()
    }
    for machine in provisioners:
        machine.wait_until_succeeds(probe + "true")
    db.succeed("systemctl stop postgresql.service")
    try:
        for machine in provisioners:
            machine.wait_until_succeeds(probe + "false", timeout=30)
        for machine, count in zip(provisioners, restarts, strict=True):
            for _ in range(count):
                previous = int(machine.succeed("systemctl show -p MainPID --value lilly.service"))
                assert previous > 0
                machine.succeed("systemctl kill --kill-whom=main --signal=KILL lilly.service")
                machine.wait_until_succeeds(
                    "test $(systemctl show -p MainPID --value lilly.service) -gt 0 && "
                    f"test $(systemctl show -p MainPID --value lilly.service) != {previous}"
                )
                machine.wait_until_succeeds(probe + "false", timeout=30)
                machine.succeed(probe + "false 5")
        for vm in vms:
            assert process_snapshot(vm) == before[vm["vm_id"]]
    finally:
        db.succeed("systemctl start postgresql.service")
    for host_id, epoch in epochs.items():
        eventually(
            lambda host_id=host_id, epoch=epoch: (
                int(sql(f"SELECT connection_epoch FROM compute_hosts WHERE id='{host_id}'")) > epoch
            )
        )
    eventually(fresh_hosts)
    for machine in provisioners:
        machine.wait_until_succeeds(probe + "true", timeout=120)
    for vm in vms:
        assert process_snapshot(vm) == before[vm["vm_id"]]
