with subtest("Marshall machine loss and database outage retain physical guests"):
    before = {vm["vm_id"]: process_snapshot(vm) for vm in vms}
    m1.crash()
    client.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt https://control.example.test/health/ready"
    )
    eventually(fresh_hosts)
    assert (
        sql("SELECT count(*) FROM compute_virtual_machines WHERE observed_state='running'") == "6"
    )
    m1.start()
    m1.wait_for_unit("marshall-m1.service")
    m1.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt https://m1:4443/health/ready"
    )
    db.succeed("systemctl stop postgresql.service")
    client.wait_until_succeeds(
        f"test $(curl --silent --cacert {root}/ca.crt https://control.example.test/health/ready -o /dev/null -w '%{{http_code}}') = 503"
    )
    for vm in vms:
        assert process_snapshot(vm) == before[vm["vm_id"]]
    db.succeed("systemctl start postgresql.service")
    client.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt https://control.example.test/health/ready",
        timeout=120,
    )
    eventually(fresh_hosts)
