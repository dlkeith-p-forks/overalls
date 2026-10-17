import ipaddress

with subtest("isolated provisioners reject new work despite otherwise available capacity"):
    eventually(fresh_hosts)
    before = {vm["vm_id"]: process_snapshot(vm) for vm in vms}
    # Read the isolated management address explicitly; user-mode QEMU NICs also
    # have addresses, so route lookup must choose the management VLAN interface.
    proxy_ip = l1.succeed(
        "getent ahostsv4 control.example.test | head -n 1 | awk '{print $1}'"
    ).strip()
    assert ipaddress.IPv4Address(proxy_ip).is_private
    # Cut the private fleet listener used by both control exchanges and terminal
    # streams. Port 443 serves browsers and no longer carries provisioner traffic.
    for machine in provisioners:
        machine.succeed("nft add table inet fleet_partition")
        machine.succeed(
            "nft 'add chain inet fleet_partition output { type filter hook output priority -300; policy accept; }'"
        )
        machine.succeed(
            f"nft add rule inet fleet_partition output ip daddr {proxy_ip} tcp dport 5443 drop"
        )
    try:
        eventually(
            lambda: (
                sql(
                    "SELECT count(*) FROM compute_hosts WHERE reported_at > "
                    "(statement_timestamp() AT TIME ZONE 'UTC') - interval '6 seconds'"
                )
                == "0"
            )
        )
        assert (
            sql("SELECT count(*) FROM compute_reservations WHERE compute_held AND disk_held") == "4"
        )
        assert not operator(m3, provision("customer"))["accepted"]
        for vm in vms:
            assert process_snapshot(vm) == before[vm["vm_id"]]
    finally:
        for machine in provisioners:
            machine.succeed("nft delete table inet fleet_partition")
    eventually(fresh_hosts)

    # ADR-0142: after the heal every provisioner re-establishes its long-lived
    # control WebSocket (and terminal stream) to the fleet listener.
    def control_sockets(machine: MachineLike) -> int:
        output = machine.succeed(
            f"ss -Htn state established '( dst {proxy_ip} and dport = :5443 )' | wc -l"
        )
        return int(output.strip())

    for machine in provisioners:
        machine.wait_until_succeeds(
            f"test $(ss -Htn state established '( dst {proxy_ip} and dport = :5443 )' | wc -l) -ge 1",
            timeout=60,
        )
        assert control_sockets(machine) >= 1
    replacements = []
    for host, profile in zip(host_bindings.values(), ["customer", "standard"], strict=False):
        for candidate in host_bindings.values():
            operator(
                m1, dict(action="enable", host_id=candidate["host"], enabled=candidate == host)
            )
        replacements.append(provision_when_available(m3, profile))
    for host in host_bindings.values():
        operator(m1, dict(action="enable", host_id=host["host"], enabled=True))
    assert all(vm["accepted"] for vm in replacements)
    assert len({vm["host_id"] for vm in replacements}) == 2
    for vm in replacements:
        await_running(vm["vm_id"])
    vms.extend(replacements)
