with subtest("failed ZFS collection withholds its pools while host telemetry stays fresh"):
    for machine in provisioners:
        machine.succeed(f"zfs set compression=off {shlex.quote(storage_dataset)}")
    try:
        eventually(
            lambda: (
                sql(
                    "SELECT count(*) FROM compute_storage_pools WHERE reported_at IS NULL "
                    "AND allocations='{}'::jsonb AND storage_observation='{}'::jsonb"
                )
                == "2"
            )
        )
        assert fresh_hosts()
        assert not operator(m3, provision("customer"))["accepted"]
        for machine in provisioners:
            machine.succeed("systemctl is-active lilly.service")
    finally:
        for machine in provisioners:
            machine.succeed(f"zfs set compression=lz4 {shlex.quote(storage_dataset)}")
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_storage_pools WHERE reported_at > "
                "(statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds'"
            )
            == "2"
        )
    )
    eventually(fresh_hosts)

with subtest("missing guest images deny admission while native capacity remains fresh"):
    for machine in provisioners:
        machine.succeed("mkdir -p /run/fleet-empty-image")
        machine.succeed(f"mount --bind /run/fleet-empty-image {shlex.quote(guest_image)}")
    try:
        eventually(
            lambda: (
                sql("SELECT count(*) FROM compute_hosts WHERE inventory->'images'='[]'::jsonb")
                == "2"
            )
        )
        assert fresh_hosts()
        assert not operator(m3, provision("customer"))["accepted"]
    finally:
        for machine in provisioners:
            machine.succeed(f"umount {shlex.quote(guest_image)}")
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_hosts WHERE jsonb_array_length(inventory->'images')=1"
            )
            == "2"
        )
    )
    eventually(fresh_hosts)
