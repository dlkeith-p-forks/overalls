"""Typed supervisor recovery journey on the real private guest service path."""

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

from test_driver.machine import QemuMachine as AgentMachine

root = "/var/lib/overalls-fleet"
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
    raise AssertionError("Guest CLI recovery condition timed out; private output withheld")


def operator(request: dict[str, object]) -> dict[str, object]:
    with TemporaryDirectory(prefix="agent-cli-private-") as directory:
        path = Path(directory) / "request.json"
        path.write_text(json.dumps(request))
        os.chmod(path, 0o600)
        target = root + "/default-oss-request.json"
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


def current_placement(vm_id: str) -> tuple[AgentMachine, str]:
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
        for filename in ("marshall.env", "ca.crt", "serper.key"):
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


def identifier(value: object) -> str:
    assert isinstance(value, str) and str(uuid.UUID(value)) == value
    return value


def current_executor(vm_id: str) -> tuple[str, int, str]:
    parsed: object = json.loads(
        sql(
            "SELECT json_build_object('id',id,'fence',fence_epoch,'digest',binary_sha256) "
            f"FROM agent_executors WHERE vm_id='{vm_id}' AND invalidated_at IS NULL"
        )
    )
    row = object_fields(parsed)
    fence = row["fence"]
    digest = row["digest"]
    assert isinstance(fence, int) and fence > 0
    assert isinstance(digest, str) and len(digest) == 64
    assert all(character in "0123456789abcdef" for character in digest)
    return identifier(row["id"]), fence, digest


def tool_round_trip(vm_id: str, minimum_fence: int) -> None:
    submitted = operator(
        dict(
            action="agent-prompt",
            actor_id=users["member_id"],
            vm_id=vm_id,
            key=str(uuid.uuid4()),
        )
    )
    turn = identifier(submitted["turn_id"])
    eventually(
        lambda: sql(f"SELECT status FROM agent_turns WHERE id='{turn}'") == "completed",
        timeout=240,
    )
    assert operator(dict(action="agent-result", actor_id=users["member_id"], turn_id=turn)) == {
        "status": "completed",
        "answer_matches": True,
        "reason": None,
    }
    assert (
        sql(
            f"SELECT count(*) FROM agent_commands c JOIN agent_executors e ON e.id=c.executor_id "
            f"WHERE c.turn_id='{turn}' AND c.tool='read_file' AND c.status='completed' "
            f"AND c.fence_epoch=e.fence_epoch AND c.fence_epoch >= {minimum_fence} "
            f"AND e.vm_id='{vm_id}'"
        )
        == "1"
    )
    assert (
        sql(f"SELECT count(*) FROM agent_model_calls WHERE turn_id='{turn}' AND status='completed'")
        == "2"
    )


with subtest("shared operator completes actual guest work before recovery"):
    provisioned = operator(
        dict(
            action="provision",
            owner_id=users["owner_id"],
            image_id=users["image_id"],
            profile="standard",
            key=str(uuid.uuid4()),
            disk_bytes=6_442_450_944,
        )
    )
    assert provisioned["accepted"] is True
    vm_id = identifier(provisioned["vm_id"])
    running(vm_id)
    machine, placement = current_placement(vm_id)
    machine.wait_until_succeeds(
        "fleet-galileo-guest agent-service " + shlex.quote(placement), timeout=180
    )
    machine.wait_until_succeeds(
        "fleet-galileo-guest agent-route " + shlex.quote(placement), timeout=180
    )
    eventually(
        lambda: (
            sql(
                f"SELECT count(*) FROM agent_executors WHERE vm_id='{vm_id}' "
                "AND invalidated_at IS NULL AND expires_at > (clock_timestamp() AT TIME ZONE 'UTC')"
            )
            == "1"
        ),
        timeout=180,
    )
    operator(
        dict(
            action="share",
            owner_id=users["owner_id"],
            vm_id=vm_id,
            email=users["member_email"],
            role="operator",
            key=str(uuid.uuid4()),
        )
    )
    initial = current_executor(vm_id)
    tool_round_trip(vm_id, initial[1])

for mode in ("format", "unregistered"):
    with subtest("real supervisor recovers candidate " + mode + " with a fresh Marshall fence"):
        prior_id, prior_fence, prior_digest = current_executor(vm_id)
        started = time.monotonic()
        machine.succeed(
            "fleet-galileo-guest agent-recovery-" + mode + " " + shlex.quote(placement),
            timeout=60,
        )
        machine.wait_until_succeeds(
            "fleet-galileo-guest agent-recovery-check " + shlex.quote(placement),
            timeout=160,
        )
        if mode == "unregistered":
            assert time.monotonic() - started >= 90
        eventually(
            lambda prior_fence=prior_fence: current_executor(vm_id)[1] > prior_fence, timeout=90
        )
        current_id, current_fence, current_digest = current_executor(vm_id)
        assert current_id != prior_id
        assert current_digest == prior_digest
        assert (
            sql(
                f"SELECT count(*) FROM agent_executors WHERE id='{prior_id}' AND invalidated_at IS NOT NULL"
            )
            == "1"
        )
        tool_round_trip(vm_id, current_fence)
        ordinary_accounts()

with subtest("fixture guest stops and is deleted through the normal owner action"):
    assert operator(
        dict(
            action="lifecycle",
            owner_id=users["owner_id"],
            vm_id=vm_id,
            kind="delete",
            key=str(uuid.uuid4()),
        )
    ) == {"requested": True}
    eventually(
        lambda: (
            sql(f"SELECT archived_at IS NOT NULL FROM compute_virtual_machines WHERE id='{vm_id}'")
            == "t"
        ),
        timeout=240,
    )
    machine.fail(
        f"systemctl is-active lilly-vm-{placement}.service",
        f"zfs list zroot/lilly/vm-{placement}",
    )
