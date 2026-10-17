"""Root SSH bridge to a bounded, unprivileged Marshall operator process."""

import json
import os
import pwd
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


def main() -> None:
    """@cc [owner:ghuntley,label:security] enrollment-operator-transport
    Private envelopes MUST travel only through authenticated caller pipes and
    private temporary files. The release MUST run without root privileges, with
    bounded runtime, and its diagnostics MUST NOT be returned to the caller.
    """
    os.umask(0o077)
    if os.getuid() != 0:
        raise ValueError()
    payload = sys.stdin.buffer.read(65537)
    if len(payload) > 65536:
        raise ValueError()
    value: dict[str, object] = json.loads(payload)
    if set(value) != {"operation_id", "action", "request"}:
        raise ValueError()
    action = value["action"]
    operation_id = value["operation_id"]
    if (
        not isinstance(action, str)
        or not isinstance(operation_id, str)
        or action
        not in (
            "prepare-enrollment",
            "rotate-credential",
        )
    ):
        raise ValueError()
    operation = str(uuid.UUID(operation_id))
    user = pwd.getpwnam("marshall-operator")
    with tempfile.TemporaryDirectory(prefix="marshall-enrollment-", dir="/run") as directory:
        work = Path(directory)
        os.chown(work, user.pw_uid, user.pw_gid)
        request = work / "request.json"
        request.write_text(json.dumps(value["request"]))
        os.chown(request, user.pw_uid, user.pw_gid)
        output = work / "credential.json"
        result = subprocess.run(
            [
                "systemd-run",
                "--quiet",
                "--wait",
                "--pipe",
                "--collect",
                "--property=User=marshall-operator",
                "--property=Group=marshall-operator",
                "--property=UMask=0077",
                "--property=RuntimeMaxSec=120",
                "--property=NoNewPrivileges=yes",
                "--property=PrivateDevices=yes",
                "--property=ProtectSystem=strict",
                "--property=ProtectHome=yes",
                "--property=ReadWritePaths=" + directory,
                "--property=EnvironmentFile=" + sys.argv[1],
                "--property=LoadCredential=database-ca.crt:" + sys.argv[3],
                sys.argv[2],
                action,
                operation,
                str(request),
                str(output),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=150,
        )
        if result.returncode:
            raise ValueError()
        metadata: dict[str, object] | None = None
        for line in (result.stdout or b"").splitlines():
            try:
                candidate: object = json.loads(line)
                if isinstance(candidate, dict) and candidate.get("operation_id") == operation:
                    metadata = candidate
            except ValueError:
                pass
        if metadata is None:
            raise ValueError()
        envelope: object = json.loads(output.read_bytes())
        sys.stdout.write(json.dumps({"metadata": metadata, "envelope": envelope}) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("Enrollment operation failed; retry with the same operation ID.", file=sys.stderr)
        sys.exit(1)
