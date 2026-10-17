"""Install distinct disposable provider credentials inside each native fixture."""

import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import TypedDict

DEADLINE = time.monotonic() + 300


class ProviderValues(TypedDict):
    OPENAI_API_KEY: str
    ANTHROPIC_API_KEY: str


def command(arguments: list[str], **options: object) -> bytes:
    remaining = DEADLINE - time.monotonic()
    if remaining <= 0:
        raise TimeoutError()
    return subprocess.run(
        arguments,
        check=True,
        stderr=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        timeout=min(120, remaining),
        **options,
    ).stdout


def ready(host: str) -> bool:
    connection = http.client.HTTPConnection("ziggy", timeout=3)
    peer = socket.socket(socket.AF_UNIX)
    peer.settimeout(3)
    try:
        peer.connect("/run/ziggy/proxy.sock")
        connection.sock = peer
        connection.request("GET", "/health/ready")
        response = connection.getresponse()
        if response.status != 200 or json.loads(response.read(4097)) != {
            "version": 1,
            "role": "ziggy",
            "ready": True,
            "host_id": host,
        }:
            return False
    finally:
        connection.close()
        peer.close()
    with socket.socket(socket.AF_UNIX) as peer:
        peer.settimeout(3)
        peer.connect("/run/audi-private/status.sock")
        with peer.makefile("rb") as stream:
            return json.loads(stream.readline(4097)) == {
                "version": 1,
                "role": "private",
                "ready": True,
            }


def main() -> None:
    """@cc [owner:ghuntley,label:verification;security] inception-provider-installation-scope
    This fixture MUST use each guest's own SOPS recipient and distinct disposable
    provider keys, preserving its independently enrolled control token. Provider
    trust and name mapping are fixture-only runtime changes, never image defaults.
    Failure diagnostics MUST exclude credentials and command output.
    """
    instance = sys.argv[1]
    if instance not in ("1", "2"):
        raise ValueError()
    os.umask(0o077)
    state = Path("/var/lib/inception")
    host = json.loads((state / "lilly.json").read_bytes())["host_id"]
    recipient = command(["ssh-to-age", "-i", "/etc/ssh/ssh_host_ed25519_key.pub"]).decode().strip()
    values: ProviderValues = {
        "OPENAI_API_KEY": "synthetic-inception-openai-" + instance,
        "ANTHROPIC_API_KEY": "synthetic-inception-anthropic-" + instance,
    }
    ciphertext = command(
        [
            "sops",
            "--encrypt",
            "--age",
            recipient,
            "--input-type",
            "json",
            "--output-type",
            "json",
            "/dev/stdin",
        ],
        input=json.dumps({"overalls-inception-ziggy": {"production": values}}).encode(),
    )
    (state / "ziggy-providers.enc.json").write_bytes(ciphertext)
    public = Path("/var/lib/inception-provider-fixture")
    public.mkdir(mode=0o755, exist_ok=True)
    public.chmod(0o755)
    bundle = Path("/etc/ssl/certs/ca-certificates.crt")
    base = public / "base.pem"
    if not base.exists():
        base.write_bytes(bundle.read_bytes())
    trust = public / "trust.pem"
    trust.write_bytes(
        base.read_bytes() + b"\n" + Path("/root/inception-provider-ca.pem").read_bytes()
    )
    trust.chmod(0o644)
    bundle.unlink()
    bundle.symlink_to(trust)
    hosts = Path("/etc/hosts")
    names = "11.0.0.2 api.openai.com api.anthropic.com # inception-provider-fixture\n"
    previous_hosts = hosts.read_text()
    if names not in previous_hosts:
        with tempfile.NamedTemporaryFile(
            mode="w", dir="/etc", prefix=".inception-hosts-", delete=False
        ) as output:
            temporary = Path(output.name)
            output.write(previous_hosts + "\n" + names)
        try:
            temporary.chmod(0o644)
            os.replace(temporary, hosts)
        finally:
            temporary.unlink(missing_ok=True)
    command(
        [
            "systemctl",
            "restart",
            "inception-ziggy-runtime.service",
            "overalls-secrets-inception-ziggy.service",
        ]
    )
    command(
        [
            "systemctl",
            "restart",
            "ziggy.service",
            "audi-private-certificate.service",
            "audi-private.service",
        ]
    )
    deadline = min(DEADLINE, time.monotonic() + 90)
    while time.monotonic() < deadline:
        try:
            if ready(host):
                return
        except (OSError, ValueError, http.client.HTTPException):
            pass
        time.sleep(1)
    raise ValueError()


try:
    main()
except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
    sys.exit("Independent private service fixture unavailable")
