"""Prove memory continuation through the production control and native VM path."""


def assert_suspended(copy: PlacementRef) -> None:
    """@cc [owner:ghuntley,label:verification] suspended-native-compute-absence
    The real production VM service MUST be inactive and every descendant cgroup
    MUST be empty while the durable control plane reports paused. Lifecycle
    observations alone MUST NOT establish released native execution capacity.
    """
    machine = host_for(copy)
    placement = copy["placement_id"]
    machine.fail("systemctl is-active lilly-vm-" + placement + ".service")
    group = "/sys/fs/cgroup/lilly.slice/lilly-vm-" + placement + ".service"
    program = (
        "from pathlib import Path; p=Path(" + repr(group) + "); "
        "assert all(not f.read_text().strip() for f in p.rglob('cgroup.procs'))"
    )
    machine.succeed("python3 -c " + shlex.quote(program))


with subtest("pause releases execution and resume preserves RAM, PID and boot UUID"):
    suspension_vm = str(vm["vm_id"])
    await_running(suspension_vm)
    original = current_copy(suspension_vm)
    guest_assertion(original, "memory-prepare")
    for _cycle in range(2):
        lifecycle(suspension_vm, "pause")
        eventually(lambda: vm_state(suspension_vm) == "paused", timeout=600)
        assert_suspended(original)
        lifecycle(suspension_vm, "resume")
        await_running(suspension_vm)
        assert current_copy(suspension_vm) == original
        guest_assertion(original, "memory-verify")

with subtest("provisioner restart retains paused RAM and adopts one restored execution"):
    lifecycle(suspension_vm, "pause")
    eventually(lambda: vm_state(suspension_vm) == "paused", timeout=600)
    source = host_for(original)
    source.succeed("systemctl restart lilly.service")
    eventually(fresh_hosts, timeout=180)
    assert vm_state(suspension_vm) == "paused"
    assert_suspended(original)
    lifecycle(suspension_vm, "resume")
    await_running(suspension_vm)
    guest_assertion(original, "memory-verify")
    resumed_processes = process_snapshot(original)
    source.succeed("systemctl restart lilly.service")
    eventually(fresh_hosts, timeout=180)
    await_running(suspension_vm)
    assert process_snapshot(original) == resumed_processes
    guest_assertion(original, "memory-verify")


with subtest("interrupted restored VMM resumes the exact paused native process"):
    # @cc [owner:ghuntley,label:verification;recovery] restored-paused-live-recovery
    # The fixture MAY pause the current restored VMM through its private API
    # without changing durable command/checkpoint evidence. Provisioner restart
    # MUST resume that exact PID/start-time and preserve guest RAM; launching a
    # replacement VMM or loading the consumed snapshot again MUST NOT pass.
    api_socket = (
        "/var/lib/lilly/pool/.lilly-jails/firecracker/"
        + original["placement_id"]
        + "/root/api.sock"
    )
    api_curl = "curl --fail --silent --unix-socket " + shlex.quote(api_socket)
    recovery_processes = process_snapshot(original)
    source.succeed("systemctl stop lilly.service")
    assert process_snapshot(original) == recovery_processes
    source.succeed(
        api_curl
        + " --request PATCH --header 'Content-Type: application/json'"
        + ' --data \'{"state":"Paused"}\' http://localhost/vm'
    )
    source.succeed(api_curl + " http://localhost/ | jq -e '.state == \"Paused\"'")
    source.succeed("systemctl start lilly.service")
    source.wait_until_succeeds(
        api_curl + " http://localhost/ | jq -e '.state == \"Running\"'", timeout=300
    )
    eventually(fresh_hosts, timeout=180)
    assert process_snapshot(original) == recovery_processes
    guest_assertion(original, "memory-verify")


with subtest("running relocation resumes the same process memory on a new host"):
    # @cc [owner:ghuntley,label:verification;isolation] relocation-global-address-continuity
    # A real neighboring destination workload MUST retain its distinct global
    # slot while the relocated VM keeps its original slot and guest memory.
    # Host enablement MAY direct ordinary admission, never fabricate placement.
    source_host_id = original["host_id"]
    operator(m1, dict(action="enable", host_id=source_host_id, enabled=False))
    try:
        neighbor = provision_when_available(m1, "standard")
        neighbor_vm = str(neighbor["vm_id"])
        await_running(neighbor_vm)
        neighbor_copy = current_copy(neighbor_vm)
        assert neighbor_copy["host_id"] != source_host_id
        assert neighbor_copy["slot"] != original["slot"]
        guest_assertion(neighbor_copy, "memory-prepare")
        lifecycle(neighbor_vm, "stop")
        eventually(lambda: vm_state(neighbor_vm) == "stopped", timeout=600)
    finally:
        operator(m1, dict(action="enable", host_id=source_host_id, enabled=True))
    move = relocate(suspension_vm)
    moved = await_relocation(move)
    assert moved["host_id"] != original["host_id"]
    assert moved["slot"] == original["slot"]
    assert moved["host_id"] == neighbor_copy["host_id"]
    assert moved["slot"] != neighbor_copy["slot"]
    guest_assertion(moved, "memory-verify")
    assert vm_state(neighbor_vm) == "stopped"
    lifecycle(neighbor_vm, "delete")
    eventually(lambda: vm_state(neighbor_vm) == "deleted", timeout=600)

with subtest("moving an already paused VM preserves pause until an explicit wake"):
    lifecycle(suspension_vm, "pause")
    eventually(lambda: vm_state(suspension_vm) == "paused", timeout=600)
    assert_suspended(moved)
    paused_move = relocate(suspension_vm)
    paused_destination = await_relocation(paused_move, expected_state="paused")
    assert_suspended(paused_destination)
    lifecycle(suspension_vm, "resume")
    await_running(suspension_vm)
    guest_assertion(paused_destination, "memory-verify")


with subtest(
    "original SSH, HTTPS and editor connections wait through fleet exhaustion and automatic move"
):
    # @cc [owner:ghuntley,label:verification;security] wake-original-network-waiters
    # All requests MUST start against the old gateway before destination
    # memory headroom returns, remain pending while no host can admit execution,
    # and finish without client retries after automatic relocation. HTTPS MUST
    # retain verified TLS and SSH MUST retain the registered per-user key.
    operator(
        m1,
        dict(
            action="audi-policy",
            owner_id=users["owner_id"],
            vm_id=suspension_vm,
            visibility="public",
        ),
    )
    sleeping = current_copy(suspension_vm)
    source = host_for(sleeping)
    other_host = next(machine for machine in provisioners if machine.name != source.name)
    old_address = client.succeed(
        "python3 -c "
        + shlex.quote("import socket;print(socket.gethostbyname(" + repr(source.name) + "))")
    ).strip()
    editor_private = root + "/suspension-editor-cookie.json"
    operator(
        m1,
        dict(
            action="suspension-editor-cookie",
            owner_id=users["owner_id"],
            vm_id=suspension_vm,
            gateway=source.name,
            output=editor_private,
        ),
    )
    transfer(m1, editor_private, client, editor_private)
    editor_config = (
        "import json,os; from pathlib import Path; "
        + "value: object=json.loads(Path("
        + repr(editor_private)
        + ").read_text()); "
        + "assert isinstance(value,dict); hostname=value.get('hostname'); cookie=value.get('cookie'); "
        + "assert isinstance(hostname,str) and isinstance(cookie,str); "
        + "fields={'url':'https://'+hostname+'/', 'cacert':"
        + repr(root + "/audi-root.pem")
        + ", 'header':'Cookie: __Host-audi_editor_session='+cookie, "
        + "'resolve':hostname+':443:' + "
        + repr(old_address)
        + "}; "
        + "fd=os.open('/run/suspension-editor-curl.conf',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); "
        + "stream=os.fdopen(fd,'w'); stream.write(''.join(key+' = '+json.dumps(value)+'\\n' "
        + "for key,value in fields.items())); stream.close()"
    )
    client.succeed("python3 -c " + shlex.quote(editor_config))
    editor_curl = (
        "curl --fail --silent --show-error --config /run/suspension-editor-curl.conf "
        "--output /run/suspension-editor-body --write-out '%{http_code}'"
    )
    client.wait_until_succeeds(
        editor_curl
        + " > /run/suspension-editor-baseline && grep -qx 200 /run/suspension-editor-baseline",
        timeout=180,
    )
    lifecycle(suspension_vm, "pause")
    eventually(lambda: vm_state(suspension_vm) == "paused", timeout=600)
    assert_suspended(sleeping)
    pressure = (
        "from pathlib import Path; import time; memory=bytearray("
        + str(fixture_guest_memory_bytes - 256 * 1024 * 1024)
        + "); memory[::4096]=b'x'*(len(memory)//4096); "
        + "Path('/run/suspension-pressure-ready').touch(); time.sleep(3600)"
    )
    for pressure_host in provisioners:
        pressure_host.succeed(
            "systemd-run --quiet --no-block --unit=suspension-memory-pressure "
            "--slice=lilly.slice --property=Type=exec python3 -c " + shlex.quote(pressure)
        )
        pressure_host.wait_until_succeeds("test -f /run/suspension-pressure-ready")
    eventually(
        lambda: all(
            sql(
                "SELECT (capacity->>'memory_headroom_bytes')::bigint < "
                "(SELECT memory_bytes FROM compute_reservations WHERE placement_id='"
                + sleeping["placement_id"]
                + "') FROM compute_hosts WHERE id='"
                + host_bindings[pressure_host.name]["host"]
                + "'"
            )
            == "t"
            for pressure_host in provisioners
        )
    )
    held_ssh_arguments = [
        "ConnectTimeout=1800" if argument == "ConnectTimeout=10" else argument
        for argument in ssh_arguments
    ]
    ssh_request = (
        ssh_environment
        + shlex.join(
            [
                *held_ssh_arguments,
                "curl --fail --silent http://127.0.0.1:18765/ | cmp - /run/memory-continuation.expected && printf 'continued\\n'",
            ]
        )
        + " > /run/suspension-ssh-result"
    )
    http_request = (
        shlex.join(
            [
                "curl",
                "--fail",
                "--silent",
                "--show-error",
                "--cacert",
                root + "/audi-root.pem",
                "--resolve",
                hostname + ":443:" + old_address,
                "https://" + hostname + "/",
            ]
        )
        + " > /run/suspension-http-result"
    )
    editor_request = editor_curl + " > /run/suspension-editor-result"
    for name, request in (("ssh", ssh_request), ("http", http_request), ("editor", editor_request)):
        client.succeed(
            "systemd-run --quiet --no-block --unit=suspension-wait-"
            + name
            + " --property=Type=oneshot --property=RemainAfterExit=yes sh -c "
            + shlex.quote(request)
        )
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_wake_requests WHERE vm_id='"
                + suspension_vm
                + "' AND finished_at IS NULL"
            )
            == "1"
        ),
        timeout=60,
    )
    # A single request owns each connection; a disconnected socket cannot pass
    # by reconnecting after capacity becomes available.
    for _observation in range(3):
        for name in ("ssh", "http", "editor"):
            assert (
                client.succeed(
                    "systemctl show suspension-wait-" + name + ".service -p ActiveState --value"
                ).strip()
                == "activating"
            )
        assert vm_state(suspension_vm) == "paused"
        time.sleep(5)
    other_host.succeed("systemctl stop suspension-memory-pressure.service")
    await_running(suspension_vm)
    awake = current_copy(suspension_vm)
    assert awake["host_id"] == host_bindings[other_host.name]["host"]
    assert awake["host_id"] != sleeping["host_id"]
    for name, expected in (("ssh", "continued"), ("http", "audi-guest"), ("editor", "200")):
        client.wait_for_unit("suspension-wait-" + name + ".service", timeout=1800)
        assert (
            client.succeed(
                "systemctl show suspension-wait-" + name + ".service -p ExecMainStatus --value"
            ).strip()
            == "0"
        )
        assert client.succeed("cat /run/suspension-" + name + "-result").strip() == expected
    guest_assertion(awake, "memory-verify")
    source.succeed("systemctl stop suspension-memory-pressure.service")


with subtest("idle scanner uses four hours and real pause/resume execution"):
    current = current_copy(suspension_vm)
    before_deadline = operator(
        m1,
        dict(
            action="suspension-idle",
            owner_id=users["owner_id"],
            vm_id=suspension_vm,
            age_seconds=10800,
        ),
    )
    assert before_deadline["result"] == "deferred"
    assert vm_state(suspension_vm) == "running"
    after_deadline = operator(
        m1,
        dict(
            action="suspension-idle",
            owner_id=users["owner_id"],
            vm_id=suspension_vm,
            age_seconds=14401,
        ),
    )
    assert after_deadline["result"] == "paused"
    eventually(lambda: vm_state(suspension_vm) == "paused", timeout=600)
    assert_suspended(current)
    lifecycle(suspension_vm, "resume")
    await_running(suspension_vm)
    guest_assertion(current_copy(suspension_vm), "memory-verify")


with subtest("missing and corrupt checkpoints refuse execution without a cold boot"):
    # @cc [owner:ghuntley,label:verification;recovery] checkpoint-corruption-no-cold-boot
    # Only physical bytes of disposable paused checkpoints MAY be faulted. A
    # completed refused resume MUST leave the native cgroup empty and MUST NOT
    # create a start operation. Database observations MUST remain genuine.
    for fault in ("missing", "corrupt"):
        damaged = provision_when_available(m1, "customer")
        damaged_vm = str(damaged["vm_id"])
        await_running(damaged_vm)
        damaged_copy = current_copy(damaged_vm)
        lifecycle(damaged_vm, "pause")
        eventually(lambda damaged_vm=damaged_vm: vm_state(damaged_vm) == "paused", timeout=600)
        damaged_host = host_for(damaged_copy)
        checkpoint_root = "/var/lib/lilly/pool/.lilly-checkpoints/" + damaged_copy["placement_id"]
        discover = (
            "from pathlib import Path; root=Path(" + repr(checkpoint_root) + "); "
            "slots=[slot for slot in ('a','b') if (root/slot/'output'/'memory').is_file()]; "
            "assert len(slots)==1; print(slots[0])"
        )
        slot = damaged_host.succeed("python3 -c " + shlex.quote(discover)).strip()
        assert slot in ("a", "b")
        dataset = storage_dataset + "/checkpoint-" + damaged_copy["placement_id"] + "-" + slot
        damaged_host.succeed("zfs set readonly=off " + shlex.quote(dataset))
        memory = checkpoint_root + "/" + slot + "/output/memory"
        mutation = (
            "from pathlib import Path; memory=Path("
            + repr(memory)
            + "); "
            + ("memory.unlink()" if fault == "missing" else "memory.write_bytes(b'corrupt')")
        )
        damaged_host.succeed("python3 -c " + shlex.quote(mutation))
        damaged_host.succeed("zfs set readonly=on " + shlex.quote(dataset))
        lifecycle(damaged_vm, "resume")
        eventually(
            lambda damaged_vm=damaged_vm: (
                sql(
                    "SELECT EXISTS(SELECT 1 FROM compute_operations o JOIN compute_physical_outcomes p "
                    "ON p.id=o.completion_outcome_id WHERE o.vm_id='" + damaged_vm + "' "
                    "AND o.kind='resume' AND o.status='completed' "
                    "AND p.observation->>'state' IN ('failed','unknown'))"
                )
                == "t"
            ),
            timeout=600,
        )
        assert_suspended(damaged_copy)
        assert (
            sql(
                "SELECT count(*) FROM compute_operations WHERE vm_id='"
                + damaged_vm
                + "' AND kind='start'"
            )
            == "0"
        )
        lifecycle(damaged_vm, "delete")
        eventually(lambda damaged_vm=damaged_vm: vm_state(damaged_vm) == "deleted", timeout=600)


with subtest("newer stop and delete discard only the interrupted confined paused VMM"):
    # @cc [owner:ghuntley,label:verification;recovery] interrupted-capture-terminal-cleanup
    # Real capturing journal plus a native Paused VMM MUST NOT imply a copied
    # checkpoint. Explicit newer stop/delete MUST empty its exact cgroup without
    # starting a replacement VMM or publishing a continuation.
    for terminal_kind in ("stop", "delete"):
        interrupted = provision_when_available(m1, "customer")
        interrupted_vm = str(interrupted["vm_id"])
        await_running(interrupted_vm)
        interrupted_copy = current_copy(interrupted_vm)
        interrupted_host = host_for(interrupted_copy)
        guest_assertion(interrupted_copy, "memory-prepare")
        native_before_capture = process_snapshot(interrupted_copy)
        interrupted_host.succeed("systemctl stop lilly.service")
        try:
            lifecycle(interrupted_vm, "pause")
            capture_generation = int(
                sql(
                    "SELECT generation FROM compute_virtual_machines WHERE id='"
                    + interrupted_vm
                    + "'"
                )
            )
            capture_revision = str(interrupted_copy["epoch"]) + ":" + str(capture_generation)
            interrupted_host.succeed(
                "fleet-relocation-guest interrupted-capture "
                + shlex.quote(interrupted_copy["placement_id"])
                + " "
                + shlex.quote(capture_revision),
                timeout=300,
            )
            assert process_snapshot(interrupted_copy) == native_before_capture
            lifecycle(interrupted_vm, terminal_kind)
            terminal_generation = int(
                sql(
                    "SELECT generation FROM compute_virtual_machines WHERE id='"
                    + interrupted_vm
                    + "'"
                )
            )
            assert terminal_generation > capture_generation
        finally:
            interrupted_host.succeed("systemctl start lilly.service")
        terminal_state = "stopped" if terminal_kind == "stop" else "deleted"
        eventually(
            lambda interrupted_vm=interrupted_vm, terminal_state=terminal_state: (
                vm_state(interrupted_vm) == terminal_state
            ),
            timeout=600,
        )
        assert_suspended(interrupted_copy)
        absent_checkpoints = (
            "from pathlib import Path; root=Path("
            + repr("/var/lib/lilly/pool/.lilly-checkpoints/" + interrupted_copy["placement_id"])
            + "); assert not any(p.name in ('memory','state') for p in root.rglob('*'))"
        )
        interrupted_host.succeed("python3 -c " + shlex.quote(absent_checkpoints))
        assert (
            sql(
                "SELECT count(*) FROM compute_operations WHERE vm_id='"
                + interrupted_vm
                + "' AND kind IN ('start','resume')"
            )
            == "0"
        )
        assert (
            sql(
                "SELECT count(*) FROM compute_operations o JOIN compute_physical_outcomes p "
                "ON p.id=o.completion_outcome_id WHERE o.vm_id='"
                + interrupted_vm
                + "' AND p.observation->'checkpoint' IS NOT NULL "
                "AND p.observation->'checkpoint' <> 'null'::jsonb"
            )
            == "0"
        )
        if terminal_kind == "stop":
            lifecycle(interrupted_vm, "delete")
            eventually(
                lambda interrupted_vm=interrupted_vm: vm_state(interrupted_vm) == "deleted",
                timeout=600,
            )
