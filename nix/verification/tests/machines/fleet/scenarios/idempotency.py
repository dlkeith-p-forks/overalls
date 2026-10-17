with subtest("three Marshall machines converge on one idempotent real VM"):
    request = provision("customer")
    results = synchronized([request, request, request])
    if not all(result["accepted"] for result in results):
        print(
            sql_json(
                "SELECT json_agg(json_build_object('enabled',enabled,"
                "'cores',effective_cores,'memory',effective_memory_bytes,'inventory',inventory,"
                "'age',extract(epoch FROM clock_timestamp() - reported_at))) FROM compute_hosts"
            )
        )
        print(
            sql_json(
                "SELECT json_agg(json_build_object('free',free_bytes,'total',total_bytes,"
                "'overhead',overhead_bytes,"
                "'age',extract(epoch FROM clock_timestamp() - reported_at))) FROM compute_storage_pools"
            )
        )
    assert all(result["accepted"] for result in results), ("Admission rejected", results)
    assert len({result["vm_id"] for result in results}) == 1, ("Idempotency diverged", results)
    first = str(results[0]["vm_id"])
    await_running(first)
    assert sql(f"SELECT count(*) FROM compute_reservations WHERE vm_id='{first}'") == "1"
    assert (
        sql(f"SELECT count(*) FROM compute_operations WHERE vm_id='{first}' AND kind='provision'")
        == "1"
    )
