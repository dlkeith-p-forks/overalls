"""Validate encryption before starting BEAM; keep bounded local encrypted artifacts."""

import json
import os
import re
import stat
import subprocess
import sys
import time
from pathlib import Path


def prune(directory: Path, keep: int) -> None:
    files = sorted(directory.glob("*.dump"), key=lambda p: p.stat().st_mtime, reverse=True)
    for index, path in enumerate(files):
        if index >= keep or path.stat().st_mtime < time.time() - 7 * 86400:
            path.unlink()


def main() -> None:
    mode, directory = sys.argv[1:3]
    directory = Path(directory)
    if mode == "prune":
        if directory.exists():
            prune(directory, 3)
        return
    if mode == "finish":
        prune(directory, 3)
        for path in directory.glob("*.dump"):
            if not re.fullmatch(r"[0-9a-f]{32}\.dump", path.name):
                continue
            marker = path.with_suffix(".reported")
            if not marker.exists():
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    info = os.fstat(fd)
                    encrypted = (
                        stat.S_ISREG(info.st_mode)
                        and info.st_nlink == 1
                        and os.read(fd, 4) == b"ENC0"
                    )
                finally:
                    os.close(fd)
                print(
                    json.dumps(
                        {
                            "event": "runtime.crash_dump",
                            "artifact": path.name,
                            "bytes": info.st_size,
                            "encrypted": encrypted,
                        }
                    ),
                    flush=True,
                )
                marker.touch(mode=0o600)
        for marker in directory.glob("*.reported"):
            if not marker.with_suffix(".dump").exists():
                marker.unlink()
        return
    key, metadata, openssl, *command = sys.argv[3:]
    if not json.loads(Path(metadata).read_text()).get("encrypted_crash_dumps"):
        raise ValueError("release lacks encryption")
    result = subprocess.run(
        [openssl, "pkey", "-pubin", "-in", key, "-text_pub", "-noout"],
        capture_output=True,
        check=True,
        timeout=5,
    )
    match = re.search(rb"Public-Key: \(([0-9]+) bit\)", result.stdout)
    if not match or int(match[1]) < 3072 or b"Modulus:" not in result.stdout:
        raise ValueError("invalid public RSA key")
    if mode == "check":
        return
    invocation = os.environ.get("INVOCATION_ID", "")
    if not re.fullmatch("[0-9a-f]{32}", invocation):
        raise ValueError("invalid invocation identity")
    prune(directory, 2)
    os.environ.update(
        ERL_CRASH_DUMP_PUBLIC_KEY=key,
        ERL_CRASH_DUMP=str(directory / (invocation + ".dump")),
        ERL_CRASH_DUMP_SECONDS="10",
        ERL_CRASH_DUMP_BYTES="268435456",
    )
    os.execv(command[0], command)


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except Exception:
        print('{"event":"runtime.crash_dump_configuration_failed"}', file=sys.stderr)
        sys.exit(1)
