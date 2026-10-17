"""Seal a VM-generated synthetic client key for the VM's real host identity."""

import json
import subprocess
from pathlib import Path

root = Path("/run/fixture")
recipient = subprocess.check_output(
    ["ssh-to-age", "-i", "/etc/ssh/ssh_host_ed25519_key.pub"], text=True
).strip()
payload = {
    "overalls-remote-builders": {"production": {"SSH_PRIVATE_KEY": (root / "client").read_text()}}
}
ciphertext = subprocess.check_output(
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
    input=json.dumps(payload).encode(),
)
(root / "keys.enc.json").write_bytes(ciphertext)
