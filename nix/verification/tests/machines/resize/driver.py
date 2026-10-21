"""Typed bounded resize journey on the fleet's real service and guest topology."""

import ipaddress
import json
import os
import shlex
import subprocess
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from tempfile import TemporaryDirectory

from test_driver.machine import QemuMachine as ResizeMachine

root = "/var/lib/overalls-fleet"
browser_root = "/var/lib/fleet-resize"
marshalls = [m1, m2, m3]
provisioners = [l1, l2]


def object_fields(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    result: dict[str, object] = {}
    for key, field in value.items():
        assert isinstance(key, str)
        result[key] = field
    return result


def string_fields(value: object) -> dict[str, str]:
    result: dict[str, str] = {}
    for key, field in object_fields(value).items():
        assert isinstance(field, str)
        result[key] = field
    return result


def sql(statement: str) -> str:
    return db.succeed(
        "sudo -u postgres psql --no-psqlrc -d marshall -Atc " + shlex.quote(statement)
    ).strip()


def eventually(probe: Callable[[], bool], timeout: int = 180) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if probe():
            return
        time.sleep(1)
    raise AssertionError("Resize fixture condition timed out; private output withheld")


def operator(request: dict[str, object]) -> dict[str, object]:
    with TemporaryDirectory(prefix="resize-private-") as directory:
        path = Path(directory) / "request.json"
        path.write_text(json.dumps(request))
        os.chmod(path, 0o600)
        target = root + "/resize-request.json"
        m1.copy_from_host(str(path), target)
        output = m1.succeed("fleet-op " + target, timeout=180)
        m1.succeed("rm " + target)
    rows = [
        line.removeprefix("FLEET_OK ")
        for line in output.splitlines()
        if line.startswith("FLEET_OK ")
    ]
    assert len(rows) == 1
    parsed: object = json.loads(rows[0])
    return object_fields(parsed)


def current_placement(vm_id: str) -> tuple[ResizeMachine, str]:
    assert str(uuid.UUID(vm_id)) == vm_id
    parsed: object = json.loads(
        sql(
            "SELECT json_build_object('host_id',p.host_id,'placement_id',p.id) FROM compute_virtual_machines v JOIN compute_workload_placements p ON p.id=v.current_placement_id WHERE v.id='"
            + vm_id
            + "'"
        )
    )
    placement = string_fields(parsed)
    placement_id = placement["placement_id"]
    assert str(uuid.UUID(placement_id)) == placement_id
    machine = next(
        host for host in provisioners if host_bindings[host.name]["host"] == placement["host_id"]
    )
    return machine, placement_id


def running(vm_id: str) -> None:
    assert str(uuid.UUID(vm_id)) == vm_id

    def observed() -> bool:
        state = sql(f"SELECT observed_state FROM compute_virtual_machines WHERE id='{vm_id}'")
        assert state != "failed", "Real profile guest failed to start"
        return state == "running"

    eventually(observed, timeout=600)


def workload_identity(vm_id: str) -> str:
    """@cc [owner:ghuntley,label:verification] resize-native-placement-identity
    Identity comparisons MUST read host and pool from the VM's current placement;
    calculated resource attributes MUST NOT be treated as persisted VM columns.
    """
    assert str(uuid.UUID(vm_id)) == vm_id
    return sql(
        "SELECT jsonb_build_array(v.owner_id,v.profile,v.image_id,p.host_id,p.pool_id,v.current_placement_id,v.execution_epoch) "
        "FROM compute_virtual_machines v JOIN compute_workload_placements p ON p.id=v.current_placement_id "
        f"WHERE v.id='{vm_id}'"
    )


def ordinary_accounts() -> None:
    assert (
        sql(
            "SELECT count(*) FROM users WHERE email LIKE 'owner-%' OR email LIKE 'member-%' OR email LIKE 'stranger-%'"
        )
        == "3"
    )
    assert (
        sql(
            "SELECT count(*) FROM users WHERE administrator AND (email LIKE 'owner-%' OR email LIKE 'member-%' OR email LIKE 'stranger-%')"
        )
        == "0"
    )
    assert (
        sql(
            "SELECT count(*) FROM users WHERE administrator AND email='profile-bootstrap@example.test'"
        )
        == "1"
    )


with subtest("boot real fleet with persistent ZFS and nested KVM"):
    for machine in provisioners:
        for member, source in (("primary", "system0"), ("secondary", "system1")):
            subprocess.run(
                [
                    qemu_img,
                    "create",
                    "-f",
                    "qcow2",
                    "-F",
                    "qcow2",
                    "-b",
                    str(Path(storage_images) / (source + ".qcow2")),
                    str(machine.state_dir / ("fleet-" + member + ".qcow2")),
                ],
                check=True,
            )
    start_all()
    db.wait_for_unit("postgresql-setup.service")
    for machine in marshalls + provisioners + [proxy, client]:
        machine.wait_for_unit("network.target")
        machine.succeed("install -d -m 700 " + root)
    for machine in [db, *marshalls, *provisioners, proxy, client, egress]:
        machine.wait_for_unit("chronyd.service")
        if machine != db:
            machine.wait_until_succeeds("chronyc waitsync 1 0.01 0 1", timeout=90)
    for machine in marshalls:
        for filename in ("marshall.env", "ca.crt"):
            transfer(db, root + "/" + filename, machine, root + "/" + filename)
        for filename in ("tls.crt", "tls.key"):
            transfer(db, f"{root}/{machine.name}/{filename}", machine, root + "/" + filename)
    m1.succeed("fleet-op migrate", timeout=180)
    for machine in marshalls:
        machine.succeed("touch " + root + "/ready")
        machine.wait_for_unit("marshall-" + machine.name + ".service")
        machine.wait_until_succeeds(
            f"curl --fail --silent --cacert {root}/ca.crt https://{machine.name}:4443/health/ready",
            timeout=120,
        )
    proxy.succeed("install -d -m 750 -o root -g haproxy /var/lib/overalls-fleet-proxy")
    transfer(db, root + "/proxy/full.pem", proxy, "/var/lib/overalls-fleet-proxy/full.pem")
    transfer(db, root + "/ca.crt", proxy, "/var/lib/overalls-fleet-proxy/ca.crt")
    proxy.succeed(
        "chgrp haproxy /var/lib/overalls-fleet-proxy/* && chmod 640 /var/lib/overalls-fleet-proxy/*"
    )
    proxy.succeed("touch " + root + "/ready")
    proxy.wait_for_unit("haproxy.service")
    transfer(db, root + "/ca.crt", client, root + "/ca.crt")
    client.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt https://control.example.test/health/ready",
        timeout=60,
    )

with subtest("authenticated native observations supply admission capacity"):
    for machine in provisioners:
        machine.wait_for_unit("fleet-storage.service")
        machine.succeed("test -c /dev/kvm")
        observed_value: object = json.loads(machine.succeed("fleet-host-identity"))
        observed = object_fields(observed_value)
        binding = host_bindings[machine.name]
        request: dict[str, object] = dict(
            version=3,
            name=machine.name,
            architecture="x86_64",
            machine_id=observed["machine_id"],
            overhead_cores=1,
            overhead_memory_bytes=1073741824,
            credential_ttl_seconds=7200,
            pools=[
                dict(
                    name="guests",
                    storage=observed["storage"],
                    overhead_bytes=536870912,
                )
            ],
        )
        envelope = root + "/" + machine.name + "-credential.json"
        operator(
            dict(
                action="enroll",
                host_id=binding["host"],
                pool_id=binding["pool"],
                request=request,
                output=envelope,
            )
        )
        transfer(m1, envelope, machine, root + "/credential.json")
        transfer(db, root + "/ca.crt", machine, root + "/ca.crt")
        machine.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
        machine.succeed("fleet-seal-lilly")
        machine.succeed("touch " + root + "/ready")
        machine.wait_for_unit("lilly.service")
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_hosts WHERE inventory->>'execution_ready'='true' AND reported_at > (statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds'"
            )
            == "2"
        ),
        timeout=300,
    )
    for binding in host_bindings.values():
        operator(dict(action="enable", host_id=binding["host"], enabled=True))
    # The installed guest has the real boot trust receiver and guest-account
    # bootstrap. Bring up their existing private-service prerequisites before
    # creating any VM; a base image without that receiver cannot satisfy Lilly.
    for machine in (m2, m3):
        path = root + "/audi-" + machine.name + ".token"
        operator(dict(action="audi-enroll", role="dns", name="audi-" + machine.name, output=path))
        transfer(m1, path, machine, root + "/audi.token")
        machine.wait_for_unit("audi-dns.service")
        machine.wait_for_open_port(53)
    m1.succeed("systemctl start fleet-audi-ca.service")
    m1.wait_for_open_port(14000)
    m1.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt --resolve m1:15000:127.0.0.1 "
        f"https://m1:15000/roots/0 >{root}/audi-root.pem"
    )
    for machine in provisioners:
        binding = host_bindings[machine.name]
        for role in ("ziggy", "galileo"):
            token_path = root + "/" + machine.name + "-" + role + ".token"
            m1.succeed(f"fleet-op {role}-rotate {binding['host']} 7200 {token_path}", timeout=180)
            transfer(m1, token_path, machine, root + "/" + role + ".token")
            machine.succeed("fleet-seal-" + role)
        transfer(m1, root + "/audi-root.pem", machine, "/run/galileo-audi-root.pem")
        machine.succeed("chmod 0444 /run/galileo-audi-root.pem")
        machine.succeed("fleet-seal-audi-private")
        machine.wait_for_unit("ziggy.service")
        machine.wait_for_unit("galileo.service")
        machine.wait_for_unit("audi-private.service")
        address = str(
            ipaddress.IPv4Address(
                client.succeed(
                    "python3 -c "
                    + shlex.quote(
                        "import socket; print(socket.gethostbyname(" + repr(machine.name) + "))"
                    )
                ).strip()
            )
        )
        path = root + "/audi-" + machine.name + ".token"
        operator(
            dict(
                action="audi-enroll",
                role="gateway",
                name="audi-" + machine.name,
                host_id=binding["host"],
                addresses=[address],
                output=path,
            )
        )
        transfer(m1, root + "/audi-root.pem", machine, root + "/audi-root.pem")
        transfer(m1, path, machine, root + "/audi.token")
        machine.wait_for_unit("audi.service")
        machine.wait_for_open_port(22)
    users = operator(dict(action="default-oss-users", output=root + "/users.json"))
    ordinary_accounts()


def check_guest(host: ResizeMachine, placement: str, cpu: int, memory_mib: int, disk: int) -> None:
    assert str(uuid.UUID(placement)) == placement
    # Read the running VMM's API as well as the guest's bounded MemTotal value.
    socket = "/var/lib/lilly/pool/.lilly-jails/firecracker/" + placement + "/root/api.sock"
    host.succeed(
        "curl --fail --silent --unix-socket "
        + shlex.quote(socket)
        + " http://localhost/machine-config | jq -e "
        + shlex.quote(f".vcpu_count == {cpu} and .mem_size_mib == {memory_mib}")
        + " >/dev/null"
    )
    host.succeed(f"fleet-resize-guest check {placement} {cpu} {disk}", timeout=180)


def browser_signal(name: str) -> None:
    def ready() -> bool:
        status, _ = client.execute("test -e " + browser_root + "/" + name + ".ready")
        if status == 0:
            return True
        alive, _ = client.execute("systemctl is-active --quiet resize-browser-fixture.service")
        if alive != 0:
            # The browser projects failures into a closed stage/category record.
            client.succeed("cat " + browser_root + "/browser.log")
            raise AssertionError("Resize browser exited before checkpoint")
        return False

    eventually(ready, timeout=600)


def resume_browser(name: str) -> None:
    client.succeed("touch " + browser_root + "/" + name + ".go")


def durable_inventory(vm_id: str) -> str:
    assert str(uuid.UUID(vm_id)) == vm_id
    # Reports and observation timestamps keep changing; compare only user intent,
    # immutable commands/receipts and allocation rows after convergence.
    return sql(
        "SELECT jsonb_build_object("
        "'requests',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM compute_resize_requests r),"
        "'operations',(SELECT jsonb_agg(to_jsonb(o) ORDER BY id) FROM compute_operations o),"
        "'reservations',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM compute_reservations r),"
        "'addresses',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM compute_network_addresses a),"
        "'audit',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM admin_audit_events a),"
        "'intent',(SELECT jsonb_build_array(generation,vcpu,memory_bytes,disk_bytes,desired_state,current_placement_id,owner_id,profile,image_id) "
        f"FROM compute_virtual_machines WHERE id='{vm_id}'))"
    )


def lifecycle(vm_id: str, kind: str) -> None:
    assert operator(
        dict(
            action="lifecycle",
            owner_id=users["owner_id"],
            vm_id=vm_id,
            kind=kind,
            key=str(uuid.uuid4()),
        )
    ) == {"requested": True}


with subtest("ordinary browser owner creates the guest through verified HTTPS"):
    client.succeed(
        "install -d -m 700 -o tester -g users " + browser_root + " /home/tester/.pki/nssdb"
    )
    client.succeed("sudo -u tester certutil -N -d sql:/home/tester/.pki/nssdb --empty-password")
    client.succeed(f"install -m 644 {root}/ca.crt {browser_root}/ca.crt")
    client.succeed(
        f"sudo -u tester certutil -A -d sql:/home/tester/.pki/nssdb -n resize-root -t 'C,,' -i {browser_root}/ca.crt"
    )
    transfer(m1, root + "/users.json", client, browser_root + "/users.json")
    client.succeed(
        f"chown tester:users {browser_root}/users.json && chmod 600 {browser_root}/users.json"
    )
    client.succeed(
        "systemd-run --unit=resize-browser-fixture --property=User=tester --setenv=HOME=/home/tester --setenv=PATH=/run/current-system/sw/bin /bin/sh -c "
        + shlex.quote("fleet-resize-browser >" + browser_root + "/browser.log 2>&1")
    )
    browser_signal("created")
    vm_id = client.succeed("cat " + browser_root + "/vm-id").strip()
    assert str(uuid.UUID(vm_id)) == vm_id
    running(vm_id)
    ordinary_accounts()
    host, placement = current_placement(vm_id)
    original_identity = workload_identity(vm_id)
    host.succeed(f"fleet-resize-guest seed {placement} 1 5368709120", timeout=180)
    check_guest(host, placement, 1, 512, 5368709120)
    resume_browser("created")

with subtest("running browser resize retains exact block length, guest data and workload identity"):
    browser_signal("resized")
    running(vm_id)
    assert (
        sql(
            f"SELECT vcpu::text || ':' || memory_bytes::text || ':' || disk_bytes::text FROM compute_virtual_machines WHERE id='{vm_id}'"
        )
        == "2:805306368:5368713216"
    )
    assert workload_identity(vm_id) == original_identity
    assert current_placement(vm_id) == (host, placement)
    check_guest(host, placement, 2, 768, 5368713216)
    # Wait for accepted coverage to settle startup holds before comparing rows.
    eventually(
        lambda: (
            sql(f"SELECT startup_compute_held FROM compute_reservations WHERE vm_id='{vm_id}'")
            == "f"
        )
    )
    before_refusal = durable_inventory(vm_id)
    resume_browser("resized")
    browser_signal("refused")
    assert durable_inventory(vm_id) == before_refusal
    assert sql("SELECT count(*) FROM compute_resize_requests") == "1"
    lifecycle(vm_id, "stop")
    eventually(
        lambda: (
            sql(f"SELECT observed_state FROM compute_virtual_machines WHERE id='{vm_id}'")
            == "stopped"
        )
    )
    resume_browser("refused")

with subtest("stopped browser resize keeps the guest stopped and data survives its later boot"):
    browser_signal("stopped")
    assert (
        sql(
            f"SELECT desired_state::text || ':' || observed_state::text FROM compute_virtual_machines WHERE id='{vm_id}'"
        )
        == "stopped:stopped"
    )
    assert (
        sql(
            "SELECT count(*) FROM compute_resize_requests WHERE phase='complete' AND finished_at IS NOT NULL"
        )
        == "2"
    )
    assert (
        sql(
            f"SELECT compute_held::text || ':' || pending_disk_bytes::text FROM compute_reservations WHERE vm_id='{vm_id}'"
        )
        == "false:0"
    )
    host.fail("systemctl is-active --quiet lilly-vm-" + placement + ".service")
    assert workload_identity(vm_id) == original_identity
    resume_browser("stopped")
    client.wait_until_succeeds("test -e " + browser_root + "/done", timeout=90)
    client.wait_until_succeeds(
        'test "$(systemctl show resize-browser-fixture.service -p SubState --value)" = dead'
    )
    client.succeed(
        'test "$(systemctl show resize-browser-fixture.service -p ExecMainStatus --value)" = 0'
    )
    ordinary_accounts()
    lifecycle(vm_id, "start")
    running(vm_id)
    check_guest(host, placement, 1, 512, 6442450944)
    assert sql("SELECT count(*) FROM compute_virtual_machines") == "1"
