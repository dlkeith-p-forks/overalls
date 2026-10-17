with subtest("actual Lilly release upgrades preserve running guests and authenticated control"):
    before = {vm["vm_id"]: process_snapshot(vm) for vm in vms}
    update_inputs = {machine.name: update_repository(machine) for machine in provisioners}
    for machine in provisioners:
        repo, candidates = update_inputs[machine.name]
        old_release = machine.succeed(
            "systemctl show -p WorkingDirectory --value lilly.service"
        ).strip()
        old_pid = machine.succeed("systemctl show -p MainPID --value lilly.service").strip()
        revision = update_publish(machine, repo, candidates["updated"], "release-upgrade")
        update_success(machine)
        assert update_status(machine)["lastHealthy"]["revision"] == revision
        assert (
            machine.succeed("systemctl show -p WorkingDirectory --value lilly.service").strip()
            != old_release
        )
        assert machine.succeed("systemctl show -p MainPID --value lilly.service").strip() != old_pid
    eventually(fresh_hosts)
    for vm in vms:
        assert process_snapshot(vm) == before[vm["vm_id"]]
    # Reuse the real console-driven packet probes, including successful egress
    # and peer/host denial, after the new BEAM release has adopted the old VMMs.
    for machine in provisioners:
        machine.succeed("fleet-network probe " + shlex.quote(requests[machine.name]), timeout=300)

with subtest(
    "an encrypted credential-only update reconnects without replacing guests or the release"
):
    host_id = host_bindings[l1.name]["host"]
    envelope = root + "/update-l1-credential.json"
    before = {vm["vm_id"]: process_snapshot(vm) for vm in vms}
    old_release = l1.succeed("systemctl show -p WorkingDirectory --value lilly.service").strip()
    old_pid = l1.succeed("systemctl show -p MainPID --value lilly.service").strip()
    operator(m1, dict(action="rotate-host", host_id=host_id, output=envelope))
    transfer(m1, envelope, l1, root + "/credential.json")
    l1.succeed("fleet-seal-lilly")
    repo, candidates = update_inputs[l1.name]
    update_publish(l1, repo, candidates["secret-only"], "credential-delivery")
    update_success(l1)
    assert (
        l1.succeed("systemctl show -p WorkingDirectory --value lilly.service").strip()
        == old_release
    )
    assert l1.succeed("systemctl show -p MainPID --value lilly.service").strip() != old_pid
    eventually(fresh_hosts)
    for vm in vms:
        assert process_snapshot(vm) == before[vm["vm_id"]]
    for machine in provisioners:
        machine.succeed("fleet-network probe " + shlex.quote(requests[machine.name]), timeout=300)
