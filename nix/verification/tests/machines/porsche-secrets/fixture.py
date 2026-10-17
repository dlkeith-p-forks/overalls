"""Private fixture sealing and verification; never emit tokens or decrypted data."""

import json
import os
import socket
import subprocess
import sys
from pathlib import Path

root = Path("/run/porsche-fixture")
document = Path("/run/porsche-sealed/gateway.enc.json")
mode = sys.argv[1]
if mode in ("seal", "missing"):
    recipient = subprocess.check_output(
        ["ssh-to-age", "-i", "/etc/ssh/ssh_host_ed25519_key.pub"], text=True
    ).strip()
    values = (
        {} if mode == "missing" else {"PORSCHE_GATEWAY_TOKEN": (root / sys.argv[2]).read_text()}
    )
    payload = json.dumps({"overalls-porsche": {"production": values}}).encode()
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
        input=payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=True,
    )
    temporary = document.with_suffix(".new")
    temporary.write_bytes(result.stdout)
    os.replace(temporary, document)
elif mode == "ready":
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(8)
        client.connect("/run/porsche/status.sock")
        response = json.loads(client.makefile("rb").readline(4097))
        assert response == {"version": 1, "ready": sys.argv[2] == "true"}
elif mode == "custody":
    import pwd

    token = Path("/run/overalls-secrets/porsche/token")
    runtime = Path("/run/porsche/gateway.token")
    assert token.read_bytes() == runtime.read_bytes() == (root / sys.argv[2]).read_bytes()
    assert token.stat().st_uid == 0 and token.stat().st_mode & 0o777 == 0o600
    assert runtime.stat().st_uid == pwd.getpwnam("porsche").pw_uid
    assert runtime.stat().st_mode & 0o777 == 0o400 and runtime.stat().st_nlink == 1
    assert not Path("/run/overalls-secrets-porsche/identity").exists()
    logs = subprocess.check_output(
        [
            "journalctl",
            "-u",
            "porsche.service",
            "-u",
            "marshall-primary.service",
            "-u",
            "porsche-fixture-operator.service",
            "-u",
            "overalls-secrets-porsche.service",
            "--no-pager",
            "-o",
            "cat",
        ]
    )
    for name in ("first", "next"):
        if (root / name).exists():
            assert (root / name).read_bytes() not in logs
else:
    raise ValueError("invalid fixture mode")
