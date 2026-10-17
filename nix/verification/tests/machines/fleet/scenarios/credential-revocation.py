with subtest("revoked provisioner authority fences the runtime and preserves running guests"):
    custody = host_bindings[l1.name]["host"]
    before = {vm["vm_id"]: process_snapshot(vm) for vm in vms if vm["host_id"] == custody}
    assert before
    operator(m1, dict(action="revoke-host", host_id=custody))
    eventually(
        lambda: sql(f"SELECT reported_at IS NULL FROM compute_hosts WHERE id='{custody}'") == "t"
    )
    l1.wait_until_succeeds("journalctl -u lilly.service --no-pager | grep -q 'unauthorized'")
    l1.succeed("systemctl is-active lilly.service")
    for vm in vms:
        if vm["host_id"] == custody:
            assert process_snapshot(vm) == before[vm["vm_id"]]
    envelope = root + "/replacement-l1-credential.json"
    operator(m1, dict(action="rotate-host", host_id=custody, output=envelope))
    transfer(m1, envelope, l1, root + "/credential.json")
    l1.succeed("fleet-seal-lilly")
    l1.succeed(
        "systemctl stop lilly.service && systemctl restart overalls-secrets-lilly.service && systemctl start lilly.service"
    )
    eventually(fresh_hosts)
    for vm in vms:
        if vm["host_id"] == custody:
            assert process_snapshot(vm) == before[vm["vm_id"]]
