"""Real OTP encryption and off-host decryption using a disposable fixture key."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

erl = sys.argv[1]
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    private = root / "private.pem"
    public = root / "public.pem"
    subprocess.run(
        [
            "openssl",
            "genpkey",
            "-algorithm",
            "RSA",
            "-pkeyopt",
            "rsa_keygen_bits:3072",
            "-out",
            str(private),
        ],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)],
        check=True,
        capture_output=True,
    )
    env = dict(
        os.environ,
        ERL_CRASH_DUMP_PUBLIC_KEY=str(public),
        ERL_CRASH_DUMP=str(root / "crash.dump"),
        ERL_CRASH_DUMP_SECONDS="10",
        ERL_CRASH_DUMP_BYTES="268435456",
    )
    command = [erl, "+S", "2:2", "-noshell", "-eval"]
    subprocess.run(
        [
            *command,
            'put(fixture_secret, crash_encryption_private_sentinel), erlang:halt("fixture").',
        ],
        env=env,
        capture_output=True,
        timeout=20,
    )
    encrypted = (root / "crash.dump").read_bytes()
    assert len(encrypted) <= 268435456
    assert b"crash_encryption_private_sentinel" not in encrypted
    env["ERL_CRASH_DUMP"] = "/dev/null"
    expression = (
        "ok = crashdump:pem_decrypt("
        + ",".join(
            json.dumps(str(path))
            for path in [root / "crash.dump", private, root / "decrypted.dump"]
        )
        + "), halt()."
    )
    subprocess.run([*command, expression], env=env, capture_output=True, check=True, timeout=20)
    assert b"crash_encryption_private_sentinel" in (root / "decrypted.dump").read_bytes()
    env.pop("ERL_CRASH_DUMP_PUBLIC_KEY")
    failed = subprocess.run([*command, "halt()."], env=env, capture_output=True, timeout=20)
    assert failed.returncode != 0, "encrypted runtime must reject missing public key"
print("Encrypted OTP dump round-trip, byte bound and missing-key rejection passed")
