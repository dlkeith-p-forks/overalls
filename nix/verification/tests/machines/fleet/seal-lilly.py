"""Encrypt an issued fixture credential; no production identities or remote providers."""

import json
import os
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path


def run(arguments: Sequence[str], payload: bytes | None = None) -> bytes:
    result = subprocess.run(
        arguments, input=payload, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60
    )
    if result.returncode:
        raise ValueError("fixture command failed")
    return result.stdout


def main() -> None:
    """@cc [owner:ghuntley,label:verification;security] fleet-issued-credential-sealing
    Lilly, Ziggy, Galileo and Peach documents MUST use independently issued control tokens
    and separate secret namespaces. Audi private may contain only the isolated
    fixture wildcard material. Sealing MUST publish atomically with private
    permissions, retain the recovery recipient, and never print secret payloads.
    """
    os.umask(0o077)
    service = sys.argv[1] if len(sys.argv) == 2 else "lilly"
    if service not in ("lilly", "ziggy", "galileo", "peach", "audi-private") or len(sys.argv) > 2:
        raise ValueError("invalid fixture service")
    root = Path("/var/lib/overalls-fleet")
    recovery = root / "update-recovery.ssh"
    if not recovery.exists():
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(recovery)])
    recipients = [
        run(["ssh-to-age", "-i", key]).decode().strip()
        for key in [
            "/etc/ssh/ssh_host_ed25519_key.pub",
            str(recovery) + ".pub",
        ]
    ]
    if service == "lilly":
        values = {"LILLY_CREDENTIAL": (root / "credential.json").read_text()}
    elif service == "ziggy":
        values = {
            "ZIGGY_CREDENTIAL": (root / "ziggy.token").read_text(),
            "OPENAI_API_KEY": "synthetic-openai-private",
            "ANTHROPIC_API_KEY": "synthetic-anthropic-private",
        }
    elif service == "galileo":
        values = {"GALILEO_CREDENTIAL": (root / "galileo.token").read_text()}
    elif service == "peach":
        values = {"PEACH_CREDENTIAL": (root / "peach.token").read_text()}
    else:
        certificate = Path(os.environ["FLEET_AUDI_PRIVATE_CERTIFICATE"])
        key = Path(os.environ["FLEET_AUDI_PRIVATE_KEY"])
        values = {
            "AUDI_PRIVATE_CERTIFICATE_CHAIN": certificate.read_text(),
            "AUDI_PRIVATE_CERTIFICATE_KEY": key.read_text(),
        }
    payload = json.dumps({"overalls-" + service: {"production": values}}).encode()
    encrypted = run(
        [
            "sops",
            "--encrypt",
            "--age",
            ",".join(recipients),
            "--input-type",
            "json",
            "--output-type",
            "json",
            "/dev/stdin",
        ],
        payload,
    )
    staged = root / (service + ".enc.json.new")
    staged.write_bytes(encrypted)
    os.replace(staged, root / (service + ".enc.json"))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("Fixture credential encryption failed", file=sys.stderr)
        sys.exit(1)
