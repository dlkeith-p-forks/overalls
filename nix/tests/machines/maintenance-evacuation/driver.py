"""Typed two-Lilly user-operated evacuation journey on source-built services."""

import base64
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
from typing import TypedDict

from test_driver.machine import QemuMachine as EvacuationMachine

root = "/var/lib/overalls-fleet"
browser_root = "/var/lib/fleet-evacuation"
marshalls = [m1, m2, m3]
provisioners = [l1, l2]


class TransferEndpoint(TypedDict):
    address: str
    port: int
    host_key: str


def transfer_endpoint(machine: EvacuationMachine, address: str) -> TransferEndpoint:
    """@cc [owner:ghuntley,label:verification;security] evacuation-enrolled-transfer-identity
    Enrollment MUST pin the actual host's Ed25519 public key and configured IPv4
    transfer listener after its service starts. Persisted endpoints MUST equal
    those pins; missing identity MUST fail setup without bypassing admission.
    """
    assert str(ipaddress.IPv4Address(address)) == address
    assert "inet " + address + "/24" in machine.succeed("ip -4 -o address show dev eth2")
    machine.wait_for_unit("lilly-transfer-sshd.service")
    machine.wait_for_open_port(2223)
    public = machine.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").split()
    assert len(public) >= 2 and public[0] == "ssh-ed25519"
    blob = base64.b64decode(public[1], validate=True)
    assert len(blob) == 51 and blob[:19] == b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
    assert base64.b64encode(blob).decode("ascii") == public[1]
    return {"address": address, "port": 2223, "host_key": " ".join(public[:2])}


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
    raise AssertionError("Evacuation fixture condition timed out; private output withheld")


def operator(request: dict[str, object]) -> dict[str, object]:
    with TemporaryDirectory(prefix="evacuation-private-") as directory:
        path = Path(directory) / "request.json"
        path.write_text(json.dumps(request))
        os.chmod(path, 0o600)
        target = root + "/evacuation-request.json"
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


def current_placement(vm_id: str) -> tuple[EvacuationMachine, str]:
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
        endpoint = transfer_endpoint(machine, binding["ip"])
        request: dict[str, object] = dict(
            version=3,
            name=machine.name,
            architecture="x86_64",
            machine_id=observed["machine_id"],
            overhead_cores=1,
            overhead_memory_bytes=1073741824,
            credential_ttl_seconds=7200,
            transfer_endpoint=endpoint,
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
        host_id = str(uuid.UUID(binding["host"]))
        persisted: object = json.loads(
            sql(f"SELECT transfer_endpoint::text FROM compute_hosts WHERE id='{host_id}'")
        )
        assert object_fields(persisted) == endpoint
        transfer(m1, envelope, machine, root + "/credential.json")
        transfer(db, root + "/ca.crt", machine, root + "/ca.crt")
        machine.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
        machine.succeed("fleet-seal-lilly")
        machine.succeed("touch " + root + "/ready")
        machine.wait_for_unit("lilly.service")
    for machine in provisioners:
        peer = l2 if machine is l1 else l1
        peer_ip = str(ipaddress.IPv4Address(host_bindings[peer.name]["ip"]))
        machine.wait_until_succeeds(
            "python3 -c "
            + shlex.quote(
                "import socket; socket.create_connection((" + repr(peer_ip) + ", 2223), 5).close()"
            ),
            timeout=30,
        )
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


def lifecycle(vm_id: str, kind: str) -> None:
    assert str(uuid.UUID(vm_id)) == vm_id
    assert kind in {"start", "stop"}
    assert operator(
        dict(
            action="lifecycle",
            owner_id=users["owner_id"],
            vm_id=vm_id,
            kind=kind,
            key=str(uuid.uuid4()),
        )
    ) == {"requested": True}


def signal(name: str) -> None:
    def ready() -> bool:
        if client.execute("test -e " + browser_root + "/" + name + ".ready")[0] == 0:
            return True
        if client.execute("systemctl is-active --quiet evacuation-browser-fixture.service")[0] != 0:
            client.succeed("cat " + browser_root + "/browser.log")
            raise AssertionError("Evacuation browser exited before checkpoint")
        return False

    eventually(ready, timeout=180)


def release(name: str) -> None:
    client.succeed("touch " + browser_root + "/" + name + ".go")


def guest(vm_id: str, action: str) -> None:
    assert action in {"prepare", "before-stop", "verify", "verify-live"}
    host, placement = current_placement(vm_id)
    host.succeed(f"fleet-relocation-guest {action} {placement}", timeout=240)


def identity(vm_id: str) -> str:
    assert str(uuid.UUID(vm_id)) == vm_id
    return sql(
        "SELECT jsonb_build_array(v.id,v.name,v.owner_id,v.team_id,v.image_id,v.profile,"
        "v.architecture,v.vcpu,v.memory_bytes,v.disk_bytes,a.id,a.slot,e.id,e.label) "
        "FROM compute_virtual_machines v JOIN compute_network_addresses a ON a.vm_id=v.id "
        "JOIN ingress_endpoints e ON e.vm_id=v.id "
        f"WHERE v.id='{vm_id}' AND a.archived_at IS NULL"
    )


def inventory() -> str:
    return sql(
        "SELECT jsonb_build_object("
        "'campaigns',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM compute_evacuations t),"
        "'items',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM compute_evacuation_items t),"
        "'moves',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM compute_relocations t),"
        "'holds',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM compute_reservations t),"
        "'audit',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM account_admin_events t "
        "WHERE kind LIKE 'evacuation_%'))"
    )


def web(vm_id: str, hostname: str) -> None:
    assert hostname.endswith(".apps.example.test")
    assert all(c.isalnum() or c in ".-" for c in hostname)
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM ingress_routes "
                f"WHERE vm_id='{vm_id}' AND expires_at > (clock_timestamp() AT TIME ZONE 'UTC')"
            )
            == "1"
        ),
        timeout=120,
    )
    client.wait_until_succeeds(
        "curl --fail --silent --show-error --cacert "
        + root
        + "/audi-root.pem https://"
        + hostname
        + "/ > /run/evacuation-response && grep -qx audi-guest /run/evacuation-response",
        timeout=60,
    )


with subtest("two ordinary owned guests retain source data before the admin campaign"):
    # Keep the destination admission-disabled until the real browser has paused
    # the campaign. This cannot block execution on the existing source.
    operator(dict(action="enable", host_id=host_bindings["l2"]["host"], enabled=False))
    vm_ids: list[str] = []
    for _ in range(2):
        admitted = operator(
            dict(
                action="provision",
                owner_id=users["owner_id"],
                image_id=users["image_id"],
                profile="oss",
                key=str(uuid.uuid4()),
                disk_bytes=4294967296,
            )
        )
        assert admitted["accepted"] is True
        vm_id = admitted["vm_id"]
        assert isinstance(vm_id, str) and str(uuid.UUID(vm_id)) == vm_id
        vm_ids.append(vm_id)
        running(vm_id)
        assert current_placement(vm_id)[0] is l1
        guest(vm_id, "prepare")
        guest(vm_id, "before-stop")
    running_vm, stopped_vm = vm_ids
    originals = {vm: current_placement(vm)[1] for vm in vm_ids}
    identities = {vm: identity(vm) for vm in vm_ids}
    lifecycle(stopped_vm, "stop")
    eventually(
        lambda: (
            sql(f"SELECT observed_state FROM compute_virtual_machines WHERE id='{stopped_vm}'")
            == "stopped"
        )
    )
    eventually(
        lambda: sql("SELECT count(*) FROM compute_reservations WHERE startup_compute_held") == "0"
    )
    l1.succeed("fleet-audi-guest " + originals[running_vm], timeout=240)
    policy = operator(
        dict(
            action="audi-policy", owner_id=users["owner_id"], vm_id=running_vm, visibility="public"
        )
    )
    label = policy["label"]
    assert isinstance(label, str)
    hostname = label + ".apps.example.test"
    transfer(m1, root + "/audi-root.pem", client, root + "/audi-root.pem")
    eventually(
        lambda: sql("SELECT count(*) FROM ingress_fleet_certificates WHERE status='active'") == "1",
        timeout=360,
    )
    web(running_vm, hostname)

with subtest("ordinary browser preview and forged maintenance refusal preserve durable state"):
    operator(
        dict(
            action="evacuation-browser",
            source=root + "/users.json",
            output=root + "/evacuation-users.json",
            host_id=host_bindings["l1"]["host"],
        )
    )
    client.succeed(
        "install -d -m 700 -o tester -g users " + browser_root + " /home/tester/.pki/nssdb"
    )
    client.succeed("sudo -u tester certutil -N -d sql:/home/tester/.pki/nssdb --empty-password")
    client.succeed(f"install -m 644 {root}/ca.crt {browser_root}/ca.crt")
    client.succeed(
        f"sudo -u tester certutil -A -d sql:/home/tester/.pki/nssdb -n evacuation-root -t 'C,,' -i {browser_root}/ca.crt"
    )
    transfer(m1, root + "/evacuation-users.json", client, browser_root + "/users.json")
    client.succeed(
        f"chown tester:users {browser_root}/users.json && chmod 600 {browser_root}/users.json"
    )
    client.succeed(
        "systemd-run --unit=evacuation-browser-fixture --property=User=tester --setenv=HOME=/home/tester --setenv=PATH=/run/current-system/sw/bin /bin/sh -c "
        + shlex.quote("fleet-evacuation-browser >" + browser_root + "/browser.log 2>&1")
    )
    signal("before-preview")
    before = inventory()
    release("before-preview")
    signal("preview-refused")
    assert inventory() == before
    release("preview-refused")

with subtest(
    "real elevated browser request fixes the cohort and pause prevents admission while serving"
):
    signal("paused")
    campaign = sql("SELECT id FROM compute_evacuations WHERE closed_at IS NULL")
    assert str(uuid.UUID(campaign)) == campaign
    assert (
        sql(f"SELECT count(*) FROM compute_evacuation_items WHERE evacuation_id='{campaign}'")
        == "2"
    )
    for vm in vm_ids:
        assert (
            sql(
                f"SELECT placement_id FROM compute_evacuation_items WHERE evacuation_id='{campaign}' AND vm_id='{vm}'"
            )
            == originals[vm]
        )
    assert (
        sql(
            "SELECT enabled::text || ':' || maintenance_mode::text FROM compute_hosts WHERE name='l1'"
        )
        == "true:evacuating"
    )
    operator(dict(action="enable", host_id=host_bindings["l2"]["host"], enabled=True))
    assert operator(dict(action="evacuation-advance", id=campaign)) == {"state": "paused"}
    assert sql(f"SELECT count(*) FROM compute_relocations WHERE evacuation_id='{campaign}'") == "0"
    guest(running_vm, "verify-live")
    web(running_vm, hostname)
    assert (
        sql(
            f"SELECT desired_state::text || ':' || observed_state::text FROM compute_virtual_machines WHERE id='{stopped_vm}'"
        )
        == "stopped:stopped"
    )
    release("paused")

with subtest(
    "continue moves running and stopped guests and readiness follows physical source cleanup"
):
    signal("continued")
    next_advance = 0.0

    def ready() -> bool:
        global next_advance
        if time.monotonic() >= next_advance:
            result = operator(dict(action="evacuation-advance", id=campaign))
            assert result["state"] in {
                "scheduled",
                "already_scheduled",
                "awaiting_cleanup",
                "blocked",
                "ready",
            }
            next_advance = time.monotonic() + 15
        # No failed physical receipt may be hidden by the total wait deadline.
        assert (
            sql(
                f"SELECT count(*) FROM compute_relocations WHERE evacuation_id='{campaign}' AND phase IN ('readiness_failed','activation_failed')"
            )
            == "0"
        )
        return sql(f"SELECT status FROM compute_evacuations WHERE id='{campaign}'") == "ready"

    eventually(ready, timeout=1800)
    assert (
        sql(
            f"SELECT count(*) FROM compute_relocations WHERE evacuation_id='{campaign}' AND committed_at IS NOT NULL AND finished_at IS NOT NULL"
        )
        == "2"
    )
    assert (
        sql(
            f"SELECT count(*) FROM compute_evacuation_items WHERE evacuation_id='{campaign}' AND relocation_id IS NOT NULL"
        )
        == "2"
    )
    for vm in vm_ids:
        destination, placement = current_placement(vm)
        assert destination is l2 and placement != originals[vm]
        assert identity(vm) == identities[vm]
        l1.fail("zfs list zroot/lilly/vm-" + originals[vm])
        l1.fail("systemctl is-active --quiet lilly-vm-" + originals[vm] + ".service")
    source_id = host_bindings["l1"]["host"]
    assert (
        sql(
            f"SELECT count(*) FROM compute_reservations WHERE host_id='{source_id}' AND (compute_held OR disk_held OR temporary_disk_bytes>0 OR pending_disk_bytes>0 OR startup_compute_held)"
        )
        == "0"
    )
    assert (
        sql(
            f"SELECT count(*) FROM compute_transfer_slots WHERE host_id='{source_id}' AND released_at IS NULL"
        )
        == "0"
    )
    assert (
        sql(f"SELECT allocations::text FROM compute_storage_pools WHERE host_id='{source_id}'")
        == "{}"
    )
    assert (
        sql(
            f"SELECT reported_at > (clock_timestamp() AT TIME ZONE 'UTC') - interval '15 seconds' FROM compute_storage_pools WHERE host_id='{source_id}'"
        )
        == "t"
    )
    running(running_vm)
    guest(running_vm, "verify")
    assert (
        sql(
            f"SELECT desired_state::text || ':' || observed_state::text FROM compute_virtual_machines WHERE id='{stopped_vm}'"
        )
        == "stopped:stopped"
    )
    stopped_placement = current_placement(stopped_vm)[1]
    l2.fail("systemctl is-active --quiet lilly-vm-" + stopped_placement + ".service")
    # The ephemeral fixture HTTP process must be restarted after the ordinary
    # relocation reboot. Its durable ingress label and real route remain intact.
    l2.succeed("fleet-audi-guest " + current_placement(running_vm)[1], timeout=240)
    web(running_vm, hostname)
    placements = {vm: current_placement(vm)[1] for vm in vm_ids}
    release("continued")

with subtest("fresh admin resume restores admissions without moving workloads back"):
    signal("resumed")
    assert (
        sql(
            f"SELECT status::text || ':' || (closed_at IS NOT NULL)::text FROM compute_evacuations WHERE id='{campaign}'"
        )
        == "resumed:true"
    )
    assert (
        sql(
            f"SELECT enabled::text || ':' || maintenance_mode::text FROM compute_hosts WHERE id='{source_id}'"
        )
        == "true:normal"
    )
    for vm in vm_ids:
        assert current_placement(vm) == (l2, placements[vm])
        assert identity(vm) == identities[vm]
    lifecycle(stopped_vm, "start")
    running(stopped_vm)
    guest(stopped_vm, "verify")
    release("resumed")
    client.wait_until_succeeds("test -e " + browser_root + "/done", timeout=60)
    client.wait_until_succeeds(
        'test "$(systemctl show evacuation-browser-fixture.service -p SubState --value)" = dead'
    )
    client.succeed(
        'test "$(systemctl show evacuation-browser-fixture.service -p ExecMainStatus --value)" = 0'
    )
    ordinary_accounts()
