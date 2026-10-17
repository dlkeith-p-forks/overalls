"""Two real native guests for independent collector-custody recovery."""

# @cc [owner:ghuntley,label:verification;isolation] observability-native-placement
# The focused variant MUST create one real guest on each provisioner through
# ordinary admission. A survivor on the other host provides an independent
# physical-process oracle while diagnostics fail on the worker host.
with subtest("configure real production collectors and independent spool custody"):
    for machine in provisioners:
        machine.wait_for_unit("opentelemetry-collector.service")
        machine.wait_for_unit("overalls-trace-lilly.service")
        machine.succeed("test -S /run/overalls-trace-lilly/ingest.sock")
        machine.succeed("test -S /run/overalls-otel-traces/collector.sock")
    l1.wait_for_unit("tempo.service")
    vms: list[ProfiledPlacement] = []
    for machine in provisioners:
        for peer in provisioners:
            operator(
                m1,
                dict(
                    action="enable",
                    host_id=host_bindings[peer.name]["host"],
                    enabled=peer == machine,
                ),
            )
        placed = provision_when_available(m1, "standard")
        assert placed["host_id"] == host_bindings[machine.name]["host"]
        vm = ProfiledPlacement(
            vm_id=placed["vm_id"],
            host_id=placed["host_id"],
            placement_id=placed["placement_id"],
            accepted=placed["accepted"],
            profile="standard",
        )
        vms.append(vm)
        await_running(vm["vm_id"])
        eventually(lambda vm_id=vm["vm_id"]: durable_service_level_snapshot(m1, vm_id))
    for machine in provisioners:
        operator(
            m1, dict(action="enable", host_id=host_bindings[machine.name]["host"], enabled=True)
        )
    assert len(vms) == 2
