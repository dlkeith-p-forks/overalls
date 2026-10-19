"""Composed after default-oss/setup.py; all authority is the packaged fleet."""


def github_browser(mode: str, member_username: str | None = None) -> None:
    arguments = ["fleet-github-integration-browser", mode, github_guest_os]
    if member_username is not None:
        arguments.append(member_username)
    try:
        client.succeed(
            "sudo -u tester env HOME=/home/tester " + shlex.join(arguments),
            timeout=420,
        )
    except Exception:
        # Only structural counters leave the database: statements, tokens and
        # provider requests never enter a failure receipt.
        counters: dict[str, int] = {}
        for label, statement in (
            ("lock_waiters", "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock'"),
            (
                "idle_transactions",
                "SELECT count(*) FROM pg_stat_activity WHERE state='idle in transaction'",
            ),
            ("connections", "SELECT count(*) FROM github_connections"),
            ("authorization_attempts", "SELECT count(*) FROM github_authorization_attempts"),
        ):
            try:
                counters[label] = int(sql(statement))
            except Exception:
                counters[label] = -1
        print(json.dumps({"event": "github_fleet_authority_failure", "counters": counters}))
        raise


def github_guest(vm_id: str, mode: str, owner: str) -> None:
    host, placement = current_placement(vm_id)
    host.succeed(
        shlex.join(["fleet-github-integration-guest", mode, placement, owner, github_guest_os]),
        timeout=480,
    )


def provider_observations() -> list[dict[str, object]]:
    return [
        object_fields(json.loads(line))
        for line in egress.succeed("cat /run/galileo-fixture/observed.jsonl").splitlines()
    ]


with subtest("real browser connects two owner identities and creates actual OSS guests"):
    egress.wait_for_unit("fleet-github-provider.service")
    client.succeed(
        "install -d -m 700 -o tester -g users " + browser_root + " /home/tester/.pki/nssdb"
    )
    client.succeed("sudo -u tester certutil -N -d sql:/home/tester/.pki/nssdb --empty-password")
    client.succeed(f"install -m 644 {root}/ca.crt {browser_root}/ca.crt")
    for name, certificate in (
        ("marshall", browser_root + "/ca.crt"),
        ("github", github_fixture_root),
    ):
        client.succeed(
            shlex.join(
                [
                    "sudo",
                    "-u",
                    "tester",
                    "certutil",
                    "-A",
                    "-d",
                    "sql:/home/tester/.pki/nssdb",
                    "-n",
                    name,
                    "-t",
                    "C,,",
                    "-i",
                    certificate,
                ]
            )
        )
    for role in ("owner", "member"):
        client.succeed(f"sudo -u tester ssh-keygen -q -t ed25519 -N '' -f {browser_root}/{role}")
    transfer(m1, root + "/users.json", client, browser_root + "/users.json")
    client.succeed(
        f"chown tester:users {browser_root}/users.json && chmod 600 {browser_root}/users.json"
    )
    image = users["image_id"]
    assert isinstance(image, str)
    github_image: str = image
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_hosts WHERE (inventory->'images') ? '"
                + github_image
                + "'"
            )
            != "0"
        ),
        timeout=900,
    )
    if github_guest_os == "windows":
        # The published Windows image is a retained historical image without
        # git_identity_version. Browser OAuth still runs normally; historical
        # allocations use the real physical admission path and leave
        # new-machine UI admission refusal as a separate product assertion.
        github_browser("connect")
        github_machines = {}
        for role, owner_id in (("owner", users["owner_id"]), ("member", users["member_id"])):
            assert isinstance(owner_id, str)
            receipt = operator(
                {
                    "action": "github-historical-windows",
                    "owner_id": owner_id,
                    "host_id": host_bindings["l1"]["host"],
                    "pool_id": host_bindings["l1"]["pool"],
                    "image_id": github_image,
                    "key": str(uuid.uuid4()),
                }
            )
            vm_id = receipt["vm_id"]
            assert isinstance(vm_id, str) and str(uuid.UUID(vm_id)) == vm_id
            github_machines[role] = vm_id
            running(vm_id)
        with TemporaryDirectory(prefix="github-machines-") as directory:
            path = Path(directory) / "github-machines.json"
            path.write_text(json.dumps(github_machines))
            os.chmod(path, 0o600)
            client.copy_from_host(str(path), browser_root + "/github-machines.json")
        client.succeed(
            "chown tester:users "
            + browser_root
            + "/github-machines.json && chmod 600 "
            + browser_root
            + "/github-machines.json"
        )
    else:
        github_browser("create")
        parsed_machines: object = json.loads(
            client.succeed("cat " + browser_root + "/github-machines.json")
        )
        github_machines = string_fields(parsed_machines)
    assert set(github_machines) == {"owner", "member"}
    assert github_machines["owner"] != github_machines["member"]
    for vm in github_machines.values():
        running(vm)
    ordinary_accounts()
    assert sql("SELECT count(*) FROM github_connections WHERE phase='connected'") == "2"

with subtest("scheduled refresh rotates each provider pair through the real Oban queue"):
    # Provider expiry alone MUST schedule refresh. The driver MUST observe real
    # provider calls and committed generations without running jobs manually or
    # editing SQL timestamps, phases, credentials or scheduled job arguments.
    eventually(
        lambda: (
            len([row for row in provider_observations() if row.get("event") == "oauth_refreshed"])
            == 2
        ),
        timeout=180,
    )
    assert (
        sql("SELECT count(*) FROM github_connections WHERE phase='connected' AND generation > 1")
        == "2"
    )
    for role, owner in (("owner", "1"), ("member", "2")):
        github_guest(github_machines[role], "connected", owner)

with subtest("real guest managed Git clones and pushes a private repository without credentials"):
    github_guest(github_machines["owner"], "git", "1")
    assert (
        egress.succeed(
            "git --git-dir=/run/galileo-fixture/repositories/owner/private.git show fleet-feature:fleet.txt"
        ).strip()
        == "real fleet push"
    )

# The common Linux journey verifies LFS independently of the platform matrix.
if github_guest_os != "windows":
    with subtest("real guest managed LFS uploads and downloads without retained guest authority"):
        github_guest(github_machines["owner"], "lfs", "1")
        uploads = [entry for entry in provider_observations() if entry.get("event") == "lfs_upload"]
        assert len(uploads) == 1
        assert uploads[0].get("owner") == 1
        assert uploads[0].get("bytes") == len(b"real fleet LFS transfer\n")

with subtest("shared member writer uses the VM owner's GitHub identity through browser terminal"):
    shared_receipt = operator(
        {
            "action": "share",
            "owner_id": users["owner_id"],
            "vm_id": github_machines["owner"],
            "email": users["member_email"],
            "role": "operator",
            "key": str(uuid.uuid4()),
        }
    )
    assert shared_receipt.get("shared") is True
    member_id = users["member_id"]
    assert isinstance(member_id, str) and str(uuid.UUID(member_id)) == member_id
    member_username = sql(
        "SELECT username FROM account_guest_accounts WHERE user_id='"
        + member_id
        + "' AND retired_at IS NULL"
    )
    assert member_username and "\n" not in member_username
    github_browser("shared-writer", member_username)
    github_guest(github_machines["member"], "connected", "2")

with subtest("browser detach persists anonymous forwarding and leaves the other owner connected"):
    github_browser("detach")
    github_guest(github_machines["owner"], "anonymous", "1")
    github_guest(github_machines["member"], "connected", "2")

with subtest("owner exclusion survives a real stopped guest and fresh native execution"):
    # @cc [owner:ghuntley,label:verification;recovery] github-fleet-detach-restart
    # A browser-created exclusion MUST still select anonymous forwarding after
    # an authorized stop/start and a different native systemd invocation. The
    # driver MUST observe real state and unit exit, never edit domain rows.
    detached_vm = github_machines["owner"]
    detached_host, detached_placement = current_placement(detached_vm)
    detached_unit = "lilly-vm-" + detached_placement + ".service"
    previous_invocation = detached_host.succeed(
        "systemctl show --property=InvocationID --value " + detached_unit
    ).strip()
    assert len(previous_invocation) == 32
    for lifecycle_kind in ("stop", "start"):
        lifecycle_receipt = operator(
            {
                "action": "lifecycle",
                "owner_id": users["owner_id"],
                "vm_id": detached_vm,
                "kind": lifecycle_kind,
                "key": str(uuid.uuid4()),
            }
        )
        assert lifecycle_receipt.get("requested") is True
        if lifecycle_kind == "stop":
            eventually(lambda: observed_state(detached_vm) == "stopped", timeout=600)
            detached_host.fail("systemctl is-active --quiet " + detached_unit)
        else:
            running(detached_vm)
    restarted_host, restarted_placement = current_placement(detached_vm)
    current_invocation = restarted_host.succeed(
        "systemctl show --property=InvocationID --value lilly-vm-"
        + restarted_placement
        + ".service"
    ).strip()
    assert len(current_invocation) == 32 and current_invocation != previous_invocation
    github_guest(detached_vm, "anonymous", "1")
    github_guest(github_machines["member"], "connected", "2")


with subtest("owner exclusion survives real relocation and a new OAuth grant"):
    # Exclusion MUST survive public relocation to a different host and a new
    # OAuth grant. Observe terminal completion, destination, epoch and source
    # unit exit before checking anonymous forwarding; never mutate domain rows.
    detached_vm = github_machines["owner"]
    source_host, source_placement = current_placement(detached_vm)
    previous_epoch = int(
        sql(f"SELECT execution_epoch FROM compute_virtual_machines WHERE id='{detached_vm}'")
    )
    request: dict[str, object] = {
        "action": "relocate",
        "owner_id": users["owner_id"],
        "vm_id": detached_vm,
        "key": str(uuid.uuid4()),
    }
    move: dict[str, object] = {}

    def admit_detached_relocation() -> bool:
        global move
        move = operator(request)
        if move.get("accepted") is True:
            return True
        assert move in (
            {"accepted": False, "reason": "insufficient_capacity"},
            {"accepted": False, "reason": "source_unavailable"},
        ), "Relocation refused outside closed readiness categories"
        return False

    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_hosts WHERE inventory->>'execution_ready'='true' "
                "AND reported_at > (statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds'"
            )
            == "2"
        ),
        timeout=180,
    )
    eventually(admit_detached_relocation, timeout=180)
    relocation_id = move["id"]
    destination = move["destination_placement_id"]
    assert isinstance(relocation_id, str) and str(uuid.UUID(relocation_id)) == relocation_id
    assert isinstance(destination, str) and str(uuid.UUID(destination)) == destination

    def detached_relocation_complete() -> bool:
        phase = sql(f"SELECT phase FROM compute_relocations WHERE id='{relocation_id}'")
        assert phase not in ("failed", "cancelled"), "Detached relocation failed"
        return (
            phase == "complete"
            and sql(
                f"SELECT finished_at IS NOT NULL FROM compute_relocations WHERE id='{relocation_id}'"
            )
            == "t"
        )

    eventually(detached_relocation_complete, timeout=600)
    running(detached_vm)
    destination_host, destination_placement = current_placement(detached_vm)
    assert destination_placement == destination
    assert destination_host.name != source_host.name
    assert (
        int(sql(f"SELECT execution_epoch FROM compute_virtual_machines WHERE id='{detached_vm}'"))
        > previous_epoch
    )
    source_host.fail("systemctl is-active --quiet lilly-vm-" + source_placement + ".service")
    github_browser("excluded")
    github_guest(detached_vm, "anonymous", "1")
    exchanged_before = len(
        [
            row
            for row in provider_observations()
            if row.get("event") == "oauth_exchanged" and row.get("owner") == 1
        ]
    )
    github_browser("reconnect")
    assert (
        len(
            [
                row
                for row in provider_observations()
                if row.get("event") == "oauth_exchanged" and row.get("owner") == 1
            ]
        )
        == exchanged_before + 1
    )
    github_guest(detached_vm, "anonymous", "1")
    github_guest(github_machines["member"], "connected", "2")
    github_browser("attach")
    github_guest(detached_vm, "connected", "1")

with subtest("browser disconnect revokes provider grant and leaves anonymous public forwarding"):
    revocations_before = len(
        [row for row in provider_observations() if row.get("event") == "oauth_revocation"]
    )
    github_browser("disconnect")
    github_guest(github_machines["owner"], "anonymous", "1")
    github_guest(github_machines["member"], "connected", "2")
    assert (
        len([row for row in provider_observations() if row.get("event") == "oauth_revocation"])
        == revocations_before + 1
    )
    for role, owner in (("owner", "1"), ("member", "2")):
        github_guest(github_machines[role], "clean", owner)
    for machine in marshalls + provisioners:
        diagnostic = machine.succeed("journalctl --no-pager -o cat")
        assert "synthetic-owner-" not in diagnostic
        assert "synthetic-refresh-owner-" not in diagnostic
