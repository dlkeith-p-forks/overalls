# @cc [owner:ghuntley,label:verification] customer-fleet-controlled-placement
# Network acceptance MUST place one Customer, Standard and OSS guest on each
# real Lilly host through ordinary admission. Only explicit capacity refusal may
# be retried; this setup MUST NOT replace the separate capacity-race assertions.
with subtest("place the profile matrix independently of capacity-race timing"):
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
        for profile in ("customer", "standard", "oss"):
            placed = provision_when_available(m1, profile)
            assert placed["host_id"] == host_bindings[machine.name]["host"]
            vm = ProfiledPlacement(
                vm_id=placed["vm_id"],
                host_id=placed["host_id"],
                placement_id=placed["placement_id"],
                accepted=placed["accepted"],
                profile=profile,
            )
            vms.append(vm)
            await_running(vm["vm_id"])
    for machine in provisioners:
        operator(
            m1, dict(action="enable", host_id=host_bindings[machine.name]["host"], enabled=True)
        )
    assert len(vms) == 6
