"""Composed after default-oss/setup.py; all authority is the packaged fleet."""


def github_browser(mode: str) -> None:
    client.succeed(
        "sudo -u tester env HOME=/home/tester fleet-github-integration-browser "
        + shlex.quote(mode),
        timeout=420,
    )


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
    for name, certificate in (("marshall", root + "/ca.crt"), ("github", github_fixture_root)):
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
    # @cc [owner:ghuntley,label:verification;recovery] github-fleet-scheduled-refresh
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

with subtest("browser detach persists anonymous forwarding and leaves the other owner connected"):
    github_browser("detach")
    github_guest(github_machines["owner"], "anonymous", "1")
    github_guest(github_machines["member"], "connected", "2")
    github_browser("attach")
    github_guest(github_machines["owner"], "connected", "1")

with subtest("browser disconnect revokes provider grant and leaves anonymous public forwarding"):
    github_browser("disconnect")
    github_guest(github_machines["owner"], "anonymous", "1")
    github_guest(github_machines["member"], "connected", "2")
    assert any(row.get("event") == "oauth_revocation" for row in provider_observations())
    for role, owner in (("owner", "1"), ("member", "2")):
        github_guest(github_machines[role], "clean", owner)
    for machine in marshalls + provisioners:
        diagnostic = machine.succeed("journalctl --no-pager -o cat")
        assert "synthetic-owner-" not in diagnostic
        assert "synthetic-refresh-owner-" not in diagnostic
