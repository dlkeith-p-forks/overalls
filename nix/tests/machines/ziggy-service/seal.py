"""Runtime-only synthetic credentials through the real SOPS publication path."""

import json
import os
import subprocess
from pathlib import Path

os.umask(0o077)
recipient = (
    subprocess.check_output(["ssh-to-age", "-i", "/etc/ssh/ssh_host_ed25519_key.pub"])
    .decode()
    .strip()
)
values = dict(
    ZIGGY_CREDENTIAL="11111111-1111-4111-8111-111111111111." + "A" * 43,
    OPENAI_API_KEY="synthetic-openai-private",
    ANTHROPIC_API_KEY="synthetic-anthropic-private",
)
result = subprocess.run(
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
    input=json.dumps({"overalls-ziggy": {"production": values}}).encode(),
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    check=True,
)
Path("/run/ziggy-fixture/ziggy.enc.json").write_bytes(result.stdout)

galileo = subprocess.run(
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
    input=json.dumps(
        {"overalls-galileo": {"production": {"GALILEO_CREDENTIAL": "synthetic-galileo"}}}
    ).encode(),
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    check=True,
)
Path("/run/ziggy-fixture/galileo.enc.json").write_bytes(galileo.stdout)
