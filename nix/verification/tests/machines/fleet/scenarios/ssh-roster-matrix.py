# @cc [owner:ghuntley,label:verification;security] roster-matrix-native-identity
# Every retained-image transition (stop/start, clone of a stopped source, resize
# restart, cross-host relocation) MUST be followed by real per-user SSH proving
# the exact durable username, UID, mode-0700 home and retained markers, on both
# the NixOS and Ubuntu guest images. Console fixtures MUST NOT inject roster or
# account state; durable PostgreSQL is the only oracle for guest account state.
from typing import TypedDict


class GuestIdentity(TypedDict):
    name: str
    uid: int


class GuestAccountRow(TypedDict):
    username: str
    uid: int


matrix_root = "/var/lib/fleet-matrix"


def matrix_hostname(vm_id: str) -> str:
    label = sql(f"SELECT label FROM ingress_endpoints WHERE vm_id='{vm_id}'")
    assert label.startswith("v-")
    return label + ".apps.example.test"


def matrix_policy(vm_id: str) -> None:
    operator(
        m1,
        dict(action="audi-policy", owner_id=users["owner_id"], vm_id=vm_id, visibility="public"),
    )


def ssh_profile(profile_name: str, vm_id: str, identity: str) -> None:
    operator(
        m1,
        dict(
            action="audi-ssh-profile",
            owner_id=users["owner_id"],
            vm_id=vm_id,
            output=root + "/" + profile_name + ".conf",
        ),
    )
    transfer(
        m1,
        root + "/" + profile_name + ".conf",
        client,
        matrix_root + "/" + profile_name + ".conf",
    )
    client.succeed(
        "sed -i 's/--identity id_ed25519/--identity "
        + identity
        + "/' "
        + matrix_root
        + "/"
        + profile_name
        + ".conf && chown tester:users "
        + matrix_root
        + "/"
        + profile_name
        + ".conf"
    )


def guest_login(identity_file: str) -> str:
    """@cc [owner:ghuntley,label:verification;security] roster-matrix-guest-login
    Like the production managed SSH block (`User <guest_username>`), each
    session MUST log in as the identity owner's current durable guest account
    name; the fixture profile template carries no user, and the client's
    local OS name (tester) is no guest account.
    """
    owners = {"id_ed25519": "owner_id", "member_id": "member_id"}
    user_id = users[owners[identity_file]]
    assert isinstance(user_id, str)
    return current_identity(user_id)["name"]


def matrix_args(profile_name: str, hostname: str, identity_file: str) -> list[str]:
    return [
        "/run/current-system/sw/bin/ssh",
        "-F",
        matrix_root + "/" + profile_name + ".conf",
        "-l",
        guest_login(identity_file),
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "GlobalKnownHostsFile=/dev/null",
        "-o",
        "UserKnownHostsFile=" + matrix_root + "/known-hosts",
        "-i",
        "/home/tester/.ssh/" + identity_file,
        hostname,
    ]


matrix_environment = (
    "sudo -u tester env HOME=/home/tester CURL_CA_BUNDLE="
    + matrix_root
    + "/ca.crt SSL_CERT_FILE="
    + matrix_root
    + "/ca.crt "
)


def ssh_route_ready(vm_id: str, hostname: str) -> None:
    """@cc [owner:ghuntley,label:verification] roster-matrix-route-readiness
    SSH admission MUST begin only after the durable route row exists and both
    authoritative DNS replicas answer the label; these are observations of real
    publication state, not synthetic setup.
    """
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM ingress_routes WHERE vm_id='"
                + vm_id
                + "' AND expires_at > (clock_timestamp() AT TIME ZONE 'UTC')"
            )
            == "1"
        ),
        timeout=180,
    )
    for server in ("m2", "m3"):
        client.wait_until_succeeds(
            f"dig @{server} {hostname} A +noall +answer | grep -Eq '[[:space:]][0-9]+[[:space:]]+IN[[:space:]]+A[[:space:]]'",
            timeout=90,
        )


def ssh_diagnose(copy: PlacementRef) -> None:
    host_for(copy).succeed(
        "fleet-audi-guest ssh-diagnostics " + shlex.quote(copy["placement_id"]), timeout=90
    )


def current_identity(user_id: str) -> GuestIdentity:
    row = sql(
        f"SELECT username || '|' || uid FROM account_guest_accounts WHERE user_id='{user_id}' AND retired_at IS NULL"
    )
    name, raw_uid = row.split("|")
    assert 1 <= len(name) <= 32
    return GuestIdentity(name=name, uid=int(raw_uid))


def oracle_accounts(vm_id: str) -> list[GuestIdentity]:
    """@cc [owner:ghuntley,label:verification;security] roster-matrix-postgres-oracle
    Expected guest accounts MUST be deduced only from durable ownership, live
    grants, live team membership and tombstone state; the roster wire or the
    guest helper output MUST NOT seed the expectation.
    """
    rows = sql_json(
        "SELECT coalesce(json_agg(json_build_object('username',a.username,'uid',a.uid) ORDER BY a.username), '[]') "
        "FROM account_guest_accounts a WHERE a.retired_at IS NULL AND a.user_id IN ("
        " SELECT ids.id FROM ("
        "  SELECT owner_id AS id FROM compute_virtual_machines WHERE id='"
        + vm_id
        + "' UNION SELECT user_id FROM access_grants WHERE vm_id='"
        + vm_id
        + "' AND archived_at IS NULL"
        + " UNION SELECT m.user_id FROM team_members m JOIN compute_virtual_machines v ON v.team_id=m.team_id"
        + " WHERE v.id='"
        + vm_id
        + "' AND m.archived_at IS NULL"
        + " ) ids JOIN users u ON u.id=ids.id WHERE u.deleted_at IS NULL)"
    )
    assert isinstance(rows, list)
    result: list[GuestIdentity] = []
    for raw_row in rows:
        assert isinstance(raw_row, dict)
        row: dict[str, object] = {
            key: item for key, item in raw_row.items() if isinstance(key, str)
        }
        name = row.get("username")
        uid = row.get("uid")
        assert isinstance(name, str) and type(uid) is int
        result.append(GuestIdentity(name=name, uid=uid))
    return result


def key_registration(user_id: str, public_key: str) -> str:
    return str(
        operator(m1, dict(action="audi-ssh-key", owner_id=user_id, public_key=public_key))["id"]
    )


def ssh_identity(
    profile: str, hostname: str, identity_file: str, expected: GuestIdentity, markers: list[str]
) -> None:
    """@cc [owner:ghuntley,label:verification;security] roster-matrix-exact-account
    The real per-user SSH session MUST land on the durable name and UID with a
    writable mode-0700 home owned by that UID, and every marker from earlier
    transitions MUST still match. Identity is asserted against PostgreSQL
    inventory, never against the roster payload.
    """
    command = (
        'test "$(id -un)" = '
        + expected["name"]
        + ' && test "$(id -u)" = '
        + str(expected["uid"])
        + ' && test "$HOME" = /home/'
        + expected["name"]
        + ' && test "$PWD" = "$HOME" && test -w "$HOME"'
        + ' && test "$(stat -c \'%u:%a:%U\' "$HOME")" = \''
        + str(expected["uid"])
        + ":700:"
        + expected["name"]
        + "'"
        + "".join(
            ' && test "$(cat "$HOME/roster-marker-' + marker + '")" = ' + marker + ""
            for marker in markers
        )
        + " && printf MATRIX_IDENTITY_OK"
    )
    output = client.wait_until_succeeds(
        matrix_environment + shlex.join([*matrix_args(profile, hostname, identity_file), command]),
        timeout=180,
    )
    assert "MATRIX_IDENTITY_OK" in output


def write_marker(profile: str, hostname: str, identity_file: str, marker: str) -> None:
    command = "printf %s " + shlex.quote(marker) + ' > "$HOME/roster-marker-' + marker + '" && sync'
    client.wait_until_succeeds(
        matrix_environment + shlex.join([*matrix_args(profile, hostname, identity_file), command]),
        timeout=180,
    )


def guest_state_identical(profile: str, hostname: str, identity_file: str, vm_id: str) -> None:
    """@cc [owner:ghuntley,label:verification;security] roster-matrix-guest-state-oracle
    The reconciled guest ledger MUST name exactly the current durable writer set
    for this VM: one row per expected account, in any order, no stale or extra
    account. The comparison runs outside the roster reader's own machinery.
    """
    expected: list[GuestAccountRow] = sorted(
        (GuestAccountRow(username=row["name"], uid=row["uid"]) for row in oracle_accounts(vm_id)),
        key=lambda row: row["username"],
    )
    raw = client.wait_until_succeeds(
        matrix_environment
        + shlex.join(
            [
                *matrix_args(profile, hostname, identity_file),
                "sudo -n cat /var/lib/overalls-ssh/accounts.json",
            ]
        ),
        timeout=60,
    )
    observed_raw: object = json.loads(raw)
    assert isinstance(observed_raw, dict)
    observed: dict[str, object] = {
        key: item for key, item in observed_raw.items() if isinstance(key, str)
    }
    assert len(observed) == len(observed_raw)
    version = observed["version"]
    assert type(version) is int and version > 0
    accounts = observed["accounts"]
    assert isinstance(accounts, list)
    actual: list[GuestAccountRow] = []
    for raw_row in accounts:
        assert isinstance(raw_row, dict)
        row: dict[str, object] = {
            key: item for key, item in raw_row.items() if isinstance(key, str)
        }
        assert len(row) == len(raw_row)
        name = row.get("username")
        uid = row.get("uid")
        assert isinstance(name, str) and type(uid) is int
        actual.append(GuestAccountRow(username=name, uid=uid))
    actual.sort(key=lambda row: row["username"])
    assert actual == expected


def expired_retained(
    retained: GuestIdentity, profile: str, hostname: str, identity_file: str
) -> None:
    """@cc [owner:ghuntley,label:verification;security] roster-matrix-expired-retained
    An account dropped from the roster MUST be expired (shadow epoch 1) with its
    sudo policy removed, while its home survives, still owned by the historical
    UID at mode 0700. The retention boundary MUST be visible to a current writer.
    """
    command = (
        'test "$(sudo -n getent passwd '
        + retained["name"]
        + ' | cut -d: -f3)" = '
        + str(retained["uid"])
        + ' && test "$(sudo -n getent shadow '
        + retained["name"]
        + ' | cut -d: -f8)" = 1'
        + " && test \"$(sudo -n stat -c '%u:%a' /home/"
        + retained["name"]
        + ")\" = '"
        + str(retained["uid"])
        + ":700'"
        + " && sudo -n test ! -e /etc/sudoers.d/overalls_uid_"
        + str(retained["uid"])
    )
    client.wait_until_succeeds(
        matrix_environment + shlex.join([*matrix_args(profile, hostname, identity_file), command]),
        timeout=60,
    )


def ssh_refused(profile: str, hostname: str, identity_file: str, login_name: str) -> None:
    """@cc [owner:ghuntley,label:verification;security] roster-matrix-refusal-path
    A removed or cloned-away account MUST fail SSH admission on the outer policy
    gate or inner public-key path; no session may open with a detached name.
    """
    status, _ = client.execute(
        matrix_environment
        + "timeout 45 "
        + shlex.join(
            [
                *matrix_args(profile, hostname, identity_file)[:-1],
                login_name + "@" + hostname,
                "true",
            ]
        )
        + " >/dev/null 2>&1",
        timeout=60,
    )
    assert status != 0, "refused account unexpectedly opened a guest SSH session"


def start_stream(unit: str, arguments: list[str], marker: str, ready_path: str) -> None:
    program = (
        "import os,subprocess,pathlib; os.environ['PATH']='/run/current-system/sw/bin'; "
        "os.environ['HOME']='/home/tester'; os.environ['CURL_CA_BUNDLE']='"
        + matrix_root
        + "/ca.crt'; os.environ['SSL_CERT_FILE']='"
        + matrix_root
        + "/ca.crt'; "
        "p=subprocess.Popen("
        + repr([*arguments, "while true; do printf '" + marker + "\\n'; sleep .1; done"])
        + ",stdout=subprocess.PIPE,stderr=subprocess.DEVNULL); "
        "assert p.stdout is not None; "
        "assert p.stdout.readline() == b'" + marker + "\\n'; "
        "pathlib.Path('" + ready_path + "').touch(); "
        "p.communicate(timeout=120); assert p.returncode != 0"
    )
    client.succeed(
        "systemd-run --quiet --no-block --unit="
        + unit
        + " --property=User=tester --property=Type=oneshot --property=RemainAfterExit=yes "
        "--property=StandardOutput=null --property=StandardError=null "
        "/run/current-system/sw/bin/python3 -c " + shlex.quote(program)
    )

    def streaming() -> bool:
        state = client.succeed(
            "systemctl show " + unit + ".service --property=ActiveState --value"
        ).strip()
        assert state != "failed", unit + " terminated before its stream was live"
        return client.execute("test -f " + ready_path)[0] == 0

    eventually(streaming, timeout=30)


def closed_stream(unit: str, bound: float) -> float:
    started = time.monotonic()
    client.wait_for_unit(unit + ".service", timeout=int(bound))
    elapsed = time.monotonic() - started
    assert (
        client.succeed(
            "systemctl show " + unit + ".service --property=ExecMainStatus --value"
        ).strip()
        == "0"
    )
    return elapsed


with subtest("roster matrix: real Audi gateways, trusted client and a shared OSS guest"):
    roster_owner_id: object = users.get("owner_id")
    roster_member_id: object = users.get("member_id")
    assert isinstance(roster_owner_id, str) and isinstance(roster_member_id, str)
    assert str(uuid.UUID(roster_owner_id)) == roster_owner_id
    assert str(uuid.UUID(roster_member_id)) == roster_member_id
    ssh_ca_key = m1.succeed("ssh-keygen -y -f " + root + "/ssh-host-ca").strip()
    for machine in (m2, m3):
        token = f"{root}/audi-{machine.name}.token"
        operator(
            m1, dict(action="audi-enroll", role="dns", name="audi-" + machine.name, output=token)
        )
        transfer(m1, token, machine, root + "/audi.token")
        machine.wait_for_unit("audi-dns.service")
        machine.wait_for_open_port(53)
    m1.succeed("systemctl start fleet-audi-ca.service")
    m1.wait_for_open_port(14000)
    m1.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt --resolve m1:15000:127.0.0.1 https://m1:15000/roots/0 >{root}/audi-root.pem"
    )
    for machine in provisioners:
        address = client.succeed(
            "python3 -c "
            + shlex.quote("import socket; print(socket.gethostbyname(" + repr(machine.name) + "))")
        ).strip()
        token = f"{root}/audi-{machine.name}.token"
        operator(
            m1,
            dict(
                action="audi-enroll",
                role="gateway",
                name="audi-" + machine.name,
                host_id=host_bindings[machine.name]["host"],
                addresses=[address],
                output=token,
            ),
        )
        transfer(m1, root + "/audi-root.pem", machine, root + "/audi-root.pem")
        transfer(m1, token, machine, root + "/audi.token")
        machine.wait_for_unit("audi.service")
        machine.wait_for_open_port(22)
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
        timeout=60,
    )
    client.succeed(f"install -d -m 700 -o tester -g users {matrix_root}")
    transfer(m1, root + "/audi-root.pem", client, matrix_root + "/audi-root.pem")
    client.succeed(f"install -m 644 {root}/ca.crt {matrix_root}/ca.crt")
    client.succeed(
        "sudo -u tester install -d -m 700 /home/tester/.ssh /home/tester/.config/overalls"
    )
    client.succeed(
        "printf %s "
        + shlex.quote(
            json.dumps({"origin": "https://control.example.test", "zone": "apps.example.test"})
        )
        + " >/home/tester/.config/overalls/config.json"
    )
    client.succeed(
        f"curl -fsS --cacert {matrix_root}/ca.crt https://control.example.test/bin/ssh-trust.json >/home/tester/.ssh/overalls-trust.json"
    )
    client.succeed(
        "printf '%s\\n' "
        + shlex.quote("@cert-authority *.apps.example.test " + ssh_ca_key)
        + f" >{matrix_root}/known-hosts"
    )
    client.succeed("chown -R tester:users /home/tester/.ssh /home/tester/.config/overalls")
    for identity in ("id_ed25519", "member_id"):
        client.succeed(
            f"sudo -u tester ssh-keygen -q -t ed25519 -N '' -f /home/tester/.ssh/{identity}"
        )
    key_registration(
        roster_owner_id, client.succeed("cat /home/tester/.ssh/id_ed25519.pub").strip()
    )
    key_registration(
        roster_member_id, client.succeed("cat /home/tester/.ssh/member_id.pub").strip()
    )

    matrix_vm = provision_when_available(m1, "oss")
    await_running(matrix_vm["vm_id"])
    matrix_policy(matrix_vm["vm_id"])
    host_for(matrix_vm).succeed(
        "fleet-audi-guest ssh "
        + shlex.quote(matrix_vm["placement_id"])
        + f" {root}/matrix-host.pub",
        timeout=180,
    )
    matrix_name = matrix_hostname(matrix_vm["vm_id"])
    operator(
        m1,
        dict(
            action="share",
            owner_id=users["owner_id"],
            vm_id=matrix_vm["vm_id"],
            email=users["member_email"],
            role="operator",
            key=str(uuid.uuid4()),
        ),
    )
    ssh_profile("matrix-owner", matrix_vm["vm_id"], "id_ed25519")
    ssh_profile("matrix-member", matrix_vm["vm_id"], "member_id")

with subtest("roster matrix baseline: exact dual identity and PostgreSQL-equal guest state"):
    ssh_route_ready(matrix_vm["vm_id"], matrix_name)
    try:
        write_marker("matrix-owner", matrix_name, "id_ed25519", "initial")
    except Exception:
        ssh_diagnose(matrix_vm)
        raise
    write_marker("matrix-member", matrix_name, "member_id", "initial")
    owner_identity = current_identity(roster_owner_id)
    member_identity = current_identity(roster_member_id)
    matrix_markers = ["initial"]
    ssh_identity("matrix-owner", matrix_name, "id_ed25519", owner_identity, matrix_markers)
    ssh_identity("matrix-member", matrix_name, "member_id", member_identity, matrix_markers)
    guest_state_identical("matrix-owner", matrix_name, "id_ed25519", matrix_vm["vm_id"])

with subtest("roster matrix: stop/start retains exact names, UIDs, homes and markers"):
    lifecycle(matrix_vm["vm_id"], "stop")
    eventually(lambda: vm_state(matrix_vm["vm_id"]) == "stopped", timeout=300)
    lifecycle(matrix_vm["vm_id"], "start")
    await_running(matrix_vm["vm_id"])
    write_marker("matrix-owner", matrix_name, "id_ed25519", "restart")
    write_marker("matrix-member", matrix_name, "member_id", "restart")
    matrix_markers.append("restart")
    ssh_identity("matrix-owner", matrix_name, "id_ed25519", owner_identity, matrix_markers)
    ssh_identity("matrix-member", matrix_name, "member_id", member_identity, matrix_markers)
    guest_state_identical("matrix-owner", matrix_name, "id_ed25519", matrix_vm["vm_id"])

with subtest("roster matrix: resize restart retains per-user identity and markers"):
    resized = operator(
        m1,
        dict(
            action="resize",
            owner_id=users["owner_id"],
            vm_id=matrix_vm["vm_id"],
            key=str(uuid.uuid4()),
        ),
    )
    eventually(
        lambda: (
            sql(f"SELECT phase FROM compute_resize_requests WHERE id='{resized['id']}'")
            == "complete"
        ),
        timeout=600,
    )
    await_running(matrix_vm["vm_id"])
    write_marker("matrix-owner", matrix_name, "id_ed25519", "resize")
    write_marker("matrix-member", matrix_name, "member_id", "resize")
    matrix_markers.append("resize")
    ssh_identity("matrix-owner", matrix_name, "id_ed25519", owner_identity, matrix_markers)
    ssh_identity("matrix-member", matrix_name, "member_id", member_identity, matrix_markers)
    guest_state_identical("matrix-owner", matrix_name, "id_ed25519", matrix_vm["vm_id"])

with subtest("roster matrix: clone of the stopped source expires clone-only accounts"):
    lifecycle(matrix_vm["vm_id"], "stop")
    eventually(lambda: vm_state(matrix_vm["vm_id"]) == "stopped", timeout=300)
    cloned = operator(
        m1,
        dict(
            action="clone",
            owner_id=users["owner_id"],
            vm_id=matrix_vm["vm_id"],
            key=str(uuid.uuid4()),
        ),
    )
    clone_id = str(cloned["destination_vm_id"])
    assert str(uuid.UUID(str(cloned["id"]))) == str(cloned["id"])
    eventually(
        lambda: (
            sql(f"SELECT phase FROM compute_clone_requests WHERE id='{cloned['id']}'") == "complete"
        ),
        timeout=900,
    )
    # A clone restores its source's original (here stopped) power state and
    # leaves the copy stopped; start both before logging in.
    lifecycle(matrix_vm["vm_id"], "start")
    lifecycle(clone_id, "start")
    await_running(matrix_vm["vm_id"])
    await_running(clone_id)
    clone_copy = current_copy(clone_id)
    matrix_policy(clone_id)
    host_for(clone_copy).succeed(
        "fleet-audi-guest ssh "
        + shlex.quote(clone_copy["placement_id"])
        + f" {root}/matrix-clone-host.pub",
        timeout=180,
    )
    clone_name = matrix_hostname(clone_id)
    ssh_profile("matrix-clone", clone_id, "id_ed25519")
    ssh_route_ready(clone_id, clone_name)
    # The clone shares the source disk: the owner keeps the exact identity and
    # markers, while the source-only member account is expired but retained.
    ssh_identity("matrix-clone", clone_name, "id_ed25519", owner_identity, matrix_markers)
    guest_state_identical("matrix-clone", clone_name, "id_ed25519", clone_id)
    expired_retained(member_identity, "matrix-clone", clone_name, "id_ed25519")
    ssh_refused("matrix-clone", clone_name, "member_id", member_identity["name"])
    ssh_identity("matrix-owner", matrix_name, "id_ed25519", owner_identity, matrix_markers)
    ssh_identity("matrix-member", matrix_name, "member_id", member_identity, matrix_markers)
    guest_state_identical("matrix-owner", matrix_name, "id_ed25519", matrix_vm["vm_id"])

with subtest("roster matrix: cross-host relocation preserves the durable account inventory"):
    move = relocate(matrix_vm["vm_id"])
    moved = await_relocation(move, abort_on_readiness_failure=True)
    assert moved["host_id"] != matrix_vm["host_id"]
    write_marker("matrix-owner", matrix_name, "id_ed25519", "relocated")
    write_marker("matrix-member", matrix_name, "member_id", "relocated")
    matrix_markers.append("relocated")
    ssh_identity("matrix-owner", matrix_name, "id_ed25519", owner_identity, matrix_markers)
    ssh_identity("matrix-member", matrix_name, "member_id", member_identity, matrix_markers)
    guest_state_identical("matrix-owner", matrix_name, "id_ed25519", matrix_vm["vm_id"])
    eventually(
        lambda: (
            int(
                sql(
                    "SELECT count(*) FROM ssh_guest_logins WHERE vm_id='"
                    + matrix_vm["vm_id"]
                    + "' AND placement_id='"
                    + moved["placement_id"]
                    + "'"
                )
            )
            >= 1
        ),
        timeout=30,
    )

with subtest("roster matrix: stale and digest-mismatched rosters refuse guest mutation"):
    authorize_path = (
        "/usr/local/bin/overalls-ssh-authorize" if ubuntu_enabled else "/run/overalls-ssh-authorize"
    )

    def guest_roster_state() -> tuple[str, int]:
        """One read of the applied roster: its exact bytes and its version."""
        text = client.succeed(
            matrix_environment
            + shlex.join(
                [
                    *matrix_args("matrix-owner", matrix_name, "id_ed25519"),
                    "sudo -n cat /var/lib/overalls-ssh/accounts.json",
                ]
            )
        ).strip()
        parsed: object = json.loads(text)
        assert isinstance(parsed, dict)
        fields: dict[str, object] = {
            key: item for key, item in parsed.items() if isinstance(key, str)
        }
        version = fields.get("version")
        assert type(version) is int and version > 0
        return text, version

    # Bytes and version come from the same read, so a legitimate roster update
    # landing during this stage cannot masquerade as an injected mutation.
    state_before, live_version = guest_roster_state()
    stale_count_before = int(
        client.succeed(
            matrix_environment
            + shlex.join(
                [
                    *matrix_args("matrix-owner", matrix_name, "id_ed25519"),
                    "sudo -n journalctl -o cat --no-pager | grep -c 'ssh.roster_stale' || true",
                ]
            )
        ).strip()
    )
    current_rows = oracle_accounts(matrix_vm["vm_id"])
    refused_roster = {
        "version": 999,
        "accounts": [{"username": row["name"], "uid": row["uid"]} for row in current_rows],
    }
    assert live_version > 0
    stale_feed = json.dumps({"version": live_version - 1, "accounts": refused_roster["accounts"]})
    mismatched_feed = json.dumps({"version": live_version, "accounts": []})
    for feed in (stale_feed, mismatched_feed):
        code, _ = client.execute(
            matrix_environment
            + shlex.join(
                [
                    *matrix_args("matrix-owner", matrix_name, "id_ed25519"),
                    "printf %s "
                    + shlex.quote(feed)
                    + " | sudo -n "
                    + authorize_path
                    + " reconcile",
                ]
            ),
            timeout=60,
        )
        assert code != 0, "stale or digest-mismatched roster reconciled successfully"
    # The refused feeds are older (stale) or the same version with different
    # accounts (digest mismatch). Only Marshall's genuinely newer roster may
    # replace the applied state while they are injected.
    state_after, version_after = guest_roster_state()
    assert state_after == state_before or version_after > live_version, (
        "a refused roster mutated the applied guest roster"
    )
    stale_count_after = int(
        client.succeed(
            matrix_environment
            + shlex.join(
                [
                    *matrix_args("matrix-owner", matrix_name, "id_ed25519"),
                    "sudo -n journalctl -o cat --no-pager | grep -c 'ssh.roster_stale' || true",
                ]
            )
        ).strip()
    )
    assert stale_count_after >= stale_count_before + 2
    ssh_identity("matrix-owner", matrix_name, "id_ed25519", owner_identity, matrix_markers)
    guest_state_identical("matrix-owner", matrix_name, "id_ed25519", matrix_vm["vm_id"])

with subtest("roster matrix: team removal closes a live guest SSH stream within its lease"):
    created_team = operator(
        m1,
        dict(
            action="team-create",
            owner_id=users["owner_id"],
            name="roster-matrix-" + str(uuid.uuid4()),
            key=str(uuid.uuid4()),
        ),
    )
    team_id = str(created_team["team_id"])
    operator(
        m1,
        dict(
            action="team-set-member",
            owner_id=users["owner_id"],
            team_id=team_id,
            email=users["member_email"],
            role="member",
            key=str(uuid.uuid4()),
        ),
    )
    team_request = dict(
        action="provision",
        owner_id=users["owner_id"],
        image_id=users["image_id"],
        profile="oss",
        team_id=team_id,
        key=str(uuid.uuid4()),
    )
    accepted_team_vm: list[dict[str, object]] = []

    def team_admitted() -> bool:
        result = operator(m1, team_request)
        if result["accepted"]:
            accepted_team_vm.append(result)
            return True
        assert result["reason"] == "insufficient_capacity", result
        return False

    eventually(team_admitted, timeout=180)
    team_vm = accepted_placement(accepted_team_vm[0])
    await_running(team_vm["vm_id"])
    matrix_policy(team_vm["vm_id"])
    host_for(team_vm).succeed(
        "fleet-audi-guest ssh "
        + shlex.quote(team_vm["placement_id"])
        + f" {root}/matrix-team-host.pub",
        timeout=180,
    )
    team_name = matrix_hostname(team_vm["vm_id"])
    ssh_profile("team-owner", team_vm["vm_id"], "id_ed25519")
    ssh_profile("team-member", team_vm["vm_id"], "member_id")
    ssh_route_ready(team_vm["vm_id"], team_name)
    # The team member derives its account only from live team membership.
    client.wait_until_succeeds(
        matrix_environment
        + shlex.join(
            [
                *matrix_args("team-member", team_name, "member_id"),
                'test "$(id -un)" = "' + member_identity["name"] + '"',
            ]
        ),
        timeout=180,
    )
    start_stream(
        "matrix-team-live",
        [
            *matrix_args("team-member", team_name, "member_id")[:-1],
            member_identity["name"] + "@" + team_name,
        ],
        "matrix-team-live",
        matrix_root + "/team-live-ready",
    )
    removed_at = time.monotonic()
    operator(
        m1,
        dict(
            action="team-set-member",
            owner_id=users["owner_id"],
            team_id=team_id,
            email=users["member_email"],
            role="removed",
            key=str(uuid.uuid4()),
        ),
    )
    closed_stream("matrix-team-live", 30)
    print("roster matrix: team-removal stream closed in seconds:", time.monotonic() - removed_at)
    # Once the roster timer lands, the guest account is expired and deactivated
    # while its home and historical UID stay owned and retained.
    expired_retained(member_identity, "team-owner", team_name, "id_ed25519")
    guest_state_identical("team-owner", team_name, "id_ed25519", team_vm["vm_id"])
    ssh_refused("team-member", team_name, "member_id", member_identity["name"])
    owner_again = current_identity(roster_owner_id)
    assert owner_again == owner_identity
    ssh_identity("team-owner", team_name, "id_ed25519", owner_identity, [])
