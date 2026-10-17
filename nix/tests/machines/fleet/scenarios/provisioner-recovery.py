with subtest("Lilly daemon death preserves every independently supervised VMM"):
    before = {vm["vm_id"]: process_snapshot(vm) for vm in vms}
    epochs = {
        binding["host"]: int(
            sql(f"SELECT connection_epoch FROM compute_hosts WHERE id='{binding['host']}'")
        )
        for binding in host_bindings.values()
    }
    for machine in provisioners:
        previous_pid = machine.succeed("systemctl show -p MainPID --value lilly.service").strip()
        assert int(previous_pid) > 0
        machine.succeed("systemctl kill --kill-whom=main --signal=KILL lilly.service")
        machine.wait_until_succeeds("systemctl is-active lilly.service")
        machine.wait_until_succeeds(
            f"test $(systemctl show -p MainPID --value lilly.service) -gt 0 && "
            f"test $(systemctl show -p MainPID --value lilly.service) != {previous_pid}"
        )
    for host_id, epoch in epochs.items():
        eventually(
            lambda host_id=host_id, epoch=epoch: (
                int(sql(f"SELECT connection_epoch FROM compute_hosts WHERE id='{host_id}'")) > epoch
            )
        )
    eventually(fresh_hosts)
    for vm in vms:
        assert process_snapshot(vm) == before[vm["vm_id"]]
