"""Exercise the real SSH/systemd/release/database boundary without printing tokens."""

import json
import os
import socket
import subprocess
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ssh = [
    "ssh",
    "-F",
    "/dev/null",
    "-o",
    "BatchMode=yes",
    "-o",
    "IdentitiesOnly=yes",
    "-o",
    "StrictHostKeyChecking=yes",
    "-o",
    "GlobalKnownHostsFile=/dev/null",
    "-o",
    "HostKeyAlgorithms=ssh-ed25519",
    "-o",
    "UserKnownHostsFile=/root/enrollment/known_hosts",
    "-i",
    "/root/enrollment/key",
    "operator@control",
    "sudo -n overalls-marshall-enrollment",
]
os.umask(0o077)
machine_id = subprocess.check_output(["overalls-lilly-identity"], text=True).strip()
pool_guid = subprocess.check_output(
    ["zpool", "get", "-Hp", "-o", "value", "guid", "zroot"], text=True
).strip()
dataset_guid = subprocess.check_output(
    ["zfs", "get", "-Hp", "-o", "value", "guid", "zroot/lilly"], text=True
).strip()
request = {
    "version": 3,
    "name": "example",
    "architecture": "x86_64",
    "machine_id": machine_id,
    "overhead_cores": 1,
    "overhead_memory_bytes": 1024,
    "credential_ttl_seconds": 157680000,
    "pools": [
        {
            "name": "guests",
            "overhead_bytes": 100,
            "storage": {
                "backend": "zfs",
                "zpool_guid": pool_guid,
                "dataset_guid": dataset_guid,
                "dataset": "zroot/lilly",
            },
        }
    ],
}


def invoke(
    operation: str,
    action: str = "prepare-enrollment",
    input_request: dict[str, object] | None = None,
    success: bool = True,
) -> dict[str, object] | None:
    result = subprocess.run(
        ssh,
        input=json.dumps(
            {"operation_id": operation, "action": action, "request": input_request or request}
        ).encode(),
        capture_output=True,
        timeout=150,
    )
    if not success:
        assert result.returncode != 0 and b"fixture-private-marker" not in result.stderr
        assert result.stdout == b""
        return None
    assert result.returncode == 0, "Protected operator failed"
    return json.loads(result.stdout)


def ready(expected: bool) -> None:
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        try:
            with socket.socket(socket.AF_UNIX) as channel:
                channel.settimeout(2)
                channel.connect("/run/lilly-release/status.sock")
                status: dict[str, object] = json.loads(channel.recv(4096))
                if status.get("ready") is expected:
                    return
        except (OSError, ValueError):
            pass
        time.sleep(0.25)
    raise AssertionError("Lilly did not reach expected readiness")


def host_command(action: str) -> dict[str, object]:
    result = subprocess.run(
        [
            "host",
            action,
            "--host",
            "example",
            "--root",
            "/root/enrollment/repo",
            "--target",
            "operator@client",
            "--marshall-target",
            "operator@control",
            "--identity",
            "/root/enrollment/key",
            "--known-hosts",
            "/root/enrollment/known_hosts",
            "--install-receipt",
            "/root/enrollment/installed.json",
            "--recovery-key",
            "/root/enrollment/key",
        ],
        capture_output=True,
        timeout=150,
    )
    assert result.returncode == 0, "Host preparation command failed: " + result.stderr.decode()
    assert b"PRIVATE KEY" not in result.stdout
    return json.loads(Path("/root/enrollment/repo/fleet/hosts/example/host.json").read_bytes())[
        "lilly"
    ]["binding"]


def activate(value: dict[str, object]) -> None:
    # Install the actual host CLI's ciphertext through the production secret unit.
    ciphertext = Path("/root/enrollment/repo/secrets/example-lilly.enc.json").read_bytes()
    Path("/run/enrollment.enc.json").write_bytes(ciphertext)
    Path("/run/enrollment-metadata.json").write_text(json.dumps(value["metadata"]))
    # Public fixture IDs; Lilly, as `lilly` (ADR-0182), reads them in preStart.
    Path("/run/enrollment-metadata.json").chmod(0o644)
    subprocess.run(
        ["systemctl", "restart", "overalls-secrets-lilly.service"],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["systemctl", "restart", "lilly.service"],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    ready(True)


binding = host_command("prepare-enrollment")
assert binding == host_command("prepare-enrollment")


operation = str(uuid.uuid4())
with ThreadPoolExecutor(max_workers=2) as pool:
    values = list(pool.map(lambda _: invoke(operation), range(2)))
assert values[0] == values[1], "Concurrent retries changed authority"
initial = values[0]
assert initial["metadata"]["enabled"] is False
assert initial["envelope"]["credential_id"] == initial["metadata"]["credential_id"]
assert len(initial["envelope"]["credential"]) == 80
activate(initial)
rotated_binding = host_command("rotate-credential")
assert rotated_binding["credential_id"] != binding["credential_id"]
state = next(Path("/root/.local/state/overalls/enrollment").glob("*.json"))
rotation = json.loads(state.read_bytes())["operation_id"]
next_value = invoke(rotation, "rotate-credential")
assert next_value == invoke(rotation, "rotate-credential")
ready(False)
activate(next_value)
assert next_value["envelope"]["credential"] != initial["envelope"]["credential"]
invoke(operation, success=False)
changed = dict(request, overhead_cores=2)
invoke(str(uuid.uuid4()), input_request=changed, success=False)
invalid = dict(request, credential_ttl_seconds=157680001)
invoke(str(uuid.uuid4()), input_request=invalid, success=False)
malformed = dict(
    request, name="fixture-private-marker", credential_ttl_seconds="fixture-private-marker"
)
invoke(str(uuid.uuid4()), input_request=malformed, success=False)
# Verify actual issued token bytes do not occur in the remote journal without
# sending the token as argv or returning the journal to the operator.
check = 'sudo -n python3 -c \'import subprocess,sys; token=sys.stdin.buffer.read(); data=subprocess.check_output(["journalctl","--no-pager"]); sys.exit(token in data)\''
result = subprocess.run(
    [*ssh[:-1], check],
    input=next_value["envelope"]["credential"].encode(),
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    timeout=30,
)
assert result.returncode == 0, "Credential appeared in diagnostics"
# Wrong pins must fail before reaching the bridge.
Path("/root/enrollment/known_hosts").write_text("")
invoke(str(uuid.uuid4()), success=False)
print(
    "SSH operator enrollment, concurrency, rotation, lifetime and diagnostic and actual Lilly readiness checks passed"
)
