"""Seal runtime-only role credentials to the disposable VM's SSH host key."""

import json
import os
import secrets
import subprocess
import sys
from collections.abc import Mapping
from pathlib import Path


def seal(sops: str, recipient: str, root: Path, service: str, values: Mapping[str, str]) -> None:
    payload = json.dumps({f"overalls-{service}": {"production": values}}).encode()
    result = subprocess.run(
        [
            sops,
            "--encrypt",
            "--age",
            recipient,
            "--input-type",
            "json",
            "--output-type",
            "json",
            "/dev/stdin",
        ],
        input=payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=True,
    )
    stage = root / f"{service}.enc.json.new"
    stage.unlink(missing_ok=True)
    with stage.open("xb") as stream:
        stream.write(result.stdout)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(stage, root / f"{service}.enc.json")


def main() -> None:
    """@cc [owner:ghuntley,label:verification;security] role-secret-runtime-sealing
    Required private-role documents MUST be generated only at VM runtime,
    encrypted for that VM's SSH-derived age recipient and atomically published
    before SecretSpec preparation; secret values MUST NOT enter arguments or logs.
    """
    if len(sys.argv) != 3:
        raise ValueError("expected SOPS and ssh-to-age executables")
    os.umask(0o077)
    root = Path("/run/overalls-test")
    root.mkdir(mode=0o700, exist_ok=True)
    recipient = subprocess.check_output(
        [sys.argv[2], "-i", "/etc/ssh/ssh_host_ed25519_key.pub"],
        stderr=subprocess.DEVNULL,
        text=True,
    ).strip()
    if not recipient:
        raise ValueError("missing fixture recipient")
    host_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    seal(
        sys.argv[1],
        recipient,
        root,
        "galileo",
        {"GALILEO_CREDENTIAL": f"{host_id}.{secrets.token_urlsafe(32)}"},
    )
    seal(
        sys.argv[1],
        recipient,
        root,
        "ziggy",
        {
            "ZIGGY_CREDENTIAL": f"{host_id}.{secrets.token_urlsafe(32)}",
            "OPENAI_API_KEY": secrets.token_urlsafe(32),
            "ANTHROPIC_API_KEY": secrets.token_urlsafe(32),
        },
    )


if __name__ == "__main__":
    main()
