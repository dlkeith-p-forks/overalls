"""Native status-socket and guest-survival histories with pinned Hypothesis."""

from hypothesis import example, given, settings
from hypothesis import strategies as st


# The action menu is first/repeated incarnation restart on each host; exact
# report-age boundaries remain in the direct Runtime property, not this wall clock test.
@settings(max_examples=2, deadline=None, derandomize=True)
@example(restarts=(1, 2))
@example(restarts=(2, 1))
@given(restarts=st.tuples(st.sampled_from([1, 2]), st.sampled_from([1, 2])))
def runtime_readiness_restarts(restarts: tuple[int, int]) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] readiness-native-runtime-incarnation
    Restored journals MUST NOT produce readiness without a newly delivered report
    and authenticated runtime. Under database outage, each restarted daemon MUST
    refuse readiness while the exact preexisting VMM process snapshots survive.
    """
    probe = "fleet-readiness "
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


with subtest("real Runtime readiness cannot survive incarnation restart on stale journals"):
    runtime_readiness_restarts()
