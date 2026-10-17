"""Repository launch journey; composed after default-oss/setup.py with its helpers."""

from typing import Literal

type ApiProvider = Literal["none", "codeberg", "bitbucket"]

git_fixture = "/var/lib/git-fixture/overalls/fixture.git"
fixture_urls = {
    "default": "https://github.com/overalls/fixture",
    "branch": "https://github.com/overalls/fixture/tree/feature/x",
    "pull": "https://github.com/overalls/fixture/pull/7",
}


def fixture_commit(workdir: str, message: str) -> str:
    egress.succeed(
        f"git -C {workdir} -c user.name=fixture -c user.email=fixture@example.test "
        f"commit --allow-empty -q -m {shlex.quote(message)}"
    )
    sha = egress.succeed(f"git -C {workdir} rev-parse HEAD").strip()
    assert len(sha) == 40 and int(sha, 16) >= 0
    return sha


def launch_placement(vm_id: str) -> tuple[ProfileMachine, str]:
    running(vm_id)
    return current_placement(vm_id)


def guest_checkout(vm_id: str, mode: str, sha: str, api_provider: ApiProvider = "none") -> None:
    assert api_provider in ("none", "codeberg", "bitbucket")
    host, placement_id = launch_placement(vm_id)
    host.succeed(
        f"fleet-repository-launch-guest {mode} {placement_id} fixture {sha} {api_provider}",
        timeout=480,
    )


def launch_porsche(command: str) -> dict[str, object]:
    """Run a Porsche command through setup's transport, reporting only the closed
    status and error fields of a failed receipt (never raw SSH output)."""
    output_path = browser_root + "/launch-receipt.json"
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
        browser_root + "/owner",
        "fixture@m1",
        command + " --json",
    ]
    status, _ = client.execute(
        "sudo -u tester " + shlex.join(arguments) + " >" + output_path + " 2>/dev/null",
        timeout=680,
    )
    program = (
        "import json; v=json.load(open("
        + repr(output_path)
        + ")); print(json.dumps({k:v[k] for k in ('status','error','request_id','operation_id','result') if k in v}))"
    )
    parsed: object = json.loads(client.succeed("python3 -c " + shlex.quote(program)))
    receipt = object_fields(parsed)
    assert status == 0 and receipt.get("status") == "succeeded", {
        "exit": status,
        "status": receipt.get("status"),
        "error": receipt.get("error"),
    }
    return receipt


def source_row(vm_id: str) -> str:
    assert str(uuid.UUID(vm_id)) == vm_id
    return sql(
        "SELECT provider || ':' || array_to_string(namespace, '/') || '/' || repository "
        "|| ':' || (revision->>'kind') || ':' || coalesce(revision->>'value', '') "
        f"FROM compute_workspace_sources WHERE vm_id='{vm_id}'"
    )


with subtest("local TLS providers serve refs, tags, immutable commits and change heads"):
    # @cc [owner:ghuntley,label:verification;security] repository-launch-fixture-refs
    # The fixture MUST expose a default branch, a named branch, an older commit
    # only reachable through history, a tag and change refs outside refs/heads, so each
    # launch form proves the guest selected the requested ref itself.
    egress.wait_for_unit("nginx.service")
    work = "/var/lib/git-fixture-work"
    egress.succeed(f"rm -rf {work} && git init -q -b main {work}")
    commit_sha = fixture_commit(work, "older commit")
    default_sha = fixture_commit(work, "main head")
    egress.succeed(f"git -C {work} checkout -q -b feature/x {commit_sha}")
    branch_sha = fixture_commit(work, "feature branch")
    egress.succeed(f"git -C {work} checkout -q --detach {commit_sha}")
    pull_sha = fixture_commit(work, "pull request head")
    egress.succeed(f"git -C {work} checkout -q main")
    egress.succeed(f"git -C {work} tag fixture-tag {commit_sha}")
    egress.succeed(
        f"install -d -m 755 /var/lib/git-fixture/overalls && rm -rf {git_fixture} && "
        f"git clone -q --bare {work} {git_fixture} && "
        f"git -C {git_fixture} update-ref refs/pull/7/head {pull_sha} && "
        f"git -C {git_fixture} update-ref refs/merge-requests/7/head {pull_sha} && "
        f"git -C {git_fixture} symbolic-ref HEAD refs/heads/main && "
        # Like GitHub, serve any reachable object by SHA for shallow commit fetches.
        f"git -C {git_fixture} config uploadpack.allowReachableSHA1InWant true && "
        # git http-backend runs as nginx and refuses repositories it does not own.
        f"chown -R nginx:nginx /var/lib/git-fixture && chmod -R a+rX /var/lib/git-fixture"
    )
    egress.wait_for_unit("fleet-git-backend.service")
    refs = egress.succeed(
        f"GIT_SSL_CAINFO={github_fixture_root} git -c http.curloptResolve=github.com:443:11.0.0.1 "
        "ls-remote https://github.com/overalls/fixture.git"
    )
    assert f"{pull_sha}\trefs/pull/7/head" in refs
    assert f"{branch_sha}\trefs/heads/feature/x" in refs
    assert f"{commit_sha}\trefs/tags/fixture-tag" in refs
    fixture_urls["commit"] = "https://github.com/overalls/fixture/commit/" + commit_sha
    expected = {
        "default": default_sha,
        "branch": branch_sha,
        "commit": commit_sha,
        "pull": pull_sha,
    }
    assert len(set(expected.values())) == 4
    provider_hosts = {
        "github": "github.com",
        "gitlab": "gitlab.com",
        "codeberg": "codeberg.org",
        "bitbucket": "bitbucket.org",
    }
    for provider, host in provider_hosts.items():
        base = f"https://{host}/overalls/fixture"
        if provider == "gitlab":
            suffixes = {
                "ref": "/-/tree/feature/x",
                "tag": "/-/tags/fixture-tag",
                "commit": "/-/commit/" + commit_sha,
                "change": "/-/merge_requests/7",
            }
        elif provider == "codeberg":
            suffixes = {
                "ref": "/src/branch/feature/x",
                "tag": "/src/tag/fixture-tag",
                "commit": "/src/commit/" + commit_sha,
                "change": "/pulls/7",
            }
        elif provider == "bitbucket":
            suffixes = {
                "ref": "/src/feature/x",
                "tag": "/src/fixture-tag",
                "commit": "/commits/" + commit_sha,
                "change": "/pull-requests/7",
            }
        else:
            suffixes = {
                "ref": "/tree/feature/x",
                "tag": "/releases/tag/fixture-tag",
                "commit": "/commit/" + commit_sha,
                "change": "/pull/7",
            }
        fixture_urls[provider + "_default"] = base
        for kind, suffix in suffixes.items():
            fixture_urls[provider + "_" + kind] = base + suffix
    # API-based change heads deliberately point at a fork rather than the target
    # repository; this exercises validated provider head URL/SHA resolution.
    egress.succeed(
        "install -d -m 755 /var/lib/git-fixture/forks /var/lib/git-api && "
        f"git clone -q --bare {work} /var/lib/git-fixture/forks/fixture.git && "
        f"git -C /var/lib/git-fixture/forks/fixture.git update-ref refs/heads/main {pull_sha} && "
        "git -C /var/lib/git-fixture/forks/fixture.git config uploadpack.allowReachableSHA1InWant true && "
        "chown -R nginx:nginx /var/lib/git-fixture/forks && chmod -R a+rX /var/lib/git-fixture/forks"
    )
    provider_apis = {
        "codeberg": {
            "head": {
                "repo": {"clone_url": "https://codeberg.org/forks/fixture.git"},
                "sha": pull_sha,
            }
        },
        "bitbucket": {
            "source": {
                "repository": {
                    "links": {
                        "clone": [
                            {"name": "https", "href": "https://bitbucket.org/forks/fixture.git"}
                        ]
                    }
                },
                "commit": {"hash": pull_sha},
            }
        },
    }
    for provider, response in provider_apis.items():
        egress.succeed(
            "printf '%s' "
            + shlex.quote(json.dumps(response))
            + f" >/var/lib/git-api/{provider}.json"
        )
    egress.succeed("chmod 755 /var/lib/git-api && chmod 644 /var/lib/git-api/*.json")

with subtest("owner registers a key and Porsche is available"):
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
    client.succeed(f"sudo -u tester ssh-keygen -q -t ed25519 -N '' -f {browser_root}/owner")
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
        "printf '%s' "
        + shlex.quote(json.dumps(fixture_urls))
        + " >"
        + browser_root
        + "/launch-urls.json"
    )
    client.succeed(f"chown -R tester:users {browser_root} && chmod 600 {browser_root}/*.json")

with subtest("signed-in launch links create deduplicated OSS machines with pinned sources"):
    admission = operator(
        dict(action="repository-admission-observations", image_id=users["image_id"])
    )
    print("REPOSITORY_ADMISSION_OBSERVATION " + json.dumps(admission))
    assert admission.get("eligible") is True, admission
    before = sql("SELECT count(*) FROM compute_virtual_machines")
    assert before == "0"
    client.succeed(
        "sudo -u tester env HOME=/home/tester fleet-repository-launch-browser", timeout=900
    )
    launched = string_fields(json.loads(client.succeed("cat " + browser_root + "/launched.json")))
    assert set(launched) == {"default", "branch", "commit", "pull"}
    assert len(set(launched.values())) == 4
    # Reloads, back navigation, a repeated same-tab visit, the refused host and
    # the anonymous visit created nothing beyond the four distinct visits.
    assert sql("SELECT count(*) FROM compute_virtual_machines") == "4"
    assert sql("SELECT count(*) FROM compute_workspace_sources") == "4"
    assert sql("SELECT count(*) FROM compute_operations WHERE kind='provision'") == "4"
    for vm_id in launched.values():
        assert sql(f"SELECT profile FROM compute_virtual_machines WHERE id='{vm_id}'") == "oss"
    assert source_row(launched["default"]) == "github:overalls/fixture:default:"
    assert source_row(launched["branch"]) == "github:overalls/fixture:ref:feature/x"
    assert source_row(launched["commit"]) == "github:overalls/fixture:commit:" + commit_sha
    assert source_row(launched["pull"]) == "github:overalls/fixture:change:7"

with subtest("each guest clones its own requested ref with plain git"):
    for form in ("default", "branch", "commit", "pull"):
        guest_checkout(launched[form], "clone", expected[form])

with subtest("guest restart keeps the checkout and never re-clones"):
    vm_id = launched["default"]
    stop = launch_porsche(f"stop {vm_id} --request-id {uuid.uuid4()} --timeout 600")
    assert stop.get("status") == "succeeded"
    assert observed_state(vm_id) == "stopped"
    launch_porsche(f"start {vm_id} --request-id {uuid.uuid4()} --timeout 600")
    guest_checkout(vm_id, "retained", expected["default"])

with subtest("release launch capacity before the CLI journey"):
    for form in ("commit", "pull", "branch"):
        launch_porsche(f"rm {launched[form]} --request-id {uuid.uuid4()} --timeout 600")
        assert observed_state(launched[form]) == "deleted"

with subtest("a fresh signed-in browser session launches a new machine for the same link"):
    client.succeed(
        "sudo -u tester env HOME=/home/tester fleet-repository-launch-browser fresh", timeout=600
    )
    fresh_vm = client.succeed("cat " + browser_root + "/fresh-vm").strip()
    assert str(uuid.UUID(fresh_vm)) == fresh_vm and fresh_vm not in launched.values()
    assert source_row(fresh_vm) == "github:overalls/fixture:default:"
    guest_checkout(fresh_vm, "clone", expected["default"])
    launch_porsche(f"rm {fresh_vm} --request-id {uuid.uuid4()} --timeout 600")
    assert observed_state(fresh_vm) == "deleted"

with subtest("all four providers clone every supported revision in a real guest"):
    # @cc [owner:ghuntley,label:verification;capacity] repository-provider-native-matrix
    # Each provider/revision MUST reach the expected HEAD through guest-owned Git
    # and validated API resolution. Machines MUST be deleted between matrix cases
    # so the fixture never substitutes enlarged capacity for admission evidence.
    matrix_heads = {
        "default": default_sha,
        "ref": branch_sha,
        "tag": commit_sha,
        "commit": commit_sha,
        "change": pull_sha,
    }
    matrix_values = {
        "default": "",
        "ref": "feature/x",
        "tag": "fixture-tag",
        "commit": commit_sha,
        "change": "7",
    }
    matrix_cases = [
        (provider, kind)
        for provider in provider_hosts
        for kind in matrix_heads
        if provider != "github" or kind == "tag"
    ]
    # Exercise guest API clients first while retaining every one of the sixteen
    # additional cases and the four previously checked GitHub cases.
    matrix_cases.sort(
        key=lambda case: not (case[0] in ("codeberg", "bitbucket") and case[1] == "change")
    )
    assert len(matrix_cases) == 16 and len(set(matrix_cases)) == 16
    for provider, kind in matrix_cases:
        key = provider + "_" + kind
        client.succeed(
            "sudo -u tester env HOME=/home/tester fleet-repository-launch-browser provider " + key,
            timeout=600,
        )
        vm_id = client.succeed("cat " + browser_root + "/provider-vm").strip()
        assert str(uuid.UUID(vm_id)) == vm_id
        source_kind = "ref" if provider == "bitbucket" and kind == "tag" else kind
        assert (
            source_row(vm_id)
            == provider + ":overalls/fixture:" + source_kind + ":" + matrix_values[kind]
        )
        api_provider: ApiProvider = "none"
        if kind == "change" and provider == "codeberg":
            api_provider = "codeberg"
        elif kind == "change" and provider == "bitbucket":
            api_provider = "bitbucket"
        guest_checkout(vm_id, "clone", matrix_heads[kind], api_provider)
        launch_porsche(f"rm {vm_id} --request-id {uuid.uuid4()} --timeout 600")
        assert observed_state(vm_id) == "deleted"

with subtest("unsigned browser downloads remain public and match immutable package metadata"):
    downloaded: dict[str, tuple[str, int]] = {}
    for artifact in ("chrome.zip", "firefox.xpi"):
        prefix = "curl --cacert " + browser_root + "/ca.crt -fsS https://control.example.test"
        client.succeed(
            prefix
            + "/bin/"
            + artifact
            + " -D "
            + browser_root
            + "/download.headers -o "
            + browser_root
            + "/"
            + artifact
        )
        headers = client.succeed("cat " + browser_root + "/download.headers").lower()
        assert "set-cookie:" not in headers
        checksum = client.succeed(prefix + "/bin/browser/sha256/" + artifact).strip()
        actual = client.succeed("sha256sum " + browser_root + "/" + artifact).split()[0]
        assert checksum == actual and len(checksum) == 64
        length = int(client.succeed("wc -c <" + browser_root + "/" + artifact).strip())
        downloaded[artifact] = (checksum, length)
    manifest_json: object = json.loads(client.succeed(prefix + "/bin/browser/manifest.json"))
    manifest = object_fields(manifest_json)
    assert manifest.get("extension_version") == "0.1.0" and manifest.get("unsigned") is True
    archive_metadata = object_fields(manifest["artifacts"])
    for artifact, (digest, length) in downloaded.items():
        assert object_fields(archive_metadata[artifact]) == {"sha256": digest, "size": length}
    denied, _ = client.execute(prefix + "/bin/browser/sha256/options.mjs >/dev/null 2>&1")
    assert denied != 0

with subtest("overalls open creates a sourced machine, waits for the guest clone and runs in it"):
    # @cc [owner:ghuntley,label:verification;security] repository-launch-cli-journey
    # The real packaged overalls CLI MUST create through Porsche with the user's
    # registered key, wait for the guest's own clone and run the user's command
    # inside /workspace/REPO over the generated Audi ProxyCommand. An invalid URL
    # MUST be refused locally without creating a machine.
    client.succeed(
        "install -d -m 700 -o tester -g users /home/tester/.ssh /home/tester/.local/bin "
        "/home/tester/.local/state /home/tester/.config"
    )
    client.succeed(
        f"install -m 600 -o tester -g users {browser_root}/owner /home/tester/.ssh/work_key"
    )
    client.succeed(
        "install -m 755 -o tester -g users /run/current-system/sw/bin/overalls "
        "/home/tester/.local/bin/overalls"
    )
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
    client.succeed(
        "printf '%s' " + shlex.quote(porsche_ssh) + " >/home/tester/.ssh/config && "
        "chown tester:users /home/tester/.ssh/config && chmod 600 /home/tester/.ssh/config"
    )
    shown = object_fields(launch_porsche("show " + launched["default"])["result"])
    installed_host = shown["ssh_host"]
    assert isinstance(installed_host, str) and installed_host.endswith("." + overalls_zone)
    overalls_environment = (
        "sudo -u tester env -u SSH_AUTH_SOCK HOME=/home/tester "
        "XDG_STATE_HOME=/home/tester/.local/state "
        "XDG_CONFIG_HOME=/home/tester/.config "
        "SSL_CERT_FILE=" + browser_root + "/ca.crt CURL_CA_BUNDLE=" + browser_root + "/ca.crt "
    )
    installer = (
        "curl -fsSL https://control.example.test/bin/install.sh | bash -s -- "
        "https://control.example.test " + overalls_zone + " " + shlex.quote(installed_host)
    )
    install_status, install_output = client.execute(
        "printf '%s\\n' "
        + shlex.quote("printf '%s%s\\n' OVERALLS_INSTALLER _SUCCESS; exit")
        + " | "
        + overalls_environment
        + "script -q -e -c "
        + shlex.quote(installer)
        + " /dev/null",
        timeout=300,
    )
    assert install_status == 0 and "OVERALLS_INSTALLER_SUCCESS" in install_output, (
        "Overalls installer did not complete"
    )
    vms_before = sql("SELECT count(*) FROM compute_virtual_machines")
    refused, _ = client.execute(
        overalls_environment
        + "/home/tester/.local/bin/overalls open https://unsupported.example.test/overalls/fixture -- true "
        + ">/dev/null 2>&1",
        timeout=60,
    )
    assert refused != 0
    assert sql("SELECT count(*) FROM compute_virtual_machines") == vms_before
    # The CLI's own stderr (progress and SSH errors, no credentials) is kept in
    # a private file and summarized only by fixed markers on failure.
    cli_status, head = client.execute(
        overalls_environment
        + "/home/tester/.local/bin/overalls open "
        + shlex.quote(fixture_urls["branch"])
        + " -- git rev-parse HEAD 2>"
        + browser_root
        + "/open.err",
        timeout=1500,
    )
    if cli_status != 0:
        stderr_text = client.succeed("cat " + browser_root + "/open.err")
        markers = [
            marker
            for marker in (
                "is running",
                "waiting for the machine to accept SSH",
                "guest SSH did not become ready",
                "SSH proxy unavailable",
                "repository cloning",
                "repository done",
                "clone failed",
                "Permission denied",
                "Host key verification failed",
                "machine creation failed",
            )
            if marker in stderr_text
        ]
        raise AssertionError({"exit": cli_status, "markers": markers})
    assert branch_sha in head.split()
    assert sql("SELECT count(*) FROM compute_virtual_machines") == str(int(vms_before) + 1)
    cli_vm = sql(
        "SELECT v.id FROM compute_virtual_machines v JOIN compute_workspace_sources s "
        "ON s.vm_id=v.id WHERE v.archived_at IS NULL AND s.provider='github' AND s.revision->>'kind'='ref'"
    )
    assert str(uuid.UUID(cli_vm)) == cli_vm
    assert sql(f"SELECT profile FROM compute_virtual_machines WHERE id='{cli_vm}'") == "oss"
    guest_checkout(cli_vm, "clone", branch_sha)
