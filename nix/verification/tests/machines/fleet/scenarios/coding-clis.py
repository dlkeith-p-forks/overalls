"""Packaged native coding clients through real guest trust and Ziggy authority."""

from typing import Literal


def coding_cli_fields(value: object) -> dict[str, object]:
    """@cc [owner:ghuntley,label:verification] coding-clis-typed-json-boundary
    Fixture JSON MUST have validated string keys before the driver treats it as
    a typed mapping; model limits and provider counters require further checks.
    """
    assert isinstance(value, dict)
    result: dict[str, object] = {}
    for key, field in value.items():
        assert isinstance(key, str)
        result[key] = field
    return result


def coding_cli_stats() -> dict[str, int]:
    """@cc [owner:ghuntley,label:verification;security] coding-clis-effect-observation
    Provider effect evidence MUST contain only the three bounded counters from
    the isolated TLS fixture's loopback endpoint. Request contents and secrets
    MUST NOT enter the driver or its diagnostics.
    """
    raw = m1.succeed(
        "curl --silent --show-error --fail --max-time 10 --cacert "
        + shlex.quote(coding_cli_provider_ca)
        + " --resolve api.openai.com:443:127.0.0.1 https://api.openai.com/fixture/stats"
    )
    value = coding_cli_fields(json.loads(raw))
    assert set(value) == {"responses", "messages", "count_tokens"}
    result: dict[str, int] = {}
    for key in ("responses", "messages", "count_tokens"):
        counter = value[key]
        assert isinstance(counter, int) and not isinstance(counter, bool) and counter >= 0
        result[key] = counter
    return result


def coding_cli_native(
    mode: Literal["prepare", "terminal", "gc", "tls-refusal", "customer", "token-count"],
    placed: ProvisionedPlacement,
    username: str,
) -> None:
    """@cc [owner:ghuntley,label:verification;security] coding-clis-native-account
    Native probes MUST use the durable GuestAccount username and current real
    Firecracker placement. They MUST invoke installed client commands without
    supplying replacement provider URLs or launchers. Terminal contents MUST
    stay inside the bounded native adapter.
    """
    host_for(placed).succeed(
        shlex.join(["fleet-coding-clis-guest", mode, placed["placement_id"], username]),
        timeout=500,
    )


def coding_cli_ssh_command(arguments: list[str], environment: str, remote: str) -> str:
    """@cc [owner:ghuntley,label:verification;security] coding-clis-authorized-ssh
    Coding-client SSH commands MUST use the actual registered guest account,
    Audi authorization and verified guest host certificates. Native provider
    settings MUST remain intact, client output MUST be discarded and batch
    stdin MUST close immediately so Codex cannot wait for appended prompt input.
    The client MUST receive only a readable public HTTPS CA copy; the root-only
    setup directory and its credentials MUST remain private.
    """
    assert arguments and arguments[0] == "ssh"
    return environment + shlex.join(["ssh", "-n", *arguments[1:], remote]) + " >/dev/null 2>&1"


with subtest("coding-client disk allocation follows the real image manifest"):
    manifest = coding_cli_fields(
        json.loads(Path(coding_cli_guest_image, "manifest.json").read_text())
    )
    minimum_disk = manifest["minimum_disk_bytes"]
    assert isinstance(minimum_disk, int) and not isinstance(minimum_disk, bool)
    minimum_memory = manifest["minimum_memory_bytes"]
    assert isinstance(minimum_memory, int) and not isinstance(minimum_memory, bool)
    coding_cli_disk_bytes = max(minimum_disk, 6_442_450_944)
    coding_cli_memory_bytes = max(minimum_memory, 2_147_483_648)
    owner_id = users["owner_id"]
    assert isinstance(owner_id, str)
    vm = provision_when_available(
        m1, "standard", disk_bytes=coding_cli_disk_bytes, memory_bytes=coding_cli_memory_bytes
    )
    await_running(vm["vm_id"])
    coding_cli_username = canonical_guest_name(owner_id)
    coding_cli_native("prepare", vm, coding_cli_username)

with subtest("native user terminal loads both clients and streams through Ziggy"):
    initial_effects = coding_cli_stats()
    coding_cli_native("terminal", vm, coding_cli_username)
    terminal_effects = coding_cli_stats()
    assert terminal_effects["responses"] > initial_effects["responses"]
    assert terminal_effects["messages"] > initial_effects["messages"]
    coding_cli_native("token-count", vm, coding_cli_username)
    assert coding_cli_stats()["count_tokens"] == terminal_effects["count_tokens"] + 1

with subtest("invalid CA and hostname refuse before a provider effect"):
    before_refusal = coding_cli_stats()
    coding_cli_native("tls-refusal", vm, coding_cli_username)
    assert coding_cli_stats() == before_refusal

with subtest("registered SSH user runs the same native configuration after guest GC"):
    coding_cli_native("gc", vm, coding_cli_username)
    ssh_root = "/var/lib/fleet-coding-clis"
    client.succeed(
        f"install -d -m 700 {ssh_root} && "
        "install -d -m 700 -o tester -g users /home/tester/.ssh "
        "/home/tester/.config /home/tester/.config/overalls"
    )
    client.succeed(f"install -m 444 {root}/ca.crt {ssh_root}/ca.crt")
    client.succeed("sudo -u tester ssh-keygen -q -t ed25519 -N '' -f /home/tester/.ssh/id_ed25519")
    public = client.succeed("cat /home/tester/.ssh/id_ed25519.pub").strip()
    operator(m1, dict(action="audi-ssh-key", owner_id=owner_id, public_key=public))
    endpoint = operator(
        m1,
        dict(action="audi-policy", owner_id=owner_id, vm_id=vm["vm_id"], visibility="private"),
    )
    label = endpoint["label"]
    assert isinstance(label, str)
    hostname = label + ".apps.example.test"
    host_for(vm).succeed(
        "fleet-audi-guest ssh "
        + shlex.quote(vm["placement_id"])
        + " "
        + shlex.quote(root + "/coding-clis-guest-host.pub"),
        timeout=180,
    )
    ssh_ca = m1.succeed("ssh-keygen -y -f " + root + "/ssh-host-ca").strip()
    client.succeed(
        "printf %s "
        + shlex.quote(
            json.dumps({"origin": "https://control.example.test", "zone": "apps.example.test"})
        )
        + " >/home/tester/.config/overalls/config.json"
    )
    client.succeed(
        f"curl -fsS --cacert {root}/ca.crt "
        "https://control.example.test/bin/ssh-trust.json >/home/tester/.ssh/overalls-trust.json"
    )
    operator(
        m1,
        dict(
            action="audi-ssh-profile",
            owner_id=owner_id,
            vm_id=vm["vm_id"],
            output=root + "/coding-clis-ssh.conf",
        ),
    )
    transfer(m1, root + "/coding-clis-ssh.conf", client, ssh_root + "/ssh.conf")
    client.succeed(
        "printf '%s\\n' "
        + shlex.quote("@cert-authority *.apps.example.test " + ssh_ca)
        + f" >{ssh_root}/guest-known-hosts"
    )
    client.succeed(
        "chown tester:users /home/tester/.config/overalls/config.json "
        f"/home/tester/.ssh/overalls-trust.json {ssh_root}/ssh.conf {ssh_root}/guest-known-hosts && "
        f"chmod 755 {ssh_root}"
    )
    ssh_arguments = [
        "ssh",
        "-F",
        ssh_root + "/ssh.conf",
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
        "UserKnownHostsFile=" + ssh_root + "/guest-known-hosts",
        "-i",
        "/home/tester/.ssh/id_ed25519",
        coding_cli_username + "@" + hostname,
    ]
    ssh_environment = (
        "sudo -u tester env HOME=/home/tester "
        f"CURL_CA_BUNDLE={ssh_root}/ca.crt SSL_CERT_FILE={ssh_root}/ca.crt "
    )
    client.wait_until_succeeds(
        coding_cli_ssh_command(ssh_arguments, ssh_environment, "true"),
        timeout=180,
    )
    before_ssh = coding_cli_stats()
    remote = (
        "umask 077; "
        + 'test "$(id -un)" = '
        + shlex.quote(coding_cli_username)
        + ' && test "$HOME" = '
        + shlex.quote("/home/" + coding_cli_username)
        + ' && test "$CODEX_CA_CERTIFICATE" = /etc/ssl/certs/ca-certificates.crt'
        + ' && test "$NODE_EXTRA_CA_CERTS" = /etc/ssl/certs/ca-certificates.crt'
        + " && codex --version | grep -Fq 0.149.0"
        + " && claude --version | grep -Fq 2.1.238"
        + " && codex --help >/dev/null && claude --help >/dev/null"
        + " && timeout --foreground -k 5 180 codex exec --skip-git-repo-check --model fixture-model"
        + ' --output-last-message "$HOME/codex-ssh-reply"'
        + " 'Reply with fixture codex reply' </dev/null >\"$HOME/codex-ssh.log\" 2>&1"
        + " && grep -Fq 'fixture codex reply' \"$HOME/codex-ssh-reply\""
        + " && timeout --foreground -k 5 180 claude -p --model fixture-model --output-format text"
        + " 'Reply with fixture claude reply' </dev/null >\"$HOME/claude-ssh.log\" 2>&1"
        + " && grep -Fq 'fixture claude reply' \"$HOME/claude-ssh.log\""
    )
    client.succeed(coding_cli_ssh_command(ssh_arguments, ssh_environment, remote), timeout=450)
    after_ssh = coding_cli_stats()
    assert after_ssh["responses"] > before_ssh["responses"]
    assert after_ssh["messages"] > before_ssh["messages"]

with subtest("Customer native clients refuse inference without contacting providers"):
    lifecycle(vm["vm_id"], "delete")
    eventually(lambda: vm_state(vm["vm_id"]) == "deleted", timeout=180)
    customer = provision_when_available(
        m1, "customer", disk_bytes=coding_cli_disk_bytes, memory_bytes=coding_cli_memory_bytes
    )
    await_running(customer["vm_id"])
    coding_cli_native("prepare", customer, coding_cli_username)
    before_customer = coding_cli_stats()
    coding_cli_native("customer", customer, coding_cli_username)
    assert coding_cli_stats() == before_customer
    lifecycle(customer["vm_id"], "delete")
    eventually(lambda: vm_state(customer["vm_id"]) == "deleted", timeout=180)
