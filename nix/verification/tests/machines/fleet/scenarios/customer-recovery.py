with subtest("Customer egress denial survives guest stop/start on both hosts"):
    for vm in vms:
        if vm["profile"] == "customer":
            lifecycle(vm["vm_id"], "stop")
            eventually(lambda vm=vm: vm_state(vm["vm_id"]) == "stopped")
            lifecycle(vm["vm_id"], "start")
            await_running(vm["vm_id"])
    # Guest restart clears /run. Re-establish and prove peer listeners without
    # overwriting the retained disk marker checked by the subsequent probe.
    for machine in provisioners:
        machine.succeed(
            "fleet-network listeners " + shlex.quote(requests[machine.name]), timeout=240
        )
    for machine in provisioners:
        machine.succeed("fleet-network probe " + shlex.quote(requests[machine.name]), timeout=300)
