"""Packaged edge and managed client journey against controlled provider data."""

import hashlib
import json
import shlex


def gh(arguments: list[str], *, second: bool = False) -> str:
    machine = client2 if second else client
    return machine.succeed(shlex.join(["gh", *arguments]), timeout=60)


def authority_state(owner: int, phase: str, generation: int = 1) -> None:
    value = json.dumps({"phase": phase, "generation": generation})
    script = (
        "from pathlib import Path\n"
        f"Path('/run/galileo-fixture/authority-{owner}.json').write_text({value!r})\n"
    )
    proxy.succeed(shlex.join(["python3", "-c", script]))


def observations() -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for line in proxy.succeed("cat /run/galileo-fixture/observed.jsonl").splitlines():
        value: object = json.loads(line)
        assert isinstance(value, dict)
        row: dict[str, object] = {}
        for key, item in value.items():
            assert isinstance(key, str)
            row[key] = item
        rows.append(row)
    return rows


def request_count(path: str, method: str) -> int:
    return sum(
        row.get("event") == "request" and row.get("path") == path and row.get("method") == method
        for row in observations()
    )


start_all()
proxy.wait_for_unit("galileo-fixture.service")
proxy.wait_until_succeeds("test -S /run/galileo-fixture/connector.sock", timeout=60)
proxy.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
proxy.succeed("python3 /etc/galileo-seal.py")
proxy.succeed("systemctl restart overalls-secrets-galileo.service")
proxy.succeed("systemctl start galileo.service")
proxy.wait_for_unit("galileo.service")
proxy.wait_until_succeeds(
    "curl -fsS --unix-socket /run/galileo/proxy.sock http://galileo/health/ready"
)
proxy.succeed("ip address add 169.254.254.1/32 dev lo")
proxy.succeed("systemctl start audi-private-fixture.service")
proxy.wait_for_unit("audi-private-fixture.service")

second_address = (
    client2.succeed("ip -4 -o address show dev eth1 | awk '{print $4}'").strip().split("/")[0]
)
assert second_address
proxy.succeed(
    shlex.join(["printf", "%s", second_address]) + " > /run/galileo-fixture/client2-address"
)
for machine in [client, client2]:
    gateway = machine.succeed("cat /etc/galileo-proxy-address").strip()
    machine.succeed("ip route add 169.254.254.1/32 via " + shlex.quote(gateway))
    machine.succeed("git config --global user.name Fixture")
    machine.succeed("git config --global user.email fixture@example.test")
    machine.succeed("git lfs install --skip-repo")
    machine.wait_until_succeeds("gh api user --jq .login", timeout=60)

with subtest("each actual managed gh client receives its VM owner's identity"):
    assert gh(["api", "user", "--jq", ".login"]).strip() == "owner-1"
    assert gh(["api", "user", "--jq", ".login"], second=True).strip() == "owner-2"
    assert (
        gh(["api", "graphql", "-f", "query={viewer{login}}", "--jq", ".data.viewer.login"]).strip()
        == "owner-1"
    )
    assert gh(["api", "repos/owner/private", "--jq", ".private"]).strip() == "true"
    assert gh(["api", "user/orgs", "--jq", ".[0].login"]).strip() == "fixture-org"

with subtest("private Git clone and push use the system broker configuration"):
    client.succeed("git clone https://github.com/owner/private.git /root/private", timeout=60)
    assert (
        client.succeed("cat /root/private/README.md").strip() == "Synthetic private GitHub fixture"
    )
    client.succeed("git -C /root/private switch -c feature")
    client.succeed("printf 'private push\n' > /root/private/feature.txt")
    client.succeed("git -C /root/private add feature.txt")
    client.succeed("git -C /root/private commit -m feature")
    client.succeed("git -C /root/private push origin feature", timeout=60)
    assert (
        proxy.succeed(
            "git --git-dir=/run/galileo-fixture/repositories/owner/private.git show feature:feature.txt"
        ).strip()
        == "private push"
    )
    assert (
        gh(
            [
                "api",
                "repos/owner/private/pulls",
                "-X",
                "POST",
                "-f",
                "title=Fixture",
                "-f",
                "head=feature",
                "-f",
                "base=main",
                "--jq",
                ".number",
            ]
        ).strip()
        == "1"
    )

with subtest("pagination and renamed reads preserve CLI behavior while mutations dispatch once"):
    assert gh(
        ["api", "--paginate", "repos/owner/private/issues", "--jq", ".[].number"]
    ).splitlines() == ["1", "2"]
    assert gh(["api", "repos/owner/old", "--jq", ".full_name"]).strip() == "owner/private"
    before = request_count("/repos/owner/private", "POST")
    client.fail("gh api repos/owner/old -X POST -f marker=one")
    assert request_count("/repos/owner/old", "POST") == 1
    assert request_count("/repos/owner/private", "POST") == before
    client.fail("gh api fixture/unreviewed-redirect")
    assert all(row.get("host") != "attacker.invalid" for row in observations())

with subtest(
    "Actions artifacts and logs use opaque downloads and release uploads use uploads origin"
):
    gh(
        [
            "run",
            "download",
            "1",
            "--repo",
            "owner/private",
            "--name",
            "fixture",
            "--dir",
            "/root/artifacts",
        ]
    )
    assert client.succeed("cat /root/artifacts/fixture.txt").strip() == "synthetic Actions artifact"
    client.succeed("gh api repos/owner/private/actions/runs/1/logs > /root/logs.zip")
    client.succeed("printf 'release fixture\n' > /root/release.txt")
    gh(["release", "upload", "v1", "/root/release.txt", "--repo", "owner/private"])
    uploads = [row for row in observations() if row.get("event") == "release_upload"]
    assert len(uploads) == 1
    assert uploads[0]["sha256"] == hashlib.sha256(b"release fixture\n").hexdigest()

with subtest("actual Git LFS upload, verify and second-owner download never expose action headers"):
    payload = bytes(range(256)) * 1000
    oid = hashlib.sha256(payload).hexdigest()
    client.succeed("git -C /root/private switch main")
    client.succeed("git -C /root/private lfs install --local")
    client.succeed("git -C /root/private lfs track '*.bin'")
    client.succeed(
        shlex.join(
            [
                "python3",
                "-c",
                "from pathlib import Path\nPath('/root/private/object.bin').write_bytes(bytes(range(256))*1000)\n",
            ]
        )
    )
    client.succeed("git -C /root/private add .gitattributes object.bin")
    client.succeed("git -C /root/private commit -m lfs")
    client.succeed("git -C /root/private push origin main", timeout=90)
    assert proxy.succeed("sha256sum /run/galileo-fixture/lfs/" + oid).split()[0] == oid
    client2.succeed(
        "git clone https://github.com/owner/private.git /root/second-private", timeout=90
    )
    assert client2.succeed("sha256sum /root/second-private/object.bin").split()[0] == oid
    transfers = [
        row
        for row in observations()
        if row.get("host")
        in {"github-cloud.githubusercontent.com", "github-cloud.s3.amazonaws.com"}
    ]
    assert any(row.get("method") == "PUT" for row in transfers)
    assert any(row.get("method") == "GET" for row in transfers)
    assert all(row.get("credential") == "action" for row in transfers)

with subtest(
    "capabilities bind VM identity and generation, and detach retains anonymous public access"
):
    capability = gh(["api", "fixture/capability", "--jq", ".url"]).strip()
    assert capability.startswith("https://com-github.integration.internal/capabilities/")
    assert "sig=" not in capability
    client2.fail(shlex.join(["gh", "api", capability]))
    authority_state(1, "active", 2)
    client.fail(shlex.join(["gh", "api", capability]))
    assert gh(["api", "user", "--jq", ".login"]).strip() == "owner-1"
    authority_state(1, "anonymous", 2)
    assert gh(["api", "public", "--jq", ".authenticated"]).strip() == "false"
    client.fail("gh api user")
    assert gh(["api", "user", "--jq", ".login"], second=True).strip() == "owner-2"
    authority_state(1, "active", 2)

with subtest("withdrawing a current lease closes the same real upstream without retry"):
    client.succeed(
        "systemd-run --quiet --unit=github-held --property=Type=oneshot --property=StandardOutput=null --property=StandardError=null gh api fixture/hold"
    )
    proxy.wait_until_succeeds("grep -q 'hold_opened' /run/galileo-fixture/observed.jsonl")
    authority_state(1, "anonymous", 2)
    proxy.wait_until_succeeds(
        "grep -q 'hold_closed' /run/galileo-fixture/observed.jsonl", timeout=5
    )
    client.wait_until_succeeds("! systemctl is-active --quiet github-held.service", timeout=5)
    assert request_count("/fixture/hold", "GET") == 1
    assert any(row.get("event") == "renewal_refused" for row in observations())
    authority_state(1, "active", 2)
    authority_state(1, "outage", 2)
    client.fail("gh api user")
    authority_state(1, "active", 2)
    assert gh(["api", "user", "--jq", ".login"]).strip() == "owner-1"

with subtest("guests and ordinary service diagnostics contain no provider credentials"):
    snapshot_script = """
import os
from pathlib import Path
contents: list[str] = [repr(dict(os.environ))]
for path in Path('/root').rglob('*'):
    if path.is_file() and path.stat().st_size < 1048576:
        contents.append(path.read_bytes().decode('utf-8', errors='ignore'))
for forbidden in ['synthetic-owner-', 'RemoteAuth action-', 'sig=synthetic', 'synthetic-provider-cookie']:
    assert all(forbidden not in value for value in contents), 'Provider credential reached guest storage'
print('clean')
"""
    for machine in [client, client2]:
        assert machine.succeed(shlex.join(["python3", "-c", snapshot_script])).strip() == "clean"
    diagnostic_script = """
import subprocess
logs = subprocess.run(['journalctl', '-u', 'galileo.service', '-u', 'audi-private-fixture.service', '--no-pager'], check=True, capture_output=True, text=True).stdout
for forbidden in ['synthetic-owner-', 'RemoteAuth action-', 'sig=synthetic']:
    assert forbidden not in logs, 'Provider credential reached service diagnostics'
print('clean')
"""
    assert proxy.succeed(shlex.join(["python3", "-c", diagnostic_script])).strip() == "clean"
    assert all(
        row.get("credential") != "oauth"
        for row in observations()
        if row.get("host") == "release-assets.githubusercontent.com"
    )
    proxy.wait_until_succeeds(
        "curl -fsS --unix-socket /run/galileo/proxy.sock http://localhost/metrics | jq -e '.gauges.galileo_active_requests == 0'"
    )
