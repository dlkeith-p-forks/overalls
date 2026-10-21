import json
import shlex

start_all()
control.wait_for_unit("postgresql-setup.service")
control.succeed("systemctl start overalls-test-migrate.service")
control.wait_until_succeeds(
    "curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready",
    timeout=120,
)
client.wait_for_unit("multi-user.target")
client.succeed("sudo -u tester install -d -m 700 /home/tester/.ssh")
client.succeed("sudo -u tester ssh-keygen -q -t ed25519 -N '' -f /home/tester/.ssh/id_ed25519")
public = client.succeed("cat /home/tester/.ssh/id_ed25519.pub").strip()
control.succeed("printf '%s\\n' " + shlex.quote(public) + " >/run/overalls-test/client.pub")
control.succeed("systemctl start installer-seed.service")
ca = control.succeed("cat /run/overalls-test/ca.crt")
client.succeed("printf '%s' " + shlex.quote(ca) + " >/home/tester/ca.crt")
origin = "https://control.example.test:4443"
curl = "sudo -u tester curl --fail --silent --show-error --cacert /home/tester/ca.crt "
control.succeed(
    "mkdir -p /run/systemd/system/marshall-control.service.d; "
    "printf '[Service]\\nUnsetEnvironment=MARSHALL_SSH_HOST_TRUST\\n' "
    ">/run/systemd/system/marshall-control.service.d/no-policy.conf; "
    "systemctl daemon-reload; systemctl restart marshall-control.service"
)
control.wait_for_open_port(4443)
with subtest("missing deployment CA policy refuses installer delivery"):
    status = client.succeed(
        "sudo -u tester curl --silent --cacert /home/tester/ca.crt -o /dev/null -w '%{http_code}' "
        + origin
        + "/bin/install.sh"
    )
    assert status == "503"

control.succeed(
    "rm /run/systemd/system/marshall-control.service.d/no-policy.conf; "
    "systemctl daemon-reload; systemctl restart marshall-control.service"
)
control.wait_until_succeeds(
    "curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready",
    timeout=120,
)
control.wait_for_open_port(5443)
with subtest("initial certificate issuance recovers after the former start limit"):
    control.succeed("systemctl stop marshall-control.service")
    control.succeed("systemctl start --no-block porsche.service")
    control.wait_until_succeeds(
        "test $(systemctl show porsche.service -p NRestarts --value) -ge 7",
        timeout=90,
    )
    control.fail("ss -ltnH 'sport = :22' | grep -q LISTEN")
    control.fail("test -e /var/lib/porsche/keys/ssh_host_ed25519_key-cert.pub")
    control.succeed("systemctl start marshall-control.service")
    control.wait_until_succeeds("systemctl is-active --quiet porsche.service", timeout=90)
    control.wait_for_open_port(22)
ssh_ca: str = " ".join(
    control.succeed("ssh-keygen -y -f /run/overalls-test/ssh-host-ca").split()[:2]
)
client.succeed(curl + origin + "/bin/install.sh -o /home/tester/install.sh")
client.succeed("chown tester:users /home/tester/install.sh")


def install_command(environment: str = "") -> str:
    # script(1) supplies a real controlling terminal for the installer's last step.
    # No guest exists: its final connection fails after successful account setup.
    return (
        "sudo -u tester env HOME=/home/tester CURL_CA_BUNDLE=/home/tester/ca.crt "
        "SSL_CERT_FILE=/home/tester/ca.crt "
        + environment
        + "script --quiet --return --command "
        + shlex.quote(
            "bash /home/tester/install.sh " + origin + " apps.example.test absent.apps.example.test"
        )
        + " /home/tester/install.log </dev/null >/dev/null 2>&1"
    )


def refusal_command(environment: str = "") -> str:
    # Refusals never reach the installer's terminal-bound exec; capture their
    # complete stdout/stderr directly instead of the sub-second pty typescript.
    return (
        "sudo -u tester env HOME=/home/tester CURL_CA_BUNDLE=/home/tester/ca.crt "
        "SSL_CERT_FILE=/home/tester/ca.crt "
        + environment
        + "bash /home/tester/install.sh "
        + origin
        + " apps.example.test absent.apps.example.test"
        + " </dev/null >/home/tester/refusal.log 2>&1"
    )


def tree_snapshot(tree: str) -> str:
    # Whole-tree state: type, mode, symlink target and file byte digests under
    # one managed tree. Refusals MUST leave every entry byte-identical; the
    # installer rewrites managed files atomically with identical bytes, so
    # modes and digests (not mtimes) are the compared content.
    return client.succeed(
        "sudo -u tester sh -c "
        + shlex.quote(
            "target=/home/tester/" + tree + "; "
            '[ -e "$target" ] || exit 0; '
            "find \"$target\" -mindepth 0 -printf '%y %m %p -> %l\\n' | sort; "
            'find "$target" -mindepth 1 -type f -exec sha256sum {} +'
        )
    ).strip()


def tree_snapshots() -> dict[str, str]:
    return {tree: tree_snapshot(tree) for tree in [".ssh", ".local/bin", ".config/overalls"]}


install = install_command()
known = "/home/tester/.ssh/known_hosts"


def json_object(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("expected object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ValueError("expected string key")
        result[key] = item
    return result


def json_string(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("expected string")
    return value


def configured_count() -> int:
    return int(
        client.succeed(
            'grep -h -F \'"event":"lyra.configured"\' '
            "/home/tester/.local/state/overalls/logs/*.jsonl | wc -l"
        ).strip()
    )


with subtest("first installation trusts the CA and configures the packaged client"):
    client.fail(install)
    first_output: str = client.succeed("cat /home/tester/install.log")
    assert "SSH configuration installed" in first_output, first_output
    trusted: str = client.succeed("cat " + known)
    assert (
        "@cert-authority control.example.test,*.apps.example.test,*.ssh.control.example.test "
        + ssh_ca
        in trusted
    )
    assert client.succeed("stat -c '%a' " + known).strip() == "600"
    installed_digest = client.succeed("sha256sum /home/tester/.local/bin/overalls").split()[0]
    assert installed_digest == client.succeed(curl + origin + "/bin/sha256/linux-amd64").strip()
    config = client.succeed("cat /home/tester/.ssh/config")
    assert "  IdentityFile ~/.ssh/id_ed25519" in config.splitlines()
    assert "# BEGIN OVERALLS SSH" in config
    settings = client.succeed("cat /home/tester/.config/overalls/config.json")
    assert origin in settings and "apps.example.test" in settings
    assert configured_count() == 1
    identity = client.succeed("cat /home/tester/.ssh/overalls-identity.pub").split()
    assert identity[:2] == public.split()[:2]
    # Separate real strict proof confirms the installed trust authenticates the
    # current gateway and the generated config identifies the registered user.
    client.succeed(
        "sudo -u tester ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes "
        "control.example.test whoami --json >/home/tester/account.json"
    )
    account = json_object(json.loads(client.succeed("cat /home/tester/account.json")))
    identity_fields = json_object(account["result"])
    guest_username = json_string(identity_fields["guest_username"])
    assert guest_username.startswith("u") and guest_username[1:].isdigit()
    assert 200000 <= int(guest_username[1:]) <= 999999
    assert "  User " + guest_username in config.splitlines()

with subtest("repeated installation preserves CA trust and one managed SSH block"):
    client.fail(install)
    assert client.succeed("cat " + known) == trusted
    assert client.succeed("cat /home/tester/.ssh/config") == config
    assert config.count("# BEGIN OVERALLS SSH") == 1
    assert configured_count() == 2

with subtest("conflicting and revoked trust refuse before replacing installed state"):
    client.succeed("printf 'prior executable\\n' >/home/tester/.local/bin/overalls")
    retained_digest: str = client.succeed("sha256sum /home/tester/.local/bin/overalls").split()[0]
    assert retained_digest != installed_digest
    for before in [
        trusted.replace(ssh_ca, " ".join(public.split()[:2])),
        trusted + "@revoked control.example.test " + ssh_ca + "\n",
    ]:
        client.succeed("printf '%s' " + shlex.quote(before) + " >" + known)
        client.fail(install)
        assert client.succeed("cat " + known) == before
        assert client.succeed("cat /home/tester/.ssh/config") == config
        assert (
            client.succeed("sha256sum /home/tester/.local/bin/overalls").split()[0]
            == retained_digest
        )
        assert configured_count() == 2
        output = client.succeed("cat /home/tester/install.log")
        assert "SSH configuration failed" in output
        client.succeed("test -z \"$(find /home/tester/.local/bin -name '.overalls.*' -print)\"")


def served_release(path: str) -> None:
    # Point the controller at a fixture release store path; an empty path
    # restores the packaged release. Only /nix/store paths are honored.
    if path:
        control.succeed(
            "mkdir -p /run/systemd/system/marshall-control.service.d; "
            "printf '[Service]\\nEnvironment=OVERALLS_LYRA_RELEASE=%s\\n' "
            + shlex.quote(path)
            + " >/run/systemd/system/marshall-control.service.d/release.conf; "
            "systemctl daemon-reload; systemctl restart marshall-control.service"
        )
    else:
        control.succeed(
            "rm -f /run/systemd/system/marshall-control.service.d/release.conf; "
            "systemctl daemon-reload; systemctl restart marshall-control.service"
        )
    control.wait_until_succeeds(
        "curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready",
        timeout=120,
    )


def fetched_manifest() -> dict[str, object]:
    manifest = json_object(json.loads(client.succeed(curl + origin + "/bin/manifest.json")))
    artifacts = json_object(manifest["artifacts"])
    assert sorted(artifacts) == [
        "darwin-amd64",
        "darwin-arm64",
        "linux-amd64",
        "linux-arm64",
        "windows-amd64",
    ]
    return manifest


def fetched_digest(target: str) -> str:
    return client.succeed(
        curl + origin + "/bin/" + target + " -o /tmp/overalls-download && "
        "sha256sum /tmp/overalls-download | cut -d' ' -f1; "
        "rm -f /tmp/overalls-download"
    ).strip()


def manifest_digest(manifest: dict[str, object], target: str) -> str:
    return json_string(json_object(json_object(manifest["artifacts"])[target])["sha256"])


with subtest("fresh account install agrees on digests, trust origin and account key"):
    client.succeed(
        "sudo -u tester rm -rf /home/tester/.ssh /home/tester/.local/bin "
        "/home/tester/.config/overalls /home/tester/.local/state/overalls"
    )
    client.succeed("sudo -u tester install -d -m 700 /home/tester/.ssh")
    client.succeed("sudo -u tester ssh-keygen -q -t ed25519 -N '' -f /home/tester/.ssh/id_ed25519")
    fresh_public = client.succeed("cat /home/tester/.ssh/id_ed25519.pub").strip()
    assert fresh_public.split()[:2] != public.split()[:2]
    control.succeed(
        "printf '%s\\n' " + shlex.quote(fresh_public) + " >/run/overalls-test/client.pub"
    )
    # Withdraw the seed key, then register the fresh one: exactly one active key.
    control.succeed("systemctl start installer-revoke.service")
    control.succeed("systemctl start installer-register.service")
    client.fail(install)
    output = client.succeed("cat /home/tester/install.log")
    assert "SSH configuration installed" in output
    assert configured_count() == 1
    installed_digest = client.succeed("sha256sum /home/tester/.local/bin/overalls").split()[0]
    # Four-way digest agreement: recomputed installed bytes, the checksum
    # endpoint, the manifest entry and a fresh download all agree.
    endpoint_digest = client.succeed(curl + origin + "/bin/sha256/linux-amd64").strip()
    manifest = fetched_manifest()
    release_digest = fetched_digest("linux-amd64")
    assert installed_digest == endpoint_digest == manifest_digest(manifest, "linux-amd64")
    assert installed_digest == release_digest
    # Five-target checksum and manifest agreement against the actual artifacts.
    for target in ["linux-amd64", "linux-arm64", "darwin-amd64", "darwin-arm64", "windows-amd64"]:
        endpoint = client.succeed(curl + origin + "/bin/sha256/" + target).strip()
        assert endpoint == manifest_digest(manifest, target)
        assert endpoint == fetched_digest(target)
    # known_hosts is recomputed from the test CA key, never from CLI output.
    expected_trust = (
        "# BEGIN OVERALLS SSH TRUST control.example.test\n"
        "@cert-authority control.example.test,*.apps.example.test,*.ssh.control.example.test "
        + ssh_ca
        + "\n# END OVERALLS SSH TRUST control.example.test\n"
    )
    assert client.succeed("cat " + known) == expected_trust
    trust_policy = json_object(
        json.loads(client.succeed("cat /home/tester/.ssh/overalls-trust.json"))
    )
    assert json_string(trust_policy["management_host"]) == "control.example.test"
    assert json_string(trust_policy["zone"]) == "apps.example.test"
    ca_field = json_string(trust_policy["ca"])
    assert " ".join(ca_field.split()[:2]) == ssh_ca
    # Three-way account association: SQL row fingerprint, live account proof
    # and the installed public identity all name the same fresh key.
    client.succeed(
        "sudo -u tester ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes "
        "control.example.test whoami --json >/home/tester/account.json"
    )
    account = json_object(json.loads(client.succeed("cat /home/tester/account.json")))
    proved_key = json_string(json_object(account["result"])["public_key"])
    local_identity = client.succeed("cat /home/tester/.ssh/overalls-identity.pub")
    assert proved_key.split()[:2] == local_identity.split()[:2] == fresh_public.split()[:2]
    fingerprint = client.succeed(
        "sudo -u tester ssh-keygen -lf /home/tester/.ssh/overalls-identity.pub"
    ).split()[1]
    sql_fingerprint = control.succeed(
        "sudo -u postgres psql --no-psqlrc -d marshall -Atc "
        + shlex.quote("SELECT fingerprint FROM ssh_keys WHERE archived_at IS NULL")
    ).strip()
    assert fingerprint == sql_fingerprint
    assert fingerprint.startswith("SHA256:")

with subtest("revoked account key refuses before any client replacement"):
    control.succeed("systemctl start installer-revoke.service")
    assert (
        control.succeed(
            "sudo -u postgres psql --no-psqlrc -d marshall -Atc "
            + shlex.quote("SELECT count(*) FROM ssh_keys WHERE archived_at IS NULL")
        ).strip()
        == "0"
    )
    before = tree_snapshots()
    # The closed account-proof refusal at the Porsche boundary: transport auth
    # completes publickey, but the revoked key no longer maps to an account, so
    # the exec refuses with an approval-required receipt instead of a JSON proof.
    proof_status, _ = client.execute(
        "sudo -u tester ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes "
        "control.example.test whoami --json </dev/null "
        ">/home/tester/revoked-proof.out 2>/home/tester/revoked-proof.err"
    )
    assert proof_status == 3, f"unexpected revoked proof status: {proof_status}"
    proof_out = client.succeed("cat /home/tester/revoked-proof.out")
    assert '"status":"approval_required"' in proof_out
    assert '"status":"succeeded"' not in proof_out
    client.fail(refusal_command())
    output = client.succeed("cat /home/tester/refusal.log")
    assert "SSH configuration failed" in output
    # The CLI maps the closed account proof to its generic failure; the inner
    # SSH detail stays on the proof's own stdout, not the installer's stderr.
    assert "SSH configuration installed" not in output
    # The account-proof refusal retains the executable and every tree
    # byte-identically, including the already-established trust.
    assert tree_snapshots() == before
    assert configured_count() == 1
    client.succeed("test -z \"$(find /home/tester/.local/bin -name '.overalls.*' -print)\"")

with subtest("revoked key at first contact installs trust but no account binding"):
    # @cc [owner:ghuntley,label:verification;security] installer-trust-before-proof-asymmetry
    # Trust installation precedes account proof (lyra/src/ssh_config.rs:218
    # before :220), so a first-contact account refusal MUST leave CA trust
    # installed while the executable, the managed SSH block, the proved identity
    # and the CLI configuration MUST stay absent or byte-identical.
    client.succeed(
        "sudo -u tester rm -f /home/tester/.ssh/known_hosts "
        "/home/tester/.ssh/overalls-trust.json /home/tester/.ssh/config "
        "/home/tester/.ssh/overalls-identity.pub && "
        "sudo -u tester rm -rf /home/tester/.config/overalls"
    )
    ssh_before = tree_snapshot(".ssh")
    bin_before = tree_snapshot(".local/bin")
    assert "overalls" in bin_before
    client.fail(refusal_command())
    output = client.succeed("cat /home/tester/refusal.log")
    assert "SSH configuration failed" in output
    assert "SSH configuration installed" not in output
    trusted_after = client.succeed("cat " + known)
    assert trusted_after == (
        "# BEGIN OVERALLS SSH TRUST control.example.test\n"
        "@cert-authority control.example.test,*.apps.example.test,*.ssh.control.example.test "
        + ssh_ca
        + "\n# END OVERALLS SSH TRUST control.example.test\n"
    )
    assert client.succeed("stat -c '%a' " + known).strip() == "600"
    assert tree_snapshot(".local/bin") == bin_before
    assert tree_snapshot(".config/overalls") == ""
    client.fail("test -e /home/tester/.ssh/config")
    client.fail("test -e /home/tester/.ssh/overalls-identity.pub")
    ssh_after = tree_snapshot(".ssh")
    residual = "\n".join(
        line
        for line in ssh_after.splitlines()
        if "known_hosts" not in line and "overalls-trust.json" not in line
    )
    assert residual == ssh_before
    client.succeed("test -z \"$(find /home/tester/.local/bin -name '.overalls.*' -print)\"")

with subtest("re-registration restores the completing install"):
    control.succeed("systemctl start installer-register.service")
    assert (
        control.succeed(
            "sudo -u postgres psql --no-psqlrc -d marshall -Atc "
            + shlex.quote("SELECT count(*) FROM ssh_keys WHERE archived_at IS NULL")
        ).strip()
        == "1"
    )
    client.fail(install)
    output = client.succeed("cat /home/tester/install.log")
    assert "SSH configuration installed" in output
    assert configured_count() == 2
    assert (
        client.succeed("sha256sum /home/tester/.local/bin/overalls").split()[0] == installed_digest
    )
    assert client.succeed("cat " + known) == (
        "# BEGIN OVERALLS SSH TRUST control.example.test\n"
        "@cert-authority control.example.test,*.apps.example.test,*.ssh.control.example.test "
        + ssh_ca
        + "\n# END OVERALLS SSH TRUST control.example.test\n"
    )
    config = client.succeed("cat /home/tester/.ssh/config")
    assert config.count("# BEGIN OVERALLS SSH") == 1
    assert "  User " + guest_username in config.splitlines()

with subtest("upgraded artifact replaces the binary only after config success"):
    served_release("@UPGRADED_RELEASE@")
    before = tree_snapshots()
    client.fail(install)
    output = client.succeed("cat /home/tester/install.log")
    assert "SSH configuration installed" in output
    upgraded_manifest = fetched_manifest()
    upgraded_digest = client.succeed(curl + origin + "/bin/sha256/linux-amd64").strip()
    assert upgraded_digest != installed_digest
    assert fetched_digest("linux-amd64") == upgraded_digest
    assert (
        client.succeed("sha256sum /home/tester/.local/bin/overalls").split()[0] == upgraded_digest
    )
    assert manifest_digest(upgraded_manifest, "linux-amd64") == upgraded_digest
    for target in ["linux-arm64", "darwin-amd64", "darwin-arm64", "windows-amd64"]:
        unchanged = manifest_digest(upgraded_manifest, target)
        assert unchanged == manifest_digest(manifest, target)
        assert client.succeed(curl + origin + "/bin/sha256/" + target).strip() == unchanged
    after = tree_snapshots()
    assert after[".ssh"] == before[".ssh"]
    assert after[".config/overalls"] == before[".config/overalls"]
    assert configured_count() == 3

with subtest("mismatched served digest refuses before replacing the executable"):
    # @cc [owner:ghuntley,label:verification;security] installer-mismatch-stderr-pin
    # The mismatched-digest refusal is distinguished ONLY by the stderr text
    # 'Binary checksum mismatch'; the install script shares exit status 1 with
    # every other refusal and emits no structured error. Pinned at
    # marshall/priv/overalls-install.sh:68-76.
    served_release("@MISMATCHED_RELEASE@")
    stale_endpoint = client.succeed(curl + origin + "/bin/sha256/linux-amd64").strip()
    actual_bytes = fetched_digest("linux-amd64")
    assert stale_endpoint == installed_digest
    assert actual_bytes != stale_endpoint
    before = tree_snapshots()
    client.fail(refusal_command())
    output = client.succeed("cat /home/tester/refusal.log")
    assert "Binary checksum mismatch" in output
    assert "SSH configuration installed" not in output
    assert tree_snapshots() == before
    assert (
        client.succeed("sha256sum /home/tester/.local/bin/overalls").split()[0] == upgraded_digest
    )
    assert configured_count() == 3
    client.succeed("test -z \"$(find /home/tester/.local/bin -name '.overalls.*' -print)\"")

with subtest("unsupported platform refuses before any download or replacement"):
    served_release("@UPGRADED_RELEASE@")
    before = tree_snapshots()
    client.succeed(
        "install -d -m 700 -o tester -g users /home/tester/shim && "
        "printf '%s\\n' '#!/bin/sh' "
        + shlex.quote('case "${1:-}" in -s) echo FreeBSD;; -m) echo amd64;; *) echo FreeBSD;; esac')
        + " >/home/tester/shim/uname && "
        "chown tester:users /home/tester/shim/uname && "
        "chmod 700 /home/tester/shim/uname"
    )
    client.fail(refusal_command("PATH=/home/tester/shim:$PATH "))
    output = client.succeed("cat /home/tester/refusal.log")
    assert "Unsupported platform" in output
    assert tree_snapshots() == before
    client.succeed("test -z \"$(find /home/tester/.local/bin -name '.overalls.*' -print)\"")

with subtest("darwin selection fetches the macOS artifact and fails at local exec"):
    # @cc [owner:ghuntley,label:verification] installer-darwin-delivery-proof
    # The Darwin shim MUST fetch exactly the darwin-arm64 artifact and its
    # checksum through verified HTTPS; the Mach-O binary's local exec refusal
    # MUST retain prior state. Native macOS runtime acceptance remains external.
    before = tree_snapshots()
    client.succeed(
        "printf '%s\\n' '#!/bin/sh' "
        + shlex.quote(
            'printf \'%s\\n\' "$*" >> /home/tester/shim-calls.log; exec /run/current-system/sw/bin/curl "$@"'
        )
        + " >/home/tester/shim/curl && "
        "printf '%s\\n' '#!/bin/sh' "
        + shlex.quote('case "${1:-}" in -s) echo Darwin;; -m) echo arm64;; *) echo Darwin;; esac')
        + " >/home/tester/shim/uname && "
        "chown tester:users /home/tester/shim/curl /home/tester/shim/uname && "
        "chmod 700 /home/tester/shim/curl /home/tester/shim/uname"
    )
    client.fail(refusal_command("PATH=/home/tester/shim:$PATH "))
    output = client.succeed("cat /home/tester/refusal.log")
    assert "cannot execute binary file" in output
    calls = client.succeed("cat /home/tester/shim-calls.log")
    assert origin + "/bin/darwin-arm64" in calls
    assert origin + "/bin/sha256/darwin-arm64" in calls
    darwin_digest = client.succeed(curl + origin + "/bin/sha256/darwin-arm64").strip()
    assert darwin_digest == manifest_digest(fetched_manifest(), "darwin-arm64")
    assert darwin_digest == fetched_digest("darwin-arm64")
    assert tree_snapshots() == before
    client.succeed("test -z \"$(find /home/tester/.local/bin -name '.overalls.*' -print)\"")

with subtest("checksum tool absence refuses and the shasum fallback completes"):
    # @cc [owner:ghuntley,label:verification] installer-shasum-fallback
    # With sha256sum and shasum both absent the installer MUST refuse before
    # replacement; with the macOS shasum present the fallback MUST verify the
    # same digest and complete configuration.
    before = tree_snapshots()
    client.succeed(
        "sudo -u tester install -d -m 700 /home/tester/shim-nosha && "
        "sudo -u tester sh -c "
        + shlex.quote(
            "for tool in /run/current-system/sw/bin/*; do "
            "name=${tool##*/}; "
            '[ "$name" = sha256sum ] || [ "$name" = shasum ] '
            '|| ln -sf "$tool" /home/tester/shim-nosha/"$name"; '
            "done; "
            # The coreutils multicall dispatches on argv[0], so the hidden real
            # digest tool must keep its basename without entering `command -v`.
            "install -d /home/tester/shim-nosha/.real && "
            "ln -sf /run/current-system/sw/bin/sha256sum /home/tester/shim-nosha/.real/sha256sum"
        )
    )
    client.fail(refusal_command("PATH=/home/tester/shim-nosha "))
    output = client.succeed("cat /home/tester/refusal.log")
    assert "shasum: command not found" in output
    assert tree_snapshots() == before
    client.succeed("test -z \"$(find /home/tester/.local/bin -name '.overalls.*' -print)\"")
    client.succeed(
        "printf '%s\\n' '#!/bin/sh' "
        + shlex.quote(
            '[ "$1" = "-a" ] || exit 1; shift 2; exec /home/tester/shim-nosha/.real/sha256sum "$@"'
        )
        + " >/home/tester/shim-nosha/shasum && "
        "chown tester:users /home/tester/shim-nosha/shasum && "
        "chmod 700 /home/tester/shim-nosha/shasum"
    )
    before = tree_snapshots()
    # Configuration completion is the scoped assertion; the final terminal-bound
    # guest exec is covered by the fleet journey, so the plain capture suffices.
    client.fail(refusal_command("PATH=/home/tester/shim-nosha "))
    output = client.succeed("cat /home/tester/refusal.log")
    assert "SSH configuration installed" in output, output
    after = tree_snapshots()
    assert after == before
    assert (
        client.succeed("sha256sum /home/tester/.local/bin/overalls").split()[0] == upgraded_digest
    )
    assert configured_count() == 4

served_release("")
