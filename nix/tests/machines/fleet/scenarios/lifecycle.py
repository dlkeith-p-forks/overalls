def assert_lifecycle_audit(vm: str, owner: str) -> None:
    """@cc [owner:ghuntley,label:verification;observability] lifecycle-independent-diagnostics
    Each deleted fresh-fixture VM MUST retain its initiating user's deletion
    intent and the system's accepted deleted observation, with exact VM identity.
    It MUST NOT ingest provisioner diagnostics. Native cleanup assertions remain
    required before this audit check.
    """
    assert str(uuid.UUID(vm)) == vm
    assert str(uuid.UUID(owner)) == owner
    assert (
        sql(
            "SELECT count(*) FROM compute_lifecycle_events "
            f"WHERE vm_id='{vm}' AND actor_kind='provisioner'"
        )
        == "0"
    )
    assert (
        sql(
            "SELECT EXISTS(SELECT 1 FROM compute_lifecycle_events "
            f"WHERE vm_id='{vm}' AND resource_type='VirtualMachine' "
            f"AND resource_id='{vm}' AND actor_kind='user' AND actor_id='{owner}' "
            "AND action='request_delete' AND next_state='deleted')"
        )
        == "t"
    )
    assert (
        sql(
            "SELECT EXISTS(SELECT 1 FROM compute_lifecycle_events "
            f"WHERE vm_id='{vm}' AND resource_type='VirtualMachine' "
            f"AND resource_id='{vm}' AND actor_kind='system' "
            "AND action='observe' AND next_state='deleted')"
        )
        == "t"
    )


with subtest("stopping retains disk identity and only confirmed deletion releases storage"):
    victim = vms[-1]
    vm_id = victim["vm_id"]
    placement_id = victim["placement_id"]
    assert isinstance(vm_id, str) and isinstance(placement_id, str)
    lifecycle_vm_id = vm_id
    machine = host_for(victim)
    child = f"zroot/lilly/vm-{placement_id}"
    original_guid = machine.succeed(f"zfs get -Hp -o value guid {child}").strip()
    lifecycle(vm_id, "stop")
    eventually(lambda: vm_state(lifecycle_vm_id) == "stopped")
    assert (
        sql(
            f"SELECT compute_held::text || ':' || disk_held::text FROM compute_reservations WHERE vm_id='{vm_id}'"
        )
        == "false:true"
    )
    machine.fail(f"systemctl is-active lilly-vm-{placement_id}.service")
    assert machine.succeed(f"zfs get -Hp -o value guid {child}").strip() == original_guid
    # Retained ownership does not restore a settled virtual disk startup hold.
    assert sql(f"SELECT startup_disk_held FROM compute_reservations WHERE vm_id='{vm_id}'") == "f"
    lifecycle(vm_id, "start")
    await_running(vm_id)
    assert machine.succeed(f"zfs get -Hp -o value guid {child}").strip() == original_guid
    victims = [next(vm for vm in vms if host_for(vm) is host) for host in provisioners]
    survivors = [vm for vm in vms if vm not in victims]
    before_delete = {vm["vm_id"]: process_snapshot(vm) for vm in survivors}
    for victim in victims:
        vm_id = victim["vm_id"]
        placement_id = victim["placement_id"]
        assert isinstance(vm_id, str) and isinstance(placement_id, str)
        lifecycle(vm_id, "delete")
        eventually(
            lambda vm_id=vm_id: (
                sql(
                    f"SELECT archived_at IS NOT NULL FROM compute_virtual_machines WHERE id='{vm_id}'"
                )
                == "t"
            )
        )
        assert (
            sql(
                f"SELECT compute_held::text || ':' || disk_held::text FROM compute_reservations WHERE vm_id='{vm_id}'"
            )
            == "false:false"
        )
        machine = host_for(victim)
        machine.fail(
            f"systemctl is-active lilly-vm-{placement_id}.service",
            f"zfs list zroot/lilly/vm-{placement_id}",
            f"test -e /var/lib/lilly/pool/vms/{placement_id}/rootfs.ext4",
        )
        eventually(
            lambda placement_id=placement_id, victim=victim: (
                sql(
                    f"SELECT NOT (allocations ? '{placement_id}') FROM compute_storage_pools WHERE host_id='{victim['host_id']}'"
                )
                == "t"
            )
        )
        vms.remove(victim)
    for vm in survivors:
        assert process_snapshot(vm) == before_delete[vm["vm_id"]]

with subtest("durable lifecycle audit retains human intent and accepted physical outcomes"):
    for victim in victims:
        assert_lifecycle_audit(victim["vm_id"], str(users["owner_id"]))
