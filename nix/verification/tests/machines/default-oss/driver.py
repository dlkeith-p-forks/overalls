"""Default-profile journey scenarios; composed after setup.py with its helpers."""

with subtest("ordinary browser owner accepts untouched OSS default and registers real keys"):
    m1.succeed("fleet-op gateway-prepare " + root + "/porsche.token")
    m1.succeed("fleet-op gateway-configure fleet " + root + "/porsche.token")
    m1.succeed("systemctl start porsche.service")
    m1.wait_for_open_port(22)
    client.succeed(
        "install -d -m 700 -o tester -g users " + browser_root + " /home/tester/.pki/nssdb"
    )
    client.succeed("sudo -u tester certutil -N -d sql:/home/tester/.pki/nssdb --empty-password")
    client.succeed(f"install -m 644 {root}/ca.crt {browser_root}/ca.crt")
    client.succeed(
        f"sudo -u tester certutil -A -d sql:/home/tester/.pki/nssdb -n profile-root -t 'C,,' -i {browser_root}/ca.crt"
    )
    for role in ("owner", "member", "stranger"):
        client.succeed(f"sudo -u tester ssh-keygen -q -t ed25519 -N '' -f {browser_root}/{role}")
    host_ca = m1.succeed("ssh-keygen -y -f " + root + "/ssh-host-ca").strip()
    client.succeed(
        "printf '%s\\n' "
        + shlex.quote("@cert-authority control.example.test " + host_ca)
        + " >"
        + browser_root
        + "/known_hosts"
    )
    transfer(m1, root + "/users.json", client, browser_root + "/users.json")
    client.succeed(
        f"chown tester:users {browser_root}/users.json && chmod 600 {browser_root}/users.json"
    )
    # Lilly advertises an image only after background SHA-256 verification
    # (ADR-0014), which can lag on a loaded host. The form defaults to the image
    # only once a host advertises it, so wait for that before the browser.
    advertised = users["image_id"]
    assert isinstance(advertised, str)
    # A declared str survives into the closure; isinstance narrowing does not.
    default_image: str = advertised
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM compute_hosts WHERE (inventory->'images') ? '"
                + default_image
                + "'"
            )
            != "0"
        ),
        timeout=900,
    )
    client.succeed("sudo -u tester env HOME=/home/tester fleet-default-oss-browser", timeout=180)
    ordinary_accounts()
    browser_vm = client.succeed("cat " + browser_root + "/browser-vm").strip()
    assert str(uuid.UUID(browser_vm)) == browser_vm
    assert sql(f"SELECT profile FROM compute_virtual_machines WHERE id='{browser_vm}'") == "oss"
    running(browser_vm)
    # no-serial-login-shell: the read-only serial console ends with the fixed
    # boot-complete line and never offers a login prompt.
    console_host, console_placement = current_placement(browser_vm)
    boot_log = f"/var/lib/lilly/vms/{console_placement}/boot.log"
    console_host.wait_until_succeeds(f"grep -aq 'lilly-guest boot complete' {boot_log}", timeout=60)
    console_host.fail(f"grep -aq 'login:' {boot_log}")

with subtest(
    "Porsche omitted profile and retry pin one OSS guest; explicit Customer stays Customer"
):
    request_id = str(uuid.uuid4())
    image_id = users["image_id"]
    assert isinstance(image_id, str)
    command = f"new --name profile-ssh-oss --image {image_id} --cpu 1 --timeout 600 --request-id {request_id}"
    ssh_vm = result_id(porsche(command))
    assert result_id(porsche(command)) == ssh_vm
    porsche(command + " --profile customer", expected_error="idempotency_conflict")
    assert (
        sql(f"SELECT count(*) FROM compute_operations WHERE vm_id='{ssh_vm}' AND kind='provision'")
        == "1"
    )
    assert sql(f"SELECT profile FROM compute_virtual_machines WHERE id='{ssh_vm}'") == "oss"
    customer_vm = result_id(
        porsche(
            f"new --name profile-customer --profile customer --image {image_id} --cpu 1 --timeout 600 --request-id {uuid.uuid4()}"
        )
    )
    assert (
        sql(f"SELECT profile FROM compute_virtual_machines WHERE id='{customer_vm}'") == "customer"
    )
    for vm in (ssh_vm, customer_vm):
        running(vm)
    assert sql("SELECT count(*) FROM compute_virtual_machines") == "3"

with subtest(
    "explicit Customer allows owner reads and denies sharing, foreign reads and agent admission"
):
    member_email = users["member_email"]
    assert isinstance(member_email, str)
    # The same owner/key/recipient can share OSS. This positive control ensures
    # the Customer refusal is profile policy rather than a broken sharing path.
    porsche(f"share add profile-ssh-oss {member_email} viewer --request-id {uuid.uuid4()}")
    assert result_id(porsche("show profile-ssh-oss", role="member")) == ssh_vm
    porsche(f"share remove profile-ssh-oss {member_email} --request-id {uuid.uuid4()}")
    porsche("show profile-ssh-oss", role="member", expected_error="forbidden")
    versions_before = sql("SELECT count(*) FROM access_grants_versions")
    assert int(versions_before) > 0
    assert result_id(porsche("show profile-customer")) == customer_vm
    share_request = str(uuid.uuid4())
    porsche(
        f"share add profile-customer {member_email} viewer --request-id {share_request}",
        expected_error="forbidden",
    )
    porsche("show " + customer_vm, role="member", expected_error="forbidden")
    assert sql(f"SELECT count(*) FROM access_grants WHERE vm_id='{customer_vm}'") == "0"
    assert sql(f"SELECT count(*) FROM access_changes WHERE vm_id='{customer_vm}'") == "0"
    assert sql("SELECT count(*) FROM access_grants_versions") == versions_before
    assert sql(f"SELECT count(*) FROM ssh_requests WHERE request_id='{share_request}'") == "0"
    assert operator(
        dict(action="customer-agent-refusal", vm_id=customer_vm, owner_id=users["owner_id"])
    ) == {"refused": True}
    assert (
        sql(f"SELECT count(*) FROM agent_roots WHERE vm_id IN ('{browser_vm}','{ssh_vm}')") == "2"
    )
    ordinary_accounts()

with subtest("Customer owner CLI lifecycle replays receipts and recreates the real guest"):
    # @cc [owner:ghuntley,label:verification;recovery] customer-cli-owner-lifecycle
    # Owner stop/start MUST traverse the real Porsche CLI entry with persisted
    # receipt replay; the real guest process tree MUST die and return while the
    # retained ZFS dataset keeps its identity, and the Customer egress fence
    # MUST survive the restart. No fixture-side outcome injection is allowed.
    stop_key = str(uuid.uuid4())
    stop = porsche(f"stop profile-customer --request-id {stop_key} --timeout 600")
    replay = porsche(f"stop profile-customer --request-id {stop_key} --timeout 600")
    assert replay.get("operation_id") == stop.get("operation_id")
    assert replay.get("request_id") == stop.get("request_id")
    shown_stop = porsche(f"request show {stop_key}")
    assert shown_stop.get("status") == "succeeded"
    assert shown_stop.get("operation_id") == stop.get("operation_id")
    host, placement_id = current_placement(customer_vm)
    child = "zroot/lilly/vm-" + placement_id
    assert observed_state(customer_vm) == "stopped"
    host.fail("systemctl is-active lilly-vm-" + placement_id + ".service")
    host.fail("test -d /sys/fs/cgroup/lilly.slice/lilly-vm-" + placement_id + ".service")
    disk_identity = host.succeed("zfs get -Hp -o value guid " + child).strip()
    assert (
        sql(
            "SELECT compute_held::text || ':' || disk_held::text FROM compute_reservations "
            f"WHERE vm_id='{customer_vm}'"
        )
        == "false:true"
    )
    start_key = str(uuid.uuid4())
    start = porsche(f"start profile-customer --request-id {start_key} --timeout 600")
    assert start.get("operation_id") != stop.get("operation_id")
    shown_start = porsche(f"request show {start_key}")
    assert shown_start.get("operation_id") == start.get("operation_id")
    running(customer_vm)
    assert observed_state(customer_vm) == "running"
    assert host.succeed("zfs get -Hp -o value guid " + child).strip() == disk_identity
    snapshot = json.loads(host.succeed("fleet-processes " + placement_id))
    assert len(snapshot) > 0
    # The real CLI restart MUST NOT open the Customer egress fence.
    host.succeed("fleet-default-oss-guest customer " + placement_id, timeout=180)

with subtest("member stranger and promoted administrator CLI refusals leave intent unchanged"):
    # @cc [owner:ghuntley,label:verification;security] customer-cli-refusal-integrity
    # Non-owner Customer lifecycle, read and receipt entries MUST be refused
    # with the closed forbidden/not_found shape and zero durable rows, before
    # and after the member's fixture promotion to administrator; CLI sessions
    # carry no elevation path, so promotion MUST NOT unlock either CLI profile.
    intent = intent_snapshot()
    for role in ("member", "stranger"):
        for target in ("profile-customer", customer_vm):
            for command in ("stop", "start", "rm"):
                porsche(
                    command + " " + target + " --request-id " + str(uuid.uuid4()),
                    role=role,
                    expected_error="forbidden",
                )
            porsche("show " + target, role=role, expected_error="forbidden")
        porsche(f"request show {stop_key}", role=role, expected_error="not_found")
    promoted = operator(dict(action="customer-promote-admin", member_id=str(users["member_id"])))
    assert promoted.get("administrator") is True
    me = porsche("whoami", role="member")
    assert object_fields(me["result"])["id"] == str(users["member_id"])
    promoted_refusals = ["profile-customer", customer_vm, "profile-ssh-oss"]
    for target in promoted_refusals:
        porsche(
            "stop " + target + " --request-id " + str(uuid.uuid4()),
            role="member",
            expected_error="forbidden",
        )
    porsche("show " + customer_vm, role="member", expected_error="forbidden")
    porsche(f"request show {stop_key}", role="member", expected_error="not_found")
    assert intent_snapshot() == intent

with subtest("Customer machine page refuses the member in the browser"):
    assert str(uuid.UUID(customer_vm)) == customer_vm
    client.succeed("install -m 600 -o tester -g users /dev/null " + browser_root + "/customer-vm")
    client.succeed(
        "sudo -u tester printf %s "
        + shlex.quote(customer_vm)
        + " >"
        + browser_root
        + "/customer-vm"
    )
    refreshed = operator(
        dict(
            action="refresh-browser-tokens",
            source=root + "/users.json",
            output=root + "/users-refreshed.json",
        )
    )
    assert refreshed.get("refreshed") is True
    transfer(m1, root + "/users-refreshed.json", client, browser_root + "/users.json")
    client.succeed(
        f"chown tester:users {browser_root}/users.json && chmod 600 {browser_root}/users.json"
    )
    client.succeed(
        "sudo -u tester env HOME=/home/tester fleet-default-oss-browser refusal", timeout=180
    )

with subtest("actual OSS guests reach the live local origin and Customer egress times out"):
    egress.wait_for_unit("fleet-egress.service")
    for host in provisioners:
        assert (
            host.succeed("curl --fail --silent http://11.0.0.1:8080/").strip()
            == "fixture-egress-ok"
        )
    for vm, profile in (
        (browser_vm, "oss"),
        (ssh_vm, "oss"),
        (customer_vm, "customer"),
        (browser_vm, "oss"),
    ):
        host, placement_id = current_placement(vm)
        host.succeed("fleet-default-oss-guest " + profile + " " + placement_id, timeout=180)
    assert (
        sql("SELECT count(*) FROM compute_virtual_machines WHERE observed_state='running'") == "3"
    )

with subtest("Customer owner CLI removal destroys the guest and pins the archived receipt"):
    # @cc [owner:ghuntley,label:verification;recovery] customer-cli-removal-physical
    # Owner rm MUST traverse the real CLI, archive the machine only after the
    # physical deleted outcome, release compute/disk holds, and verify real
    # Firecracker/ZFS death. The succeeded receipt MUST stay owner-readable and
    # pinned; every non-owner receipt or lifecycle entry MUST keep refusing
    # with zero durable rows.
    remove_key = str(uuid.uuid4())
    removed = porsche(f"rm profile-customer --request-id {remove_key} --timeout 600")
    replay = porsche(f"rm profile-customer --request-id {remove_key} --timeout 600")
    assert replay.get("operation_id") == removed.get("operation_id")
    assert replay.get("request_id") == removed.get("request_id")
    assert observed_state(customer_vm) == "deleted"
    assert (
        sql(
            f"SELECT archived_at IS NOT NULL FROM compute_virtual_machines WHERE id='{customer_vm}'"
        )
        == "t"
    )
    host, placement_id = current_placement(customer_vm)
    child = "zroot/lilly/vm-" + placement_id
    assert (
        sql(
            "SELECT compute_held::text || ':' || disk_held::text FROM compute_reservations "
            f"WHERE vm_id='{customer_vm}'"
        )
        == "false:false"
    )
    host.fail("systemctl is-active lilly-vm-" + placement_id + ".service")
    host.fail("test -d /sys/fs/cgroup/lilly.slice/lilly-vm-" + placement_id + ".service")
    host.fail("zfs list " + child)
    shown_remove = porsche(f"request show {remove_key}")
    assert shown_remove.get("status") == "succeeded"
    assert shown_remove.get("operation_id") == removed.get("operation_id")
    result_remove = object_fields(shown_remove["result"])
    assert result_remove["id"] == customer_vm
    porsche(f"request show {remove_key}", role="member", expected_error="not_found")
    porsche(f"request show {remove_key}", role="stranger", expected_error="not_found")
    porsche("start profile-customer --request-id " + str(uuid.uuid4()), expected_error="forbidden")
    porsche(
        "stop profile-customer --request-id " + str(uuid.uuid4()),
        role="member",
        expected_error="forbidden",
    )
    assert sql("SELECT count(*) FROM compute_virtual_machines WHERE archived_at IS NULL") == "2"
    intent = intent_snapshot()
    porsche(f"rm profile-customer --request-id {remove_key} --timeout 600 --no-wait")
    assert intent_snapshot() == intent
