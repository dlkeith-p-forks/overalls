# @cc [owner:ghuntley,label:verification;security] fleet-user-porsche-overalls-shell
# The owner MUST register a key through Porsche, create a fresh Firecracker VM
# through its native SSH command, configure the packaged Overalls CLI, and reach
# a PTY login shell as the email-derived account with its own writable home.
# The registered key MUST use a nondefault filename so the nested Audi proxy
# proves it offers the setup-selected identity instead of default SSH keys.
# A VM owner with zero registered keys MUST receive guidance before browser
# approval, then reach the same VM with the newly approved key.
# The installer MUST establish CA trust without console-derived host pins.
# The console MUST NOT start SSH services or inject an authorization outcome.
# A revoked account key MUST close both guest SSH and Porsche account proof
# until the key is re-registered through the real domain action.
# Secrets stay inside the fixture.
import base64
import hashlib
import re
from typing import TypedDict


class JourneyResult(TypedDict, total=False):
    id: str
    host: str
    ssh_host: str
    guest_username: str
    public_key: str
    destination_vm_id: str


class JourneyReceipt(TypedDict):
    version: int
    status: str
    result: JourneyResult


def refresh_journey_browser_tokens() -> None:
    token_path = f"{root}/porsche-journey-users-{uuid.uuid4()}.json"
    operator(
        m1,
        dict(
            action="refresh-browser-tokens",
            source=root + "/users.json",
            output=token_path,
        ),
    )
    transfer(m1, token_path, client, porsche_root + "/users.json")
    client.succeed(
        f"chown tester:users {porsche_root}/users.json && chmod 600 {porsche_root}/users.json"
    )


def starship_shell_probe() -> str:
    """@cc [owner:ghuntley,label:verification] journey-managed-user-starship
    Managed accounts MUST execute Bash with an active Starship hook in actual
    SSH PTYs, nested interactive login/non-login shells and after reconciliation
    and restart. Noninteractive commands MUST retain their exact stdout.
    """
    hook = (
        'test -n "$BASH_VERSION" && test "$STARSHIP_SHELL" = bash && '
        "command -v starship >/dev/null && declare -F starship_precmd >/dev/null && "
        "[[ ${PROMPT_COMMAND[*]} == *starship_precmd* ]] && "
        'test "$(readlink /proc/$$/exe)" = "$(readlink -f "$(command -v bash)")" && '
        'test "$(readlink -f "$(getent passwd "$(id -un)" | cut -d: -f7)")" = '
        '"$(readlink -f "$(command -v bash)")"'
    )
    return (
        hook
        + " && shopt -q login_shell && "
        + shlex.join(["bash", "-ic", hook + " && ! shopt -q login_shell"])
        + " && "
        + shlex.join(["bash", "-lic", hook + " && shopt -q login_shell"])
        + ' && test "$(bash -c "printf prompt-clean"; printf "!")" = prompt-clean!'
        + ' && test "$(bash -lc "printf prompt-clean"; printf "!")" = prompt-clean!'
    )


with subtest("Audi wildcard and gateway are ready for a new Porsche VM"):
    for machine in (m2, m3):
        token = f"{root}/audi-{machine.name}.token"
        operator(
            m1, dict(action="audi-enroll", role="dns", name="audi-" + machine.name, output=token)
        )
        transfer(m1, token, machine, root + "/audi.token")
        machine.wait_for_unit("audi-dns.service")
        machine.wait_for_open_port(53)
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
    # The real ACME state machine advances on minute scheduler ticks through
    # order, DNS proof, finalization and download after DNS enrollment completes.
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

with subtest("owner registers their local SSH key through Porsche"):
    porsche_root = "/var/lib/fleet-porsche"
    m1.succeed(f"fleet-op gateway-prepare {root}/porsche.token")
    m1.succeed(f"fleet-op gateway-configure fleet {root}/porsche.token")
    m1.succeed("systemctl start porsche.service")
    m1.wait_for_open_port(22)
    client.succeed(
        f"install -d -m 700 -o tester -g users {porsche_root} "
        "/home/tester/.ssh /home/tester/.local/bin /home/tester/.pki/nssdb"
    )
    client.succeed("sudo -u tester certutil -N -d sql:/home/tester/.pki/nssdb --empty-password")
    client.succeed(f"install -m 644 {root}/ca.crt {porsche_root}/ca.crt")
    client.succeed(
        f"sudo -u tester certutil -A -d sql:/home/tester/.pki/nssdb "
        f"-n fleet-root -t 'C,,' -i {porsche_root}/ca.crt"
    )
    client.succeed("sudo -u tester ssh-keygen -q -t ed25519 -N '' -f /home/tester/.ssh/work_key")
    client.succeed(f"cp /home/tester/.ssh/work_key.pub {porsche_root}/owner.pub")
    client.succeed(f"sudo -u tester ssh-keygen -q -t ed25519 -N '' -f {porsche_root}/member")
    gateway_key = m1.succeed("ssh-keygen -y -f " + root + "/ssh-host-ca").strip()
    client.succeed(
        "printf '%s\\n' "
        + shlex.quote("@cert-authority * " + gateway_key)
        + f" >{porsche_root}/known_hosts"
    )
    refresh_journey_browser_tokens()
    client.succeed("sudo -u tester env HOME=/home/tester fleet-porsche-browser add", timeout=120)

    # Keep a specific Porsche host entry below the CLI-managed wildcard block.
    # The account proof uses the local OS name while Porsche resolves the key.
    porsche_ssh = (
        "Host control.example.test\n"
        "  HostName m1\n"
        "  IdentityFile ~/.ssh/work_key\n"
        "  IdentitiesOnly yes\n"
        "  BatchMode yes\n"
        "  StrictHostKeyChecking yes\n"
        "  GlobalKnownHostsFile /dev/null\n"
        "  HostKeyAlias control.example.test\n"
    )
    client.succeed("printf '%s' " + shlex.quote(porsche_ssh) + " >/home/tester/.ssh/config")
    client.succeed(
        "chown tester:users /home/tester/.ssh/config && chmod 600 /home/tester/.ssh/config"
    )
    client.succeed("rm /home/tester/.ssh/work_key.pub")

with subtest("Porsche creates a fresh physical VM and Overalls configures the user alias"):
    porsche_args = [
        "/run/current-system/sw/bin/ssh",
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
        "GlobalKnownHostsFile=/dev/null",
        "-o",
        "UserKnownHostsFile=" + porsche_root + "/known_hosts",
        "-o",
        "HostKeyAlias=control.example.test",
        "-i",
        "/home/tester/.ssh/work_key",
        "fixture@m1",
    ]

    # @cc [owner:ghuntley,label:verification;capacity] journey-retries-only-refused-admission
    # Initial creation may retry only the closed insufficient_capacity refusal
    # for at most sixty seconds using identical command/request identity. Never
    # manufacture observations or retry an accepted, failed or uncertain effect.
    # Rejections MUST expose only allowlisted status/error/phase/wait categories,
    # never response payloads, identifiers or raw stderr.
    def porsche_journey(command: str, retry_capacity: bool = False) -> JourneyReceipt:
        arguments = [*porsche_args, command + " --json"]
        program = (
            "import subprocess,json; p=subprocess.run("
            + repr(arguments)
            + ",stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=660); "
            "v=json.loads(p.stdout); "
            "assert isinstance(v,dict) and v.get('version')==1, 'Invalid Porsche response'; "
            "status=v.get('status'); error=v.get('error'); result=v.get('result'); "
            "phase=result.get('phase') if isinstance(result,dict) else None; "
            "safe_status=status if status in ('accepted','succeeded','failed','cancelled','error') else 'unknown'; "
            "safe_wait='timed_out' if v.get('wait_status')=='timed_out' else 'unknown'; "
            "safe_error=error if error in ('insufficient_capacity','timeout','transport_error','invalid_response','conflict') else 'unknown'; "
            "safe_phase=phase if phase in ('queued','preparing','stopping','capturing','copying','publishing','cleaning','complete','cancelling','cancelled','failed') else 'unknown'; "
            "assert (p.returncode==0 and v.get('status')=='succeeded') or ("
            + repr(retry_capacity)
            + " and v.get('status')=='error' and v.get('error')=='insufficient_capacity'), "
            "'Porsche command rejected: status='+safe_status+' error='+safe_error+' phase='+safe_phase+' wait='+safe_wait; "
            "print(json.dumps(v))"
        )
        deadline = time.monotonic() + 60
        while True:
            assert time.monotonic() < deadline, "Measured admission remained unavailable"
            raw = client.succeed(
                "sudo -u tester env HOME=/home/tester python3 -c " + shlex.quote(program),
                timeout=680,
            )
            parsed: object = json.loads(raw)
            assert isinstance(parsed, dict)
            envelope: dict[str, object] = {}
            for parsed_key, parsed_value in parsed.items():
                assert isinstance(parsed_key, str)
                envelope[parsed_key] = parsed_value
            if envelope.get("status") != "error":
                break
            assert retry_capacity and envelope.get("error") == "insufficient_capacity"
            assert time.monotonic() < deadline, "Measured admission remained unavailable"
            time.sleep(1)
        version = envelope.get("version")
        status = envelope.get("status")
        fields: object = envelope.get("result")
        assert isinstance(version, int) and isinstance(status, str) and isinstance(fields, dict)
        assert version == 1 and status == "succeeded"
        field_map: dict[str, object] = {}
        for field_key, field_value in fields.items():
            assert isinstance(field_key, str)
            field_map[field_key] = field_value
        result: JourneyResult = {}
        for name in ("id", "host", "ssh_host", "guest_username", "public_key", "destination_vm_id"):
            field = field_map.get(name)
            if field is not None:
                assert isinstance(field, str)
                result[name] = field
        return JourneyReceipt(version=version, status=status, result=result)

    account = porsche_journey("whoami")["result"]
    owner_email = users["owner_email"]
    assert isinstance(owner_email, str)
    remote_username = account["guest_username"]
    owner_id = users["owner_id"]
    assert isinstance(owner_id, str)
    assert remote_username == canonical_guest_name(owner_id)
    assert account["guest_username"] == remote_username
    request = str(uuid.uuid4())
    image_id: object = users.get("image_id")
    assert isinstance(image_id, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", image_id)
    print(
        json.dumps(
            {
                "event": "fixture.admission_snapshot",
                "hosts": sql_json(
                    "SELECT json_agg(json_build_object('id',id,'enabled',enabled,'mode',maintenance_mode,'fresh',reported_at > (statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds','ready',inventory->'execution_ready','images',inventory->'images','age_ms',extract(epoch from ((statement_timestamp() AT TIME ZONE 'UTC') - reported_at))*1000,'capacity',capacity,'cpu_margin',overhead_cores,'memory_margin',overhead_memory_bytes)) FROM compute_hosts"
                ),
                "image": sql_json(
                    "SELECT json_build_object('memory',minimum_memory_bytes,'disk',minimum_disk_bytes) FROM compute_images WHERE id='"
                    + image_id
                    + "'"
                ),
                "pools": sql_json(
                    "SELECT json_agg(json_build_object('id',id,'free',free_bytes,'margin',overhead_bytes,'fresh',reported_at > (statement_timestamp() AT TIME ZONE 'UTC') - interval '5 seconds')) FROM compute_storage_pools"
                ),
            }
        )
    )
    created = porsche_journey(
        f"new --profile standard --name journey-fresh --cpu 2 "
        f"--image {users['image_id']} --timeout 600 --request-id {request}",
        retry_capacity=True,
    )
    vm_id = created["result"]["id"]
    assert str(uuid.UUID(vm_id)) == vm_id
    await_running(vm_id)
    # @cc [owner:ghuntley,label:verification;durability] native-ssh-durable-slo-restart
    # The real Porsche-created guest MUST establish all three retained physical
    # measurements, including verified readiness. Marshall restart and repeated
    # reconciliation MUST preserve their nonzero counters, buckets and lifetimes.
    eventually(
        lambda: durable_service_level_snapshot(m1, vm_id, require_ssh=True) != "",
        timeout=120,
    )
    before_restart = durable_service_level_snapshot(m1, vm_id, require_ssh=True)
    m1.succeed("systemctl restart marshall-m1.service")
    m1.wait_for_unit("marshall-m1.service")
    assert durable_service_level_snapshot(m1, vm_id, require_ssh=True) == before_restart
    assert durable_service_level_snapshot(m1, vm_id, require_ssh=True) == before_restart
    placement = sql_json(
        f"SELECT json_build_object('vm_id',v.id,'placement_id',p.id,'host_id',p.host_id) "
        f"FROM compute_virtual_machines v JOIN compute_workload_placements p "
        f"ON p.id=v.current_placement_id WHERE v.id='{vm_id}'"
    )
    assert isinstance(placement, dict) and placement["vm_id"] == vm_id
    host = host_for(placement)
    host.wait_until_succeeds(
        "fleet-audi-guest ssh-host-key "
        + shlex.quote(placement["placement_id"])
        + f" {root}/journey-guest-host.pub",
        timeout=240,
    )
    shown = porsche_journey("show journey-fresh")["result"]
    assert shown["host"] == host.name
    hostname = shown["ssh_host"]
    assert hostname == "v-journey-fresh-" + vm_id.replace("-", "") + ".apps.example.test"

with subtest("VM owner with zero registered SSH keys receives actionable onboarding"):
    refresh_journey_browser_tokens()
    client.succeed(
        "sudo -u tester env HOME=/home/tester fleet-porsche-browser remove-owner", timeout=120
    )
    owner_id = users["owner_id"]
    assert isinstance(owner_id, str)
    assert str(uuid.UUID(owner_id)) == owner_id
    assert sql(f"SELECT owner_id FROM compute_virtual_machines WHERE id='{vm_id}'") == owner_id
    assert (
        sql(f"SELECT count(*) FROM ssh_keys WHERE user_id='{owner_id}' AND archived_at IS NULL")
        == "0"
    )
    # Offer a fresh, never-registered key from the owner's client after clearing
    # their profile. Ownership alone must not let an unregistered key into SSH.
    client.succeed("mv /home/tester/.ssh/work_key /home/tester/.ssh/bootstrap_key")
    client.succeed("sudo -u tester ssh-keygen -q -t ed25519 -N '' -f /home/tester/.ssh/work_key")
    client.succeed(f"cp /home/tester/.ssh/work_key.pub {porsche_root}/owner.pub")
    audi_key = host.succeed("cat /var/lib/audi/keys/ssh_host_ed25519_key.pub").strip()
    digest = (
        base64.b32encode(hashlib.sha256(base64.b64decode(audi_key.split()[1])).digest())
        .decode()
        .lower()
        .rstrip("=")
    )
    audi_alias = "audi-" + digest + ".ssh.control.example.test"
    client.succeed(
        "printf '%s\\n' "
        + shlex.quote("@cert-authority * " + gateway_key)
        + f" >{porsche_root}/audi-known-hosts"
    )
    direct_args = [
        "ssh",
        "-F",
        "/dev/null",
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "IdentityAgent=none",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        f"UserKnownHostsFile={porsche_root}/audi-known-hosts",
        "-o",
        "HostKeyAlias=" + audi_alias,
        "-o",
        "HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com",
        "-i",
        "/home/tester/.ssh/work_key",
    ]
    for terminal_option in ("-T", "-tt"):
        command = shlex.join([*direct_args, terminal_option, "root@" + hostname])
        status, _ = client.execute(
            f"timeout 15 {command} </dev/null >{porsche_root}/direct.out 2>{porsche_root}/direct.err"
        )
        output = client.succeed(f"cat {porsche_root}/direct.err")
        # @cc [owner:ghuntley,label:verification;security] direct-ssh-failure-redaction
        # Unexpected exits MUST expose only a fixed diagnostic category; SSH
        # stderr may contain identity or onboarding data and MUST NOT be logged.
        reason = "unclassified"
        for marker, category in (
            ("Could not resolve hostname", "name_resolution"),
            ("Connection refused", "connection_refused"),
            ("Connection timed out", "connection_timeout"),
            ("Host key verification failed", "host_trust"),
            ("Permission denied", "authentication"),
            ("Connection closed", "connection_closed"),
            ("Connection reset", "connection_reset"),
        ):
            if marker in output:
                reason = category
                break
        assert status == 1, f"unexpected direct SSH exit status: {status} ({reason})"
        assert "We don't recognize this SSH key" in output
        assert "ssh control.example.test" in output
        assert "without root@" in output
        assert "PTY allocation request failed" not in output
        client.succeed(f"test ! -s {porsche_root}/direct.out")
    command = shlex.join(
        [*direct_args, "-T", "audi@" + hostname, "connect", hostname.split(".")[0]]
    )
    status, _ = client.execute(
        f"timeout 15 {command} >{porsche_root}/direct.out 2>{porsche_root}/direct.err"
    )
    assert status == 1, f"unexpected proxy SSH exit status: {status}"
    assert "We don't recognize this SSH key" in client.succeed(f"cat {porsche_root}/direct.err")
    client.succeed(f"test ! -s {porsche_root}/direct.out")
    assert sql(f"SELECT count(*) FROM ingress_sessions WHERE vm_id='{vm_id}'") == "0"

    # Reuse Porsche's real browser approval fixture, then verify Audi observes
    # the registration without a cached decision or an invented account actor.
    approval_args = [
        "ssh",
        "-S",
        f"{porsche_root}/approval-control",
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
        "StrictHostKeyChecking=yes",
        "-o",
        f"UserKnownHostsFile={porsche_root}/known_hosts",
        "-o",
        "HostKeyAlias=control.example.test",
        "-i",
        "/home/tester/.ssh/work_key",
        "m1",
        "whoami --json",
    ]
    # Approval is bound to a live proved connection. Keep it open across the
    # JSON exec and browser visit, as the interactive onboarding flow does.
    client.succeed(shlex.join([*approval_args[:-2], "-M", "-N", "-f", "m1"]) + " >/dev/null 2>&1")
    status, _ = client.execute(
        shlex.join([*approval_args[:-1], "whoami"]) + f" >{porsche_root}/management.out"
    )
    assert status == 3, f"unexpected human onboarding exit status: {status}"
    management_output = client.succeed(f"cat {porsche_root}/management.out")
    assert "We don't recognize this SSH key" in management_output
    assert "ssh control.example.test" in management_output
    assert "Keep that connection open" in management_output
    assert "/ssh/approve/" not in management_output
    status, _ = client.execute(shlex.join(approval_args) + f" >{porsche_root}/pending.json")
    assert status == 3, f"unexpected pending approval exit status: {status}"
    client.succeed(f"chown tester:users {porsche_root}/pending.json")
    refresh_journey_browser_tokens()
    client.succeed(
        "sudo -u tester env HOME=/home/tester fleet-porsche-browser approve-owner", timeout=120
    )
    client.succeed(shlex.join([*approval_args[:-2], "-O", "exit", "m1"]))
    assert (
        sql(f"SELECT count(*) FROM ssh_keys WHERE user_id='{owner_id}' AND archived_at IS NULL")
        == "1"
    )
    assert sql(f"SELECT owner_id FROM compute_virtual_machines WHERE id='{vm_id}'") == owner_id
    client.succeed("rm /home/tester/.ssh/work_key.pub")
    command = shlex.join([*direct_args, "-T", "root@" + hostname])
    status, _ = client.execute(
        f"timeout 15 {command} >{porsche_root}/direct.out 2>{porsche_root}/direct.err"
    )
    assert status == 1, f"unexpected recognized-key SSH exit status: {status}"
    output = client.succeed(f"cat {porsche_root}/direct.err")
    assert "Overalls SSH configuration" in output
    assert "don't recognize" not in output
    assert sql(f"SELECT count(*) FROM ingress_sessions WHERE vm_id='{vm_id}'") == "0"
    client.succeed(
        "install -m 755 -o tester -g users /run/current-system/sw/bin/overalls "
        "/home/tester/.local/bin/overalls"
    )
    client.succeed(
        "install -d -m 700 -o tester -g users /home/tester/.local/state /home/tester/.config"
    )
    overalls_environment = (
        "sudo -u tester env -u SSH_AUTH_SOCK HOME=/home/tester "
        "XDG_STATE_HOME=/home/tester/.local/state "
        "XDG_CONFIG_HOME=/home/tester/.config "
        "SSL_CERT_FILE=" + porsche_root + "/ca.crt CURL_CA_BUNDLE=" + porsche_root + "/ca.crt "
    )
    installer = (
        "curl -fsSL https://control.example.test/bin/install.sh | bash -s -- "
        "https://control.example.test apps.example.test " + shlex.quote(hostname)
    )
    install_status, install_output = client.execute(
        "printf '%s\\n' "
        + shlex.quote("printf '%s%s\\n' OVERALLS_INSTALLER _SUCCESS; exit")
        + " | "
        + overalls_environment
        + "script -q -e -c "
        + shlex.quote(installer)
        + " /dev/null",
        timeout=180,
    )
    assert install_status == 0, {
        "status": install_status,
        "signals": [
            message
            for message in [
                "SSH configuration installed",
                "Host key verification failed",
                "Permission denied",
                "Connection closed",
                "Connection refused",
                "Connection timed out",
                "Bad configuration option",
                "No such file or directory",
                "no matching host key type",
                "overalls:",
            ]
            if message in install_output
        ],
    }
    assert "OVERALLS_INSTALLER_SUCCESS" in install_output
    assert "Are you sure you want to continue" not in install_output
    assert "authenticity of host" not in install_output

    managed = client.succeed("cat /home/tester/.ssh/config")
    assert "Host *.apps.example.test" in managed
    assert "User " + remote_username + "\n" in managed
    assert "IdentityFile ~/.ssh/work_key" in managed
    assert (
        "ProxyCommand '/home/tester/.local/bin/overalls' proxy --host %h --identity work_key"
        in managed
    )

with subtest("Overalls CLI opens an interactive Firecracker Bash shell with Starship and its home"):
    known_hosts = client.succeed("cat /home/tester/.ssh/known_hosts")
    assert "@cert-authority" in known_hosts
    assert hostname not in known_hosts
    shell_commands = (
        f'if test -t 0 && test "$HOME" = /home/{remote_username} '
        '&& test -d "$HOME" && test -w "$HOME" '
        "&& "
        + starship_shell_probe()
        + "; then printf '\\n%s%s\\n' OVERALLS_INTERACTIVE _SHELL; exit 0; else exit 1; fi"
    )
    ssh_args = [
        "/run/current-system/sw/bin/ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "GlobalKnownHostsFile=/dev/null",
        hostname,
    ]
    ssh_environment = overalls_environment + "TERM=xterm-256color "

    def assert_interactive_starship(arguments: list[str]) -> None:
        """@cc [owner:ghuntley,label:verification;security] journey-prompt-private-output
        PTY assertions MUST match an executed complete marker line, never echoed
        input. Terminal bytes MUST stay in a private fixture file on failure.
        """
        output_path = f"{porsche_root}/prompt-{uuid.uuid4()}.private"
        status, _ = client.execute(
            "printf '%s\\n' "
            + shlex.quote(shell_commands)
            + " | "
            + ssh_environment
            + shlex.join(arguments)
            + " >"
            + shlex.quote(output_path)
            + " 2>&1",
            timeout=60,
        )
        assert status == 0, "Guest Bash/Starship startup failed; terminal bytes withheld"
        client.succeed(
            "tr -d '\\r' <" + shlex.quote(output_path) + " | grep -Fxq OVERALLS_INTERACTIVE_SHELL"
        )

    # @cc [owner:ghuntley,label:verification] journey-ssh-command-and-shell
    # Both a non-interactive remote command and a real PTY login MUST work
    # through the generated Overalls wildcard ProxyCommand.
    assert (
        client.wait_until_succeeds(
            ssh_environment + shlex.join([*ssh_args, "whoami"]), timeout=180
        ).strip()
        == remote_username
    )
    assert (
        client.succeed(ssh_environment + shlex.join([*ssh_args, "pwd"]), timeout=60).strip()
        == "/home/" + remote_username
    )
    assert (
        client.succeed(ssh_environment + shlex.join([*ssh_args, "printf prompt-clean"]), timeout=60)
        == "prompt-clean"
    )
    assert (
        client.succeed(
            ssh_environment + shlex.join([*ssh_args, "stat -c '%U:%a' \"$HOME\""]),
            timeout=60,
        ).strip()
        == remote_username + ":700"
    )
    # @cc [owner:ghuntley,label:verification;security] ubuntu-guest-nix-registry-usable
    # After real Ubuntu guest SSH, the installed Nix CLI MUST find the pinned
    # development-tools closure in its normalized guest-local registry. This
    # proves runtime registration access, not cross-host rootfs equality; only
    # a fixed verdict may leave the guest, never registry rows or guest bytes.
    if ubuntu_enabled:
        assert (
            client.succeed(
                ssh_environment
                + shlex.join(
                    [
                        *ssh_args,
                        "root=$(readlink /usr/local/bin/devenv); "
                        'test "${root#/nix/store/}" != "$root" && '
                        'store=$(dirname "$(dirname "$root")") && '
                        'sudo /usr/bin/nix-store --query --hash "$store" >/dev/null && '
                        "printf guest-nix-registry-valid",
                    ]
                ),
                timeout=60,
            ).strip()
            == "guest-nix-registry-valid"
        )
    # @cc [owner:ghuntley,label:verification;security] journey-boot-ready-journal-native
    # After authenticated guest SSH, the fixture MUST validate the current
    # host-local production journal against the actual running intent, exact
    # boot challenge, host/placement and guest boot UUID. The guest boot MUST
    # remain unchanged across the read; only its digest enters a host command.
    guest_boot = client.succeed(
        ssh_environment + shlex.join([*ssh_args, "cat /proc/sys/kernel/random/boot_id"]),
        timeout=60,
    ).strip()
    assert str(uuid.UUID(guest_boot)) == guest_boot
    placement_id = placement["placement_id"]
    host_id = placement["host_id"]
    assert isinstance(placement_id, str) and str(uuid.UUID(placement_id)) == placement_id
    assert isinstance(host_id, str) and str(uuid.UUID(host_id)) == host_id
    digest = hashlib.sha256(guest_boot.encode()).hexdigest()
    assert (
        host.succeed(
            "fleet-provisioning-verify " + shlex.join([placement_id, digest, host_id]),
            timeout=120,
        ).strip()
        == "current-boot-ready"
    )
    assert (
        client.succeed(
            ssh_environment + shlex.join([*ssh_args, "cat /proc/sys/kernel/random/boot_id"]),
            timeout=60,
        ).strip()
        == guest_boot
    )
    stale_digest = hashlib.sha256((guest_boot + "-stale").encode()).hexdigest()
    host.fail(
        "fleet-provisioning-verify " + shlex.join([placement_id, stale_digest, host_id]),
        timeout=120,
    )
    foreign_host = "00000000-0000-4000-8000-000000000001"
    if foreign_host == host_id:
        foreign_host = "00000000-0000-4000-8000-000000000002"
    host.fail(
        "fleet-provisioning-verify " + shlex.join([placement_id, digest, foreign_host]),
        timeout=120,
    )
    interactive_args = [ssh_args[0], "-tt", *ssh_args[1:]]
    assert_interactive_starship(interactive_args)
    # Authority fetches can fail closed and recover through the guest timer.
    # Require two successful refreshes within a bound before checking the shell.
    for _ in range(2):
        client.wait_until_succeeds(
            ssh_environment
            + shlex.join([*ssh_args, "sudo systemctl start overalls-ssh-sync.service"]),
            timeout=60,
        )
    assert_interactive_starship(interactive_args)
    browser_probe(
        ProvisionedPlacement(
            vm_id=vm_id, placement_id=placement_id, host_id=host_id, accepted=True
        ),
        prompt_only=True,
    )
    eventually(
        lambda: (
            int(
                sql(
                    "SELECT count(*) FROM ssh_guest_logins WHERE "
                    f"vm_id='{vm_id}' AND user_id='{users['owner_id']}'"
                )
            )
            >= 1
        ),
        timeout=30,
    )

with subtest("a lilly-hostd restart ends live guest SSH and new sessions reconnect"):
    # @cc [owner:ghuntley,label:verification;isolation] journey-hostd-restart-ends-bridges
    # Each ingress bridge is a child of the lilly-hostd session that started it
    # (ADR-0184), so restarting hostd MUST end a live guest SSH session and leave
    # no lilly-ingress-bridge process; the guest MUST keep its boot and a new
    # session MUST reach it through the restarted hostd.
    bridges = "pgrep -u lilly -f '/lilly-ingress-bridge 3 4'"
    client.succeed(
        ssh_environment
        + shlex.join([*ssh_args, "printf live-session-open; exec sleep 600"])
        + " >/tmp/live-guest-ssh.out 2>&1 </dev/null & echo $! >/tmp/live-guest-ssh.pid"
    )
    client.wait_until_succeeds("grep -q live-session-open /tmp/live-guest-ssh.out", timeout=120)
    host.wait_until_succeeds(bridges, timeout=30)
    host.succeed("systemctl restart lilly-hostd.service")
    client.wait_until_succeeds('! kill -0 "$(cat /tmp/live-guest-ssh.pid)"', timeout=60)
    host.wait_until_fails(bridges, timeout=30)
    host.succeed("systemctl is-active lilly.service")
    assert (
        client.wait_until_succeeds(
            ssh_environment + shlex.join([*ssh_args, "cat /proc/sys/kernel/random/boot_id"]),
            timeout=120,
        ).strip()
        == guest_boot
    )
    host.wait_until_fails(bridges, timeout=30)

with subtest("email change preserves native identity, home, SSH configuration and running boot"):
    # @cc [owner:ghuntley,label:verification;security] journey-mailbox-identity-continuity
    # A mailbox edit MUST preserve the stored GuestAccount UUID/UID, guest files,
    # numeric ownership, installed SSH configuration and physical boot. A real
    # roster refresh and a new strict SSH connection MUST retain the same login.
    identity_sql = f"SELECT id,username,uid FROM account_guest_accounts WHERE user_id='{owner_id}' AND retired_at IS NULL"
    before_identity = sql(identity_sql)
    before_config = client.succeed("cat /home/tester/.ssh/config")
    before_intent = sql(
        f"SELECT generation,execution_epoch,current_placement_id FROM compute_virtual_machines WHERE id='{vm_id}'"
    )
    uid = int(remote_username[1:])
    marker_command = 'printf mailbox-continuity > "$HOME/mailbox-continuity"'
    client.succeed(ssh_environment + shlex.join([*ssh_args, marker_command]), timeout=60)
    changed_email = "identity-changed-" + owner_id + "@example.test"
    try:
        assert (
            operator(m1, dict(action="identity-email", user_id=owner_id, email=changed_email))[
                "updated"
            ]
            is True
        )
        assert porsche_journey("whoami")["result"]["guest_username"] == remote_username
        client.succeed(
            ssh_environment
            + shlex.join([*ssh_args, "sudo systemctl start overalls-ssh-sync.service"]),
            timeout=60,
        )
        continuity_command = (
            f'test "$(id -un)" = {remote_username} && test "$(id -u)" = {uid} '
            f'&& test "$(id -g)" = {uid} && test "$HOME" = /home/{remote_username} '
            '&& test "$(cat "$HOME/mailbox-continuity")" = mailbox-continuity '
            f'&& test "$(stat -c %u:%g "$HOME/mailbox-continuity")" = {uid}:{uid} '
            f'&& test "$(cat /proc/sys/kernel/random/boot_id)" = {guest_boot}'
        )
        client.succeed(ssh_environment + shlex.join([*ssh_args, continuity_command]), timeout=60)
        assert sql(identity_sql) == before_identity
        assert client.succeed("cat /home/tester/.ssh/config") == before_config
        assert (
            sql(
                f"SELECT generation,execution_epoch,current_placement_id FROM compute_virtual_machines WHERE id='{vm_id}'"
            )
            == before_intent
        )
    finally:
        assert (
            operator(m1, dict(action="identity-email", user_id=owner_id, email=owner_email))[
                "updated"
            ]
            is True
        )

with subtest("account-key revocation closes guest SSH and Porsche until re-registration"):
    # @cc [owner:ghuntley,label:verification;security] journey-late-revocation-fails-closed
    # One revoke→probe→re-register cycle: a withdrawn account key MUST close
    # guest SSH and Porsche account proof with publickey refusal, and
    # re-registering the same key through the real domain action MUST restore
    # both without touching installed trust, config or the CLI binary.
    def active_owner_keys() -> list[dict[str, str]]:
        rows: object = sql_json(
            "SELECT coalesce(json_agg(json_build_object('id',id,'fingerprint',fingerprint)), '[]') "
            f"FROM ssh_keys WHERE user_id='{owner_id}' AND archived_at IS NULL"
        )
        assert isinstance(rows, list)
        keys: list[dict[str, str]] = []
        for raw_row in rows:
            assert isinstance(raw_row, dict)
            row: dict[str, object] = {
                key: value for key, value in raw_row.items() if isinstance(key, str)
            }
            assert len(row) == len(raw_row)
            key_id = row.get("id")
            fingerprint = row.get("fingerprint")
            assert isinstance(key_id, str) and isinstance(fingerprint, str)
            keys.append({"id": key_id, "fingerprint": fingerprint})
        return keys

    [revoked] = active_owner_keys()
    # The unattended fixture cannot hold the live MFA elevation the
    # administrator revocation action requires, so the owner withdraws their
    # own key through the real owner-scoped action.
    operator(m1, dict(action="audi-ssh-revoke", owner_id=owner_id, key_id=revoked["id"]))
    assert active_owner_keys() == []
    assert (
        sql(f"SELECT count(*) FROM ssh_keys WHERE id='{revoked['id']}' AND archived_at IS NOT NULL")
        == "1"
    )
    status, _ = client.execute(
        f"{shlex.join([*porsche_args, 'whoami --json'])} "
        f">{porsche_root}/revoked-whoami.out 2>{porsche_root}/revoked-whoami.err"
    )
    # Porsche refuses the revoked key at the account layer: the exec returns the
    # onboarding approval receipt (status 3), never a succeeded JSON proof.
    assert status == 3, f"unexpected revoked Porsche exit status: {status}"
    whoami_refusal = client.succeed(f"cat {porsche_root}/revoked-whoami.out")
    assert '"status":"approval_required"' in whoami_refusal
    assert '"status":"succeeded"' not in whoami_refusal
    guest_status, _ = client.execute(
        ssh_environment
        + shlex.join([*ssh_args, "whoami"])
        + f" >{porsche_root}/revoked-guest.out 2>{porsche_root}/revoked-guest.err",
        timeout=60,
    )
    assert guest_status != 0, f"unexpected revoked guest exit status: {guest_status}"
    guest_refusal = client.succeed(f"cat {porsche_root}/revoked-guest.err")
    assert (
        "We don't recognize this SSH key" in guest_refusal
        or "Permission denied (publickey" in guest_refusal
        or "Connection closed" in guest_refusal
    )
    assert client.succeed(f"cat {porsche_root}/revoked-guest.out").strip() == ""
    operator(
        m1,
        dict(
            action="audi-ssh-key",
            owner_id=owner_id,
            public_key=client.succeed(f"cat {porsche_root}/owner.pub").strip(),
        ),
    )
    [restored] = active_owner_keys()
    assert restored["fingerprint"] == revoked["fingerprint"]
    assert restored["id"] != revoked["id"]
    account = porsche_journey("whoami")["result"]
    assert account["guest_username"] == remote_username
    fingerprint = client.succeed(
        "sudo -u tester ssh-keygen -lf /home/tester/.ssh/overalls-identity.pub"
    ).split()[1]
    assert fingerprint == restored["fingerprint"]
    identity_public = client.succeed("cat /home/tester/.ssh/overalls-identity.pub")
    assert account["public_key"].split()[:2] == identity_public.split()[:2]
    assert (
        client.wait_until_succeeds(
            ssh_environment + shlex.join([*ssh_args, "whoami"]), timeout=180
        ).strip()
        == remote_username
    )

with subtest("Overalls uses an agent-only SSH key from a quoted Host * IdentityAgent path"):
    # @cc [owner:ghuntley,label:verification;security] journey-custom-agent-socket
    # Porsche proof and the isolated Audi proxy MUST use the same agent socket
    # when Host * selects a path containing spaces and SSH_AUTH_SOCK is absent.
    agent_dir = "/home/tester/Library/Group Containers/Overalls"
    agent_socket = agent_dir + "/agent.sock"
    client.succeed("install -d -m 700 -o tester -g users " + shlex.quote(agent_dir))
    client.succeed("sudo -u tester ssh-agent -a " + shlex.quote(agent_socket))
    client.succeed(
        "sudo -u tester env SSH_AUTH_SOCK="
        + shlex.quote(agent_socket)
        + " ssh-add /home/tester/.ssh/work_key"
    )
    client.succeed("rm /home/tester/.ssh/work_key")
    agent_porsche_ssh = (
        porsche_ssh.replace(
            "IdentityFile ~/.ssh/work_key\n", "IdentityFile ~/.ssh/overalls-identity.pub\n"
        )
        + f'Host *\n  IdentityAgent "{agent_socket}"\n'
    )
    client.succeed("printf '%s' " + shlex.quote(agent_porsche_ssh) + " >/home/tester/.ssh/config")
    porsche_args[porsche_args.index("/home/tester/.ssh/work_key")] = (
        "/home/tester/.ssh/overalls-identity.pub"
    )
    porsche_args[-1:-1] = ["-o", 'IdentityAgent="' + agent_socket + '"']
    client.succeed(
        overalls_environment + "/home/tester/.local/bin/overalls config-ssh "
        "--origin https://control.example.test --zone apps.example.test"
    )
    managed = client.succeed("cat /home/tester/.ssh/config")
    assert "IdentityFile ~/.ssh/overalls-identity.pub" in managed
    assert "--identity overalls-identity.pub" in managed
    assert (
        client.succeed(ssh_environment + shlex.join([*ssh_args, "whoami"]), timeout=60).strip()
        == remote_username
    )

with subtest("Overalls accepts OpenSSH agent variables, tokens and relative sockets"):
    # @cc [owner:ghuntley,label:verification;security] journey-agent-forms
    # Each form MUST prove the same agent-only key to Porsche and Audi.
    agent_config_base = porsche_ssh.replace(
        "IdentityFile ~/.ssh/work_key\n", "IdentityFile ~/.ssh/overalls-identity.pub\n"
    )
    client.succeed("ln -s " + shlex.quote(agent_socket) + " /tmp/overalls-agent-relative.sock")
    agent_variables = " OVERALLS_TEST_AGENT=" + shlex.quote(agent_socket)
    inherited_agent = " SSH_AUTH_SOCK=" + shlex.quote(agent_socket)
    variants: list[tuple[str, str, str]] = [
        ("legacy environment", "$OVERALLS_TEST_AGENT", agent_variables),
        ("braced environment", "${OVERALLS_TEST_AGENT}", agent_variables),
        ("SSH_AUTH_SOCK", "SSH_AUTH_SOCK", inherited_agent),
        ("home token", "%d/Library/Group Containers/Overalls/agent.sock", ""),
        ("relative socket", "./overalls-agent-relative.sock", ""),
        ("inherited socket", "", inherited_agent),
    ]
    for name, setting, extra_environment in variants:
        agent_rule = "Host *\n"
        if setting:
            agent_rule += "  IdentityAgent " + '"' + setting + '"' + "\n"
        client.succeed(
            "printf '%s' "
            + shlex.quote(agent_config_base + agent_rule)
            + " >/home/tester/.ssh/config"
        )
        variant_environment = overalls_environment + extra_environment + " "
        client.succeed(
            variant_environment + "/home/tester/.local/bin/overalls config-ssh "
            "--origin https://control.example.test --zone apps.example.test",
            timeout=60,
        )
        assert (
            client.succeed(
                variant_environment + shlex.join([*ssh_args, "whoami"]), timeout=60
            ).strip()
            == remote_username
        ), name
    client.succeed("printf '%s' " + shlex.quote(agent_porsche_ssh) + " >/home/tester/.ssh/config")
    client.succeed(
        overalls_environment + "/home/tester/.local/bin/overalls config-ssh "
        "--origin https://control.example.test --zone apps.example.test"
    )

with subtest("guest renewal publishes a valid certificate and reloads OpenSSH"):
    certificate_path = "/run/overalls-ssh-host/ssh_host_ed25519_key-cert.pub"
    metadata_path = "/run/overalls-ssh-host/certificate.json"
    original_certificate = client.succeed(
        ssh_environment + shlex.join([*ssh_args, "sudo cat " + certificate_path]), timeout=60
    ).strip()
    guest_key = client.succeed(
        ssh_environment
        + shlex.join([*ssh_args, "sudo cat /run/overalls-ssh-host/ssh_host_ed25519_key.pub"]),
        timeout=60,
    ).strip()
    client.succeed(
        ssh_environment + shlex.join([*ssh_args, "sudo systemctl stop overalls-ssh-sync.timer"]),
        timeout=60,
    )
    m1.succeed("printf '%s\\n' " + shlex.quote(guest_key) + " >/run/renewal-test.pub")
    m1.succeed(
        "ssh-keygen -q -s "
        + root
        + "/ssh-host-ca -I renewal-fixture -h -n "
        + shlex.quote(hostname)
        + " -V -5m:+1d /run/renewal-test.pub"
    )
    near_expiry = m1.succeed("cat /run/renewal-test-cert.pub").strip()
    metadata = json.dumps(
        {
            "version": 1,
            "certificate": near_expiry,
            "principal": hostname,
            "ca": " ".join(gateway_key.split()[:2]),
        }
    )
    client.succeed(
        ssh_environment
        + shlex.join(
            [
                *ssh_args,
                "printf '%s' "
                + shlex.quote(metadata)
                + " | sudo tee "
                + metadata_path
                + " >/dev/null; printf '%s' "
                + shlex.quote(near_expiry)
                + " | sudo tee "
                + certificate_path
                + ".new >/dev/null; sudo mv "
                + certificate_path
                + ".new "
                + certificate_path,
            ]
        ),
        timeout=60,
    )
    scan = "ssh-keyscan -c -t ed25519 127.0.0.1 2>/dev/null"
    client.wait_until_succeeds(
        ssh_environment
        + shlex.join([*ssh_args, scan + " | grep -F " + shlex.quote(near_expiry.split()[1])]),
        timeout=60,
    )
    client.succeed(
        ssh_environment + shlex.join([*ssh_args, "sudo systemctl start overalls-ssh-sync.service"]),
        timeout=60,
    )
    client.wait_until_succeeds(
        ssh_environment
        + shlex.join(
            [*ssh_args, scan + " | grep -F " + shlex.quote(original_certificate.split()[1])]
        ),
        timeout=60,
    )
    client.succeed(
        ssh_environment + shlex.join([*ssh_args, "sudo systemctl start overalls-ssh-sync.timer"]),
        timeout=60,
    )

with subtest("Porsche relocation preserves the Overalls login, account and home"):
    # @cc [owner:ghuntley,label:verification;recovery] journey-ssh-after-relocation
    # The same CA trust and CLI configuration MUST reach a new
    # placement after Porsche moves the VM. The login MUST retain its username,
    # writable home and a file written before the move, and its new placement
    # MUST appear in the durable login audit.
    original_host_key = client.succeed(
        ssh_environment
        + shlex.join([*ssh_args, "sudo cat /run/overalls-ssh-host/ssh_host_ed25519_key.pub"]),
        timeout=60,
    )
    marker = "overalls-ssh-journey-marker"
    client.succeed(
        ssh_environment
        + shlex.join([*ssh_args, f'printf journey-data >"$HOME/{marker}" && test -w "$HOME"']),
        timeout=60,
    )
    source_placement = placement
    relocation_request_key = str(uuid.uuid4())
    porsche_journey(f"relocate journey-fresh --request-id {relocation_request_key} --timeout 600")
    relocated = sql_json(
        "SELECT json_build_object('vm_id',v.id,'placement_id',p.id,'host_id',p.host_id) "
        "FROM compute_virtual_machines v JOIN compute_workload_placements p "
        f"ON p.id=v.current_placement_id WHERE v.id='{vm_id}'"
    )
    assert isinstance(relocated, dict) and relocated["vm_id"] == vm_id
    assert relocated["placement_id"] != source_placement["placement_id"]
    assert relocated["host_id"] != source_placement["host_id"]
    await_running(vm_id)
    destination_host = host_for(relocated)
    assert porsche_journey("show journey-fresh")["result"]["host"] == destination_host.name
    assert (
        client.wait_until_succeeds(
            ssh_environment + shlex.join([*ssh_args, "whoami"]), timeout=180
        ).strip()
        == remote_username
    )
    assert (
        client.succeed(ssh_environment + shlex.join([*ssh_args, "pwd"]), timeout=60).strip()
        == "/home/" + remote_username
    )
    assert (
        client.succeed(
            ssh_environment + shlex.join([*ssh_args, "stat -c '%U:%a' \"$HOME\""]),
            timeout=60,
        ).strip()
        == remote_username + ":700"
    )
    listing = client.succeed(
        ssh_environment
        + shlex.join(
            [
                *ssh_args,
                f'test -d "$HOME" && test -w "$HOME" && '
                f'grep -Fxq journey-data "$HOME/{marker}" && ls -A "$HOME"',
            ]
        ),
        timeout=60,
    )
    assert marker in listing.splitlines()
    assert_interactive_starship(interactive_args)
    eventually(
        lambda: (
            int(
                sql(
                    "SELECT count(*) FROM ssh_guest_logins WHERE "
                    f"vm_id='{vm_id}' AND user_id='{users['owner_id']}' "
                    f"AND placement_id='{relocated['placement_id']}'"
                )
            )
            >= 1
        ),
        timeout=30,
    )

with subtest("reboot and cloning issue distinct keys under unchanged client CA trust"):
    relocated_key = client.succeed(
        ssh_environment
        + shlex.join([*ssh_args, "sudo cat /run/overalls-ssh-host/ssh_host_ed25519_key.pub"]),
        timeout=60,
    )
    assert relocated_key != original_host_key
    relocated_boot = client.succeed(
        ssh_environment + shlex.join([*ssh_args, "cat /proc/sys/kernel/random/boot_id"]),
        timeout=60,
    ).strip()
    assert str(uuid.UUID(relocated_boot)) == relocated_boot
    porsche_journey("stop journey-fresh --timeout 600")
    porsche_journey("start journey-fresh --timeout 600")
    await_running(vm_id)
    rebooted_key = client.wait_until_succeeds(
        ssh_environment
        + shlex.join([*ssh_args, "sudo cat /run/overalls-ssh-host/ssh_host_ed25519_key.pub"]),
        timeout=180,
    )
    assert rebooted_key not in (original_host_key, relocated_key)
    restarted = sql_json(
        "SELECT json_build_object('vm_id',v.id,'placement_id',p.id,'host_id',p.host_id) "
        "FROM compute_virtual_machines v JOIN compute_workload_placements p "
        f"ON p.id=v.current_placement_id WHERE v.id='{vm_id}'"
    )
    assert isinstance(restarted, dict) and restarted["vm_id"] == vm_id
    restart_placement = restarted["placement_id"]
    restart_host_id = restarted["host_id"]
    assert (
        isinstance(restart_placement, str)
        and str(uuid.UUID(restart_placement)) == restart_placement
    )
    assert isinstance(restart_host_id, str) and str(uuid.UUID(restart_host_id)) == restart_host_id
    restart_host = host_for(restarted)
    rebooted_boot = client.succeed(
        ssh_environment + shlex.join([*ssh_args, "cat /proc/sys/kernel/random/boot_id"]),
        timeout=60,
    ).strip()
    assert str(uuid.UUID(rebooted_boot)) == rebooted_boot
    assert rebooted_boot != relocated_boot
    assert_interactive_starship(interactive_args)
    # The currently running boot must be ready; the pre-restart boot may not
    # be reused even when the placement itself stayed on the same host.
    rebooted_digest = hashlib.sha256(rebooted_boot.encode()).hexdigest()
    assert (
        restart_host.succeed(
            "fleet-provisioning-verify "
            + shlex.join([restart_placement, rebooted_digest, restart_host_id]),
            timeout=120,
        ).strip()
        == "current-boot-ready"
    )
    restart_host.fail(
        "fleet-provisioning-verify "
        + shlex.join(
            [
                restart_placement,
                hashlib.sha256(relocated_boot.encode()).hexdigest(),
                restart_host_id,
            ]
        ),
        timeout=120,
    )
    clone_request_key = str(uuid.uuid4())
    clone = porsche_journey(
        f"clone journey-fresh --name journey-copy --request-id {clone_request_key} --timeout 600"
    )
    clone_id = clone["result"]["destination_vm_id"]
    await_running(clone_id)
    clone_hostname = porsche_journey("show journey-copy")["result"]["ssh_host"]
    clone_args = [clone_hostname if arg == hostname else arg for arg in ssh_args]
    cloned_key = client.wait_until_succeeds(
        ssh_environment
        + shlex.join([*clone_args, "sudo cat /run/overalls-ssh-host/ssh_host_ed25519_key.pub"]),
        timeout=180,
    )
    source_key = client.wait_until_succeeds(
        ssh_environment
        + shlex.join([*ssh_args, "sudo cat /run/overalls-ssh-host/ssh_host_ed25519_key.pub"]),
        timeout=180,
    )
    assert cloned_key not in (original_host_key, relocated_key, rebooted_key, source_key)
    assert (
        client.succeed(ssh_environment + shlex.join([*clone_args, "whoami"])).strip()
        == remote_username
    )
    assert client.succeed("cat /home/tester/.ssh/known_hosts") == known_hosts
    # A certificate for the source VM cannot authenticate the clone's hostname.
    client.fail(
        ssh_environment
        + shlex.join([*ssh_args[:-1], "-o", "HostKeyAlias=" + clone_hostname, hostname, "true"]),
        timeout=60,
    )

    # @cc [owner:ghuntley,label:verification;accounting] native-workflow-slo-completion
    # The real Porsche clone and relocation above MUST contribute successful
    # receipt-bound workflow measurements, preserving them across publisher
    # restart. SQL observations MUST NOT refresh receipts or insert evidence.
    # This fleet uses m1/m2/m3, rather than the enrolled Overalls publisher.
    # Invoke both production reconcilers through the sentinel-fenced helper.
    assert durable_service_level_snapshot(m1, vm_id, require_ssh=True)
    for workflow_service, request_key in (
        ("porsche_clone", clone_request_key),
        ("porsche_relocate", relocation_request_key),
    ):
        eventually(
            lambda service=workflow_service, key=request_key: (
                int(
                    sql(
                        "SELECT count(*) FROM compute_workflow_service_level_attempts a "
                        "JOIN ssh_requests r ON r.id=a.request_id "
                        f"WHERE a.service='{service}' AND r.request_id='{key}' "
                        f"AND r.vm_id='{vm_id}' AND a.status='finished' AND a.success IS TRUE"
                    )
                )
                == 1
            ),
            timeout=90,
        )
    workflow_before = sql(
        "SELECT string_agg(service || ':' || requests::text || ':' || successes::text "
        "|| ':' || failures::text || ':' || id::text || ':' || started_at::text, ',' ORDER BY service) "
        "FROM compute_service_level_totals WHERE service IN "
        "('porsche_clone','porsche_relocate','porsche_retry','porsche_cancel')"
    )
    m1.succeed("systemctl restart marshall-m1.service")
    m1.wait_for_unit("marshall-m1.service")
    assert (
        sql(
            "SELECT string_agg(service || ':' || requests::text || ':' || successes::text "
            "|| ':' || failures::text || ':' || id::text || ':' || started_at::text, ',' ORDER BY service) "
            "FROM compute_service_level_totals WHERE service IN "
            "('porsche_clone','porsche_relocate','porsche_retry','porsche_cancel')"
        )
        == workflow_before
    )
