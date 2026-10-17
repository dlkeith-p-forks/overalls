"""Native launch fencing and authenticated settlement across full daemon loss."""

from hypothesis import Phase as SubmissionPhase
from hypothesis import example, given, settings
from hypothesis import strategies as st


# After a real body failure, shared guests may be failed or mid-transition.
# Preserve the first fault; rerunning/shrinking on that changed fleet is not an
# independent history. All fixed witnesses and generated draws run on success.
@settings(
    max_examples=1,
    deadline=None,
    derandomize=True,
    report_multiple_bugs=False,
    phases=[SubmissionPhase.explicit, SubmissionPhase.generate],
)
@example(host_index=0, reopens=1)
@example(host_index=1, reopens=2)
@given(host_index=st.sampled_from([0, 1]), reopens=st.sampled_from([1, 2]))
def submission_daemon_recovery(host_index: int, reopens: int) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] native-submission-daemon-recovery
    Each history MUST observe a real before/after submission checkpoint and old
    daemon death. Before submission MUST refuse the fenced generation; after
    submission MUST adopt the exact VMM. Authenticated settlement and subsequent
    daemon reopens MUST preserve outcome identity and unrelated native processes.
    """
    machine = provisioners[host_index]
    victim = next(vm for vm in vms if host_for(vm) is machine and vm["profile"] == "standard")
    vm_id = victim["vm_id"]
    placement = victim["placement_id"]
    barrier = "/run/fleet-submission-barrier"
    unit = f"lilly-vm-{placement}.service"
    marker = f"/var/lib/lilly/vms/{placement}/launch-attempt.bin"
    survivors = {vm["vm_id"]: process_snapshot(vm) for vm in vms if vm != victim}

    for phase in ("before", "after"):
        lifecycle(vm_id, "stop")
        eventually(lambda: vm_state(vm_id) == "stopped")
        machine.fail(f"systemctl is-active {unit}")
        machine.succeed(f"rm -rf {barrier}; install -d -m 0700 {barrier}")
        selector = placement + "\n" + phase + "\n"
        machine.succeed("printf %s " + shlex.quote(selector) + f" > {barrier}/armed")
        old_pid = int(machine.succeed("systemctl show -p MainPID --value lilly.service"))
        assert old_pid > 0
        try:
            lifecycle(vm_id, "start")
            # Pause the complete daemon tree, including the native command
            # owner, so its deadline cannot execute before the intended kill.
            machine.wait_until_succeeds(
                f"test -f {barrier}/reached && "
                "systemctl kill --kill-whom=all --signal=STOP lilly.service",
                timeout=30,
            )
            assert machine.succeed(f"cat {barrier}/reached").strip() == phase
            worker_pid, worker_start = (
                int(value) for value in machine.succeed(f"cat {barrier}/worker").strip().split(":")
            )
            assert worker_pid > 0 and worker_start > 0
            daemon_stat = machine.succeed(f"cat /proc/{old_pid}/stat").rsplit(") ", 1)[1].split()
            assert daemon_stat[0] == "T", "the original daemon must actually be suspended"
            assert (
                int(machine.succeed("systemctl show -p MainPID --value lilly.service")) == old_pid
            )
            authority = sql(
                "SELECT execution_epoch::text || ':' || generation::text "
                f"FROM compute_operations WHERE vm_id='{vm_id}' AND kind='start' "
                "ORDER BY generation DESC LIMIT 1"
            )
            epoch, generation = (int(value) for value in authority.split(":"))
            assert epoch > 0 and generation > 0
            outcome_filter = (
                f"placement_id='{placement}' AND execution_epoch={epoch} "
                f"AND generation={generation}"
            )
            assert (
                sql(f"SELECT count(*) FROM compute_physical_outcomes WHERE {outcome_filter}") == "0"
            )
            original_marker = machine.succeed(f"sha256sum {marker}")
            launched: list[object] | None = None
            if phase == "before":
                machine.fail(f"systemctl is-active {unit}")
            else:
                machine.wait_for_unit(unit, timeout=30)
                machine.wait_until_succeeds(f"fleet-processes {placement}", timeout=30)
                launched = process_snapshot(victim)
                assert launched
            machine.succeed(f"rm {barrier}/armed")
            worker_stat = machine.succeed(f"cat /proc/{worker_pid}/stat").rsplit(") ", 1)[1].split()
            assert worker_stat[0] == "T" and int(worker_stat[19]) == worker_start, (
                "the actual barrier worker must be suspended until the intended daemon fault"
            )
            machine.succeed("systemctl kill --kill-whom=all --signal=KILL lilly.service")
            # The old process must actually disappear; a new MainPID alone
            # does not prove that the observed original daemon has died.
            machine.wait_until_succeeds(f"test ! -e /proc/{old_pid}", timeout=30)
            machine.wait_until_succeeds(f"test ! -e /proc/{worker_pid}", timeout=30)
            machine.wait_until_succeeds(
                "test $(systemctl show -p MainPID --value lilly.service) -gt 0 && "
                f"test $(systemctl show -p MainPID --value lilly.service) != {old_pid}",
                timeout=60,
            )
            target = "failed" if phase == "before" else "running"
            eventually(lambda expected=target: vm_state(vm_id) == expected, timeout=180)
            assert machine.succeed(f"sha256sum {marker}") == original_marker
            expected_reason = "execution_failed" if phase == "before" else "none"
            assert (
                sql(
                    "SELECT count(*) FROM compute_physical_outcomes "
                    f"WHERE {outcome_filter} AND observation->>'state'='{target}' "
                    f"AND observation->>'reason'='{expected_reason}'"
                )
                == "1"
            )
            assert (
                sql(
                    "SELECT status FROM compute_operations "
                    f"WHERE placement_id='{placement}' AND execution_epoch={epoch} "
                    f"AND generation={generation}"
                )
                == "completed"
            )
            settled = sql(
                "SELECT id::text || ':' || sequence::text FROM compute_physical_outcomes "
                f"WHERE {outcome_filter} ORDER BY sequence"
            )
            assert settled
            for _ in range(reopens):
                machine.succeed("systemctl restart lilly.service")
                machine.wait_until_succeeds("fleet-readiness true", timeout=120)
                assert vm_state(vm_id) == target
                assert (
                    sql(
                        "SELECT id::text || ':' || sequence::text FROM compute_physical_outcomes "
                        f"WHERE {outcome_filter} ORDER BY sequence"
                    )
                    == settled
                )
                assert machine.succeed(f"sha256sum {marker}") == original_marker
                if launched is not None:
                    assert process_snapshot(victim) == launched
                else:
                    machine.fail(f"systemctl is-active {unit}")
                for vm in vms:
                    if vm != victim:
                        assert process_snapshot(vm) == survivors[vm["vm_id"]]
            if phase == "before":
                # A distinct public start authority is required to recover the
                # deliberately fenced attempt; same-generation relaunch is forbidden.
                lifecycle(vm_id, "start")
                next_generation = int(
                    sql(f"SELECT generation FROM compute_virtual_machines WHERE id='{vm_id}'")
                )
                assert next_generation > generation

                def restored_generation_running(
                    expected_epoch: int = epoch, expected_generation: int = next_generation
                ) -> bool:
                    # The VM retains its previous failed observation until the
                    # new generation settles. It is not failure of this request.
                    current = (
                        f"placement_id='{placement}' AND execution_epoch={expected_epoch} "
                        f"AND generation={expected_generation}"
                    )
                    assert (
                        sql(
                            "SELECT count(*) FROM compute_physical_outcomes "
                            f"WHERE {current} AND observation->>'state'='failed'"
                        )
                        == "0"
                    ), "the newly requested generation must not fail"
                    return (
                        sql(
                            "SELECT count(*) FROM compute_operations o "
                            "JOIN compute_physical_outcomes p ON p.id=o.completion_outcome_id "
                            f"WHERE o.placement_id='{placement}' AND o.execution_epoch={expected_epoch} "
                            f"AND o.generation={expected_generation} AND o.status='completed' "
                            "AND p.observation->>'state'='running'"
                        )
                        == "1"
                    )

                eventually(restored_generation_running, timeout=600)
                assert vm_state(vm_id) == "running"
        finally:
            machine.execute(f"rm -f {barrier}/armed; touch {barrier}/release")
            machine.execute("systemctl kill --kill-whom=all --signal=CONT lilly.service")


with subtest("real launch submission and authenticated outcome survive whole daemon loss"):
    submission_daemon_recovery()
