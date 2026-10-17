"""Typed bounded profile journey on the fleet's real service and guest topology."""

import base64
import hashlib
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

from test_driver.machine import QemuMachine as TeamMachine

root = "/var/lib/overalls-fleet"
browser_root = "/var/lib/fleet-team-resources"
marshalls = [m1, m2, m3]
provisioners = [l1, l2]


class TeamAccount(TypedDict):
    id: str
    email: str


def account_fields(receipt: dict[str, object]) -> dict[str, TeamAccount]:
    """@cc [owner:ghuntley,label:verification] team-resource-account-schema
    The ordinary-account receipt MUST validate every role's UUID and email
    before browser or VM operations. Tokens MUST NOT enter this public schema.
    """
    result: dict[str, TeamAccount] = {}
    for role in ("owner", "member", "stranger"):
        identity = receipt[role + "_id"]
        email = receipt[role + "_email"]
        assert isinstance(identity, str) and str(uuid.UUID(identity)) == identity
        assert isinstance(email, str) and email.startswith(role + "-")
        assert email.endswith("@example.test") and email.count("@") == 1
        result[role] = {"id": identity, "email": email}
    assert len({account["id"] for account in result.values()}) == 3
    return result


def image_identity(receipt: dict[str, object]) -> str:
    """@cc [owner:ghuntley,label:verification] team-resource-explicit-fixture-image
    Native creates MUST name the registered fixture image after validating its
    canonical SHA-256 identity; the fleet has no configured default image.
    """
    value = receipt["image_id"]
    assert isinstance(value, str) and value.startswith("sha256:")
    assert len(value) == 71 and all(char in "0123456789abcdef" for char in value[7:])
    return value


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


def ed25519_blob(key: str) -> bytes:
    fields = key.split(" ")
    assert len(fields) == 2 and fields[0] == "ssh-ed25519"
    blob = base64.b64decode(fields[1], validate=True)
    assert len(blob) == 51 and blob[:19] == b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
    assert base64.b64encode(blob).decode() == fields[1]
    return blob


def public_https(path: str, maximum: int, *, await_ready: bool = False) -> str:
    assert path.startswith("/") and maximum in (1024, 8192)
    command = (
        "curl --fail --silent --show-error --proto '=https' --max-time 10 "
        + "--max-filesize "
        + str(maximum)
        + " --cacert "
        + root
        + "/ca.crt "
        + shlex.quote("https://control.example.test" + path)
    )
    if await_ready:
        return client.wait_until_succeeds(command, timeout=30)
    return client.succeed(command)


def public_ssh_ca() -> str:
    """@cc [owner:ghuntley,label:verification;security] team-resource-public-ca
    Client CA trust MUST come from verified public HTTPS policy bound to the
    expected management host and guest zone, with an unexpired retirement and
    canonical Ed25519 key. Console-derived guest keys MUST NOT establish trust.
    """
    parsed: object = json.loads(public_https("/bin/ssh-trust.json", 8192))
    policy = object_fields(parsed)
    assert set(policy) == {"version", "ca", "management_host", "zone", "retirement"}
    assert type(policy["version"]) is int and policy["version"] == 1
    assert policy["management_host"] == "control.example.test"
    assert policy["zone"] == "apps.example.test"
    retirement = policy["retirement"]
    assert isinstance(retirement, int) and not isinstance(retirement, bool)
    assert retirement > time.time()
    ca = policy["ca"]
    assert isinstance(ca, str)
    ed25519_blob(ca)
    return ca


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
    raise AssertionError("Team-resource fixture condition timed out; private output withheld")


def operator(request: dict[str, object]) -> dict[str, object]:
    with TemporaryDirectory(prefix="team-resources-private-") as directory:
        path = Path(directory) / "request.json"
        path.write_text(json.dumps(request))
        os.chmod(path, 0o600)
        target = root + "/team-resources-request.json"
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


def current_placement(vm_id: str) -> tuple[TeamMachine, str]:
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


def porsche(
    command: str, role: str = "owner", expected_error: str | None = None
) -> dict[str, object]:
    """@cc [owner:ghuntley,label:verification;security] team-resource-porsche-transport
    Commands MUST traverse OpenSSH, packaged Porsche and authenticated Marshall.
    Refusals MUST be parsed application denials, never accepted transport errors.
    Raw rejection output stays private because onboarding can contain a token.
    """
    arguments = [
        "ssh",
        "-F",
        "/dev/null",
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com",
        "-o",
        "HostKeyAlias=control.example.test",
        "-o",
        "GlobalKnownHostsFile=/dev/null",
        "-o",
        "UserKnownHostsFile=" + browser_root + "/known_hosts",
        "-i",
        browser_root + "/" + role,
        "fixture@m1",
        command + " --json",
    ]
    output_path = browser_root + "/receipt.json"
    status, _ = client.execute(
        "sudo -u tester " + shlex.join(arguments) + " >" + output_path + " 2>/dev/null", timeout=680
    )
    # Never relay raw SSH output; project only a bounded, validated receipt.
    program = (
        "import json; v=json.load(open("
        + repr(output_path)
        + ")); assert v.get('version')==1; print(json.dumps({k:v[k] for k in ('status','error','result') if k in v}))"
    )
    parsed: object = json.loads(client.succeed("python3 -c " + shlex.quote(program)))
    receipt = object_fields(parsed)
    if expected_error is not None:
        assert status != 0
        assert receipt.get("error") == expected_error
    else:
        error = receipt.get("error")
        category = (
            error
            if isinstance(error, str)
            and error
            in {
                "conflict",
                "forbidden",
                "invalid_request",
                "not_found",
                "insufficient_capacity",
                "temporarily_unavailable",
            }
            else "unclassified"
        )
        assert status == 0 and receipt.get("status") == "succeeded", (
            "Porsche profile operation did not succeed: " + category
        )
    return receipt


def result_id(receipt: dict[str, object]) -> str:
    value = object_fields(receipt["result"])["id"]
    assert isinstance(value, str) and str(uuid.UUID(value)) == value
    return value


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
    # Current-route discovery requires the active fleet wildcard installed on
    # each gateway. The real ACME state machine advances on minute scheduler
    # ticks through order, DNS proof, finalization and download, so its finish
    # depends on wall-clock phase; wait for it here rather than inside the
    # per-guest 30-second route-publication budget.
    eventually(
        lambda: sql("SELECT count(*) FROM ingress_fleet_certificates WHERE status='active'") == "1",
        timeout=360,
    )
    eventually(
        lambda: (
            sql(
                "SELECT count(DISTINCT host_id) FROM ingress_fleet_certificate_installations WHERE generation=1"
            )
            == str(len(provisioners))
        ),
        timeout=90,
    )
    fixture = operator(dict(action="default-oss-users", output=root + "/users.json"))
    users = account_fields(fixture)
    image_id = image_identity(fixture)
    ordinary_accounts()

with subtest("ordinary users register real keys and enter packaged Porsche"):
    client.succeed(
        "install -d -m 700 -o tester -g users " + browser_root + " /home/tester/.pki/nssdb"
    )
    client.succeed("sudo -u tester certutil -N -d sql:/home/tester/.pki/nssdb --empty-password")
    client.succeed(f"install -m 644 {root}/ca.crt {browser_root}/ca.crt")
    client.succeed(
        f"sudo -u tester certutil -A -d sql:/home/tester/.pki/nssdb -n team-root -t 'C,,' -i {browser_root}/ca.crt"
    )
    # Registration tokens are minted immediately before use; startup must not
    # spend their normal short expiry while building actual guests.
    operator(
        dict(
            action="refresh-browser-tokens",
            source=root + "/users.json",
            output=root + "/fresh-users.json",
        )
    )
    transfer(m1, root + "/fresh-users.json", client, browser_root + "/users.json")
    client.succeed(
        f"chown tester:users {browser_root}/users.json && chmod 600 {browser_root}/users.json"
    )
    for role in ("owner", "member", "stranger"):
        client.succeed(f"sudo -u tester ssh-keygen -q -t ed25519 -N '' -f {browser_root}/{role}")
    client.succeed("sudo -u tester env HOME=/home/tester fleet-team-resource-browser", timeout=180)
    ordinary_accounts()
    m1.succeed(f"fleet-op gateway-prepare {root}/porsche.token")
    m1.succeed(f"fleet-op gateway-configure fleet {root}/porsche.token")
    m1.succeed("systemctl start porsche.service")
    m1.wait_for_open_port(22)
    ssh_ca = public_ssh_ca()
    client.succeed(
        "printf '%s\\n' "
        + shlex.quote("@cert-authority control.example.test " + ssh_ca)
        + f" >{browser_root}/known_hosts"
    )
    client.succeed(
        f"chown tester:users {browser_root}/known_hosts && chmod 600 {browser_root}/known_hosts"
    )
    guest_names: dict[str, str] = {}
    for role in ("owner", "member", "stranger"):
        result = object_fields(porsche("whoami", role)["result"])
        assert result["email"] == users[role]["email"]
        username = result["guest_username"]
        assert isinstance(username, str)
        raw_uid = sql(
            f"SELECT uid FROM account_guest_accounts WHERE user_id='{users[role]['id']}' AND retired_at IS NULL"
        )
        uid = int(raw_uid)
        assert 200000 <= uid <= 999999 and username == "u" + str(uid)
        guest_names[role] = username


def intent_inventory() -> dict[str, dict[str, dict[str, object]]]:
    """Refusals preserve intent, immutable operations, allocations and user receipts."""
    tables = (
        "team_members",
        "team_transfers",
        "account_admin_events",
        "ssh_requests",
        "compute_operations",
        "compute_reservations",
        "compute_network_addresses",
        "galileo_integrations",
        "galileo_integration_headers",
        "galileo_attachments",
    )
    queries = {table: "SELECT row_to_json(t) FROM " + table + " t ORDER BY id" for table in tables}
    queries["compute_virtual_machines"] = (
        "SELECT row_to_json(t) FROM (SELECT id,owner_id,team_id,profile,desired_state,generation,current_placement_id,execution_epoch FROM compute_virtual_machines ORDER BY id) t"
    )
    state: dict[str, dict[str, dict[str, object]]] = {}
    for table, query in queries.items():
        rows: dict[str, dict[str, object]] = {}
        for line in sql(query).splitlines():
            parsed: object = json.loads(line)
            fields = object_fields(parsed)
            row_id = fields["id"]
            assert isinstance(row_id, str) and row_id not in rows
            rows[row_id] = fields
        state[table] = rows
    return state


def refused(command: str, role: str) -> None:
    """@cc [owner:ghuntley,label:verification;security] team-refusal-inventory-diagnostics
    Forbidden commands MUST preserve the full captured inventory. Failure
    diagnostics MUST identify changed tables and column names without row values,
    identities, command arguments or integration header contents.
    """
    before = intent_inventory()
    porsche(command, role, "forbidden")
    after = intent_inventory()
    changes: dict[str, list[str]] = {}
    for table, prior_rows in before.items():
        current_rows = after[table]
        changed: set[str] = set()
        if prior_rows.keys() != current_rows.keys():
            changed.add("row_set")
        for row_id in prior_rows.keys() & current_rows.keys():
            prior, current = prior_rows[row_id], current_rows[row_id]
            changed.update(
                field
                for field in prior.keys() | current.keys()
                if field not in prior or field not in current or prior[field] != current[field]
            )
        if changed:
            changes[table] = sorted(changed)
    assert after == before, json.dumps(
        {"event": "team_refusal_inventory_changed", "changes": changes}
    )


def guest_route(vm_id: str, *, await_ready: bool = False) -> tuple[str, str, str]:
    """@cc [owner:ghuntley,label:verification;security] team-resource-certified-route
    Every scripted guest operation MUST derive its Audi certificate principal from
    the current verified HTTPS route-key response. Trust MUST admit only CA
    certificates for that principal and the authoritative guest hostname, never
    unsigned leaf keys. Fixture access MUST NOT start guest SSH or roster units.
    Positive readiness waits MAY poll publication through verified HTTPS before
    deriving the route, within the caller's shared 90-second budget. Denials
    MUST fetch the route once. Retries MAY reuse it while placement is unchanged.
    """
    host, _ = current_placement(vm_id)
    label = sql(f"SELECT label FROM ingress_endpoints WHERE vm_id='{vm_id}'")
    assert label.startswith("v-") and all(
        char in "abcdefghijklmnopqrstuvwxyz0123456789-" for char in label
    )
    hostname = label + ".apps.example.test"
    route = public_https("/api/audi/v1/known-hosts/" + label, 1024, await_ready=await_ready)
    assert len(route) <= 1024 and route.endswith("\n") and route.count("\n") == 1
    fields = route[:-1].split(" ")
    assert len(fields) == 3 and fields[0] == hostname
    blob = ed25519_blob(" ".join(fields[1:]))
    digest = base64.b32encode(hashlib.sha256(blob).digest()).decode().lower().rstrip("=")
    alias = "audi-" + digest + ".ssh.control.example.test"
    known = browser_root + "/known-" + vm_id
    client.succeed(
        "printf '%s\\n' "
        + shlex.quote("@cert-authority " + hostname + "," + alias + " " + ssh_ca)
        + " >"
        + known
    )
    client.succeed("chown tester:users " + known + " && chmod 600 " + known)
    return hostname, host.name, alias


def journal_cursor(machine: TeamMachine, unit: str) -> str:
    cursor = machine.succeed(
        "journalctl -u " + shlex.quote(unit) + " -n 1 -o json | jq -r .__CURSOR"
    ).strip()
    assert cursor and all(
        char in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789;=-"
        for char in cursor
    )
    return cursor


def journal_reasons(machine: TeamMachine, unit: str, cursor: str, event: str) -> list[str]:
    raw = machine.succeed(
        "journalctl -u "
        + shlex.quote(unit)
        + " --after-cursor="
        + shlex.quote(cursor)
        + " -o cat | jq -Rsc --arg event "
        + shlex.quote(event)
        + " "
        + shlex.quote(
            '[split("\\n")[] | fromjson? | .metadata | select(.event == $event) | .reason]'
        )
    )
    parsed: object = json.loads(raw)
    assert isinstance(parsed, list)
    reasons: list[str] = []
    for reason in parsed:
        assert isinstance(reason, str)
        reasons.append(reason)
    return reasons


def guest_command(
    vm_id: str,
    role: str,
    command: str,
    expected: str | None,
    *,
    await_ready: bool = False,
    inspect_output: bool = False,
) -> None:
    """@cc [owner:ghuntley,label:verification;security] team-resource-native-ssh
    User operations MUST traverse actual OpenSSH, Audi and guest sshd with strict
    certificates bound to public HTTPS CA policy and current routing. Explicit
    postboot/roster waits MUST require actual successful SSH with a 90-second
    polling budget and a 45-second limit per attempt;
    running VM state alone MUST NOT count as SSH readiness. Denials MUST remain
    single attempts. New-connection denial MUST leave both
    ingress and guest-login receipts unchanged and receive recognized-key
    guidance plus a fresh Audi forbidden control response for the authenticated
    foreign, Customer or removed member. Generic SSH exits
    and transport errors MUST NOT count as authority refusal. Existing session
    termination is outside this check. Explicit inspect_output reads MUST require
    successful SSH and leave bytes in private files for schema validation.
    """
    readiness_started = time.monotonic()
    if await_ready:
        assert expected is not None
    hostname, host, alias = guest_route(vm_id, await_ready=await_ready)
    label = hostname.split(".")[0]
    known = browser_root + "/known-" + vm_id
    identity = browser_root + "/" + role
    shared = [
        "ssh",
        "-F",
        "/dev/null",
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "IdentityAgent=none",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com",
        "-o",
        "GlobalKnownHostsFile=/dev/null",
        "-o",
        "UserKnownHostsFile=" + known,
        "-i",
        identity,
    ]
    proxy_command = shlex.join(
        [*shared, "-o", "HostKeyAlias=" + alias, "audi@" + host, "connect", label]
    )
    username = guest_names[role]
    argv = [*shared, "-o", "ProxyCommand=" + proxy_command, username + "@" + hostname, command]
    before = sql(
        f"SELECT (SELECT count(*) FROM ingress_sessions WHERE vm_id='{vm_id}')::text || ':' || (SELECT count(*) FROM ssh_guest_logins WHERE vm_id='{vm_id}')::text"
    )
    host_machine, _ = current_placement(vm_id)
    cursor = journal_cursor(host_machine, "audi.service")
    invocation = (
        "sudo -u tester timeout 45 "
        + shlex.join(argv)
        + " >"
        + browser_root
        + "/guest.out 2>"
        + browser_root
        + "/guest.err"
    )
    if await_ready:
        assert expected is not None
        remaining = 90 - int(time.monotonic() - readiness_started)
        assert remaining > 0, "Route publication exhausted SSH readiness budget"
        client.wait_until_succeeds(invocation, timeout=remaining)
        status = 0
    else:
        status, _ = client.execute(invocation, timeout=50)
    if inspect_output:
        assert expected is None and not await_ready
        assert status == 0, "Authorized counter read failed; private diagnostics retained"
    elif expected is None:
        assert status == 255, "New guest connection was not refused at SSH admission"
        client.succeed(
            "grep -Fq "
            + shlex.quote(
                "This SSH connection could not be authorized. Check your machine access and try again."
            )
            + " "
            + browser_root
            + "/guest.err"
        )
        reasons = journal_reasons(
            host_machine, "audi.service", cursor, "audi.control_exchange_failed"
        )
        assert reasons and all(reason == "forbidden" for reason in reasons), (
            "SSH refusal lacked a fresh closed forbidden control response"
        )
        assert (
            sql(
                f"SELECT (SELECT count(*) FROM ingress_sessions WHERE vm_id='{vm_id}')::text || ':' || (SELECT count(*) FROM ssh_guest_logins WHERE vm_id='{vm_id}')::text"
            )
            == before
        )
    else:
        assert status == 0, "Authorized guest command failed; private diagnostics retained"
        client.succeed('test "$(cat ' + browser_root + '/guest.out)" = ' + shlex.quote(expected))


def integration_probe(vm_id: str, role: str, permitted: bool) -> None:
    """@cc [owner:ghuntley,label:verification;security] team-resource-private-refusal
    The isolated denied request MUST yield exactly one fresh Marshall Galileo
    unauthorized event across the three replicas, guest HTTP 403 (a verified
    refusal, not an outage) and unchanged origin count. Proxy outages alone MUST NOT count as membership refusal. Positive
    requests MUST reach the real origin through the guest private service path.
    """
    cursors = (
        [
            (machine, journal_cursor(machine, "marshall-" + machine.name + ".service"))
            for machine in marshalls
        ]
        if not permitted
        else []
    )
    before = int(egress.succeed("cat /run/galileo-origin/count").strip())
    command = "curl --silent --show-error --max-time 15 --output /tmp/team-integration-body --write-out '%{http_code}' https://directapi.integration.internal/direct"
    guest_command(vm_id, role, command, "200" if permitted else "403")
    assert int(egress.succeed("cat /run/galileo-origin/count").strip()) == before + (
        1 if permitted else 0
    )
    if permitted:
        guest_command(vm_id, role, "cat /tmp/team-integration-body", "galileo-origin-ok")
    else:
        reasons = [
            reason
            for machine, cursor in cursors
            for reason in journal_reasons(
                machine,
                "marshall-" + machine.name + ".service",
                cursor,
                "galileo.authorization_denied",
            )
        ]
        assert reasons == ["unauthorized"], (
            "Private-service refusal lacked the isolated request's unauthorized decision"
        )


with subtest("ordinary team owner provisions shared, personal and Customer resources"):
    team_id = result_id(porsche("team create native-resources"))
    member_email = users["member"]["email"]
    porsche("team member add native-resources " + member_email + " member")
    shared_vm = result_id(
        porsche(
            f"new --name shared-team --team native-resources --image {image_id} --profile oss --cpu 1 --memory 512 --disk 4 --timeout 600"
        )
    )
    member_vm = result_id(
        porsche(
            f"new --name member-personal --image {image_id} --profile oss --cpu 1 --memory 512 --disk 4 --timeout 600",
            "member",
        )
    )
    customer_vm = result_id(
        porsche(
            f"new --name team-customer --team native-resources --image {image_id} --profile customer --cpu 1 --memory 512 --disk 4 --timeout 600"
        )
    )
    for vm_id in (shared_vm, member_vm, customer_vm):
        running(vm_id)
    for vm_id, role in ((shared_vm, "owner"), (member_vm, "member"), (customer_vm, "owner")):
        guest_command(vm_id, role, "whoami", guest_names[role], await_ready=True)
    assert sql(f"SELECT team_id FROM compute_virtual_machines WHERE id='{shared_vm}'") == team_id
    assert sql(f"SELECT team_id FROM compute_virtual_machines WHERE id='{customer_vm}'") == team_id
    assert (
        sql(f"SELECT team_id IS NULL FROM compute_virtual_machines WHERE id='{member_vm}'") == "t"
    )
    # Wait for startup accounting to settle before unchanged-inventory refusals.
    eventually(
        lambda: sql("SELECT count(*) FROM compute_reservations WHERE startup_compute_held") == "0"
    )
    ordinary_accounts()

with subtest("member uses shared guest but cannot manage; foreign and Customer refuse"):
    porsche("show shared-team", "member")
    guest_command(shared_vm, "owner", "whoami", guest_names["owner"])
    guest_command(shared_vm, "member", "whoami", guest_names["member"])
    guest_command(
        shared_vm,
        "member",
        "printf team-member-data >$HOME/team-proof && cat $HOME/team-proof",
        "team-member-data",
    )
    refused("stop shared-team", "member")
    refused("show shared-team", "stranger")
    guest_command(shared_vm, "stranger", "true", None)
    refused("show team-customer", "member")
    guest_command(customer_vm, "member", "true", None)
    guest_command(customer_vm, "owner", "whoami", guest_names["owner"])

with subtest("team integration reaches member-owned guest and follows current membership"):
    egress.wait_for_unit("fleet-galileo-origin.service")
    operator(
        dict(action="galileo-configure-direct", owner_id=users["owner"]["id"], team_id=team_id)
    )
    assert (
        sql(
            f"SELECT owner_id IS NULL AND team_id='{team_id}' FROM galileo_integrations WHERE name='directapi'"
        )
        == "t"
    )
    assert sql("SELECT count(*) FROM galileo_attachments") == "0"
    integration_probe(member_vm, "member", True)
    refused("integration rm directapi", "member")
    refused("integration rm directapi", "stranger")
    porsche("team member add native-resources " + member_email + " admin")
    porsche("stop shared-team --timeout 180", "member")
    eventually(
        lambda: (
            sql(f"SELECT observed_state FROM compute_virtual_machines WHERE id='{shared_vm}'")
            == "stopped"
        )
    )
    porsche("start shared-team --timeout 600", "member")
    running(shared_vm)
    guest_command(shared_vm, "member", "cat $HOME/team-proof", "team-member-data", await_ready=True)
    # A running outcome can precede the host inventory that releases its startup
    # hold. Wait for that background update before comparing refusal snapshots,
    # as the initial provision and later removal checks already do.
    eventually(
        lambda: sql("SELECT count(*) FROM compute_reservations WHERE startup_compute_held") == "0"
    )
    refused("stop team-customer", "member")
    guest_command(customer_vm, "member", "true", None)
    porsche("team member remove native-resources " + member_email)
    eventually(
        lambda: sql("SELECT count(*) FROM compute_reservations WHERE startup_compute_held") == "0"
    )
    refused("show shared-team", "member")
    refused("start shared-team", "member")
    guest_command(shared_vm, "member", "true", None)
    integration_probe(member_vm, "member", False)
    integration_probe(shared_vm, "owner", True)
    # Re-add restores fresh use without changing identities, VM ownership or
    # explicit integration attachments. The member's home survives roster removal.
    porsche("team member add native-resources " + member_email + " member")
    guest_command(shared_vm, "member", "cat $HOME/team-proof", "team-member-data", await_ready=True)
    integration_probe(member_vm, "member", True)
    ordinary_accounts()
    assert sql("SELECT count(*) FROM galileo_attachments") == "0"
    assert (
        sql("SELECT count(*) FROM compute_virtual_machines WHERE observed_state='running'") == "3"
    )
