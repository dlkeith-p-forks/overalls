with subtest("actual profile egress and same-host/cross-host guest denial"):
    egress.wait_for_unit("fleet-egress.service")
    egress.wait_for_unit("dnsmasq.service")
    guests = sql_json(
        "SELECT json_agg(json_build_object('vm_id',v.id,'placement_id',p.id,'host_id',p.host_id,"
        "'profile',a.profile,'slot',a.slot)) FROM compute_virtual_machines v "
        "JOIN compute_workload_placements p ON p.id=v.current_placement_id "
        "JOIN compute_network_addresses a ON a.vm_id=v.id WHERE v.archived_at IS NULL"
    )
    # Closed diagnostics only: profile counts, never addresses or identifiers.
    profiles = sorted(str(guest["profile"]) for guest in guests)
    assert len(guests) == 6, profiles
    assert {guest["profile"] for guest in guests} == {"customer", "standard", "oss"}, profiles
    requests = {}
    for machine in provisioners:
        machine.wait_for_unit("fleet-host-listener.service")
        # Positive controls establish reachable protected/host listeners outside
        # the guest isolation boundary. No public Internet service is contacted.
        machine.succeed(
            "curl --fail --silent http://11.0.0.1:8080/ && curl --fail --silent http://11.0.0.2:8080/"
        )
        client.succeed(f"curl --fail --silent http://{machine.name}:8080/ -o /dev/null")
        requests[machine.name] = request_file(
            machine,
            dict(
                host_id=host_bindings[machine.name]["host"],
                guests=guests,
                host_addresses=[host["ip"] for host in host_bindings.values()],
            ),
        )
        machine.succeed("fleet-network prepare " + shlex.quote(requests[machine.name]), timeout=240)
    for machine in provisioners:
        machine.succeed("fleet-network probe " + shlex.quote(requests[machine.name]), timeout=300)
