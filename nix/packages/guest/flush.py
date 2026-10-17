"""Host-only best-effort disk flush. No freeze or arbitrary guest commands."""

import contextlib
import importlib.util
import json
import re
import socket
import subprocess
import sys
from collections.abc import Callable, Mapping
from typing import TypedDict

PORT = 1026
LIMIT = 1024


class Boot(TypedDict):
    placement_id: str
    execution_epoch: int
    boot_challenge: str


def boot_value(value: object) -> Boot:
    if not isinstance(value, dict):
        raise ValueError("invalid boot identity")
    placement, epoch, challenge = (
        value.get("placement_id"),
        value.get("execution_epoch"),
        value.get("boot_challenge"),
    )
    if not isinstance(placement, str) or type(epoch) is not int or not isinstance(challenge, str):
        raise ValueError("invalid boot identity")
    return Boot(placement_id=placement, execution_epoch=epoch, boot_challenge=challenge)


def receive(connection: socket.socket) -> object:
    body = bytearray()
    while len(body) <= LIMIT:
        byte = connection.recv(1)
        if not byte:
            raise ValueError("incomplete request")
        body.extend(byte)
        if byte == b"\n":
            return json.loads(body)
    raise ValueError("oversized request")


def answer(
    connection: socket.socket,
    peer: tuple[int, int],
    boot: Boot,
    boot_id: str,
    sync: Callable[[], None],
) -> None:
    """@cc [owner:ghuntley,label:security;recovery] flush-only-current-boot
    Only host CID 2 with this boot's exact identity and a request nonce
    may invoke the fixed sync operation. Success MUST follow sync completion;
    no request may freeze a filesystem or select an executable or arguments.
    """
    connection.settimeout(2)
    if peer[0] != 2:
        return
    request = receive(connection)
    identity: Mapping[str, str | int] = {
        "placement_id": boot["placement_id"],
        "execution_epoch": boot["execution_epoch"],
        "boot_challenge": boot["boot_challenge"],
    }
    if not isinstance(request, dict) or set(request) != {
        "version",
        "operation",
        "nonce",
        *identity,
    }:
        return
    nonce = request["nonce"]
    if (
        type(request["version"]) is not int
        or request["version"] != 1
        or request["operation"] != "sync"
        or type(request["execution_epoch"]) is not int
        or any(request[key] != value for key, value in identity.items())
        or not isinstance(nonce, str)
        or not re.fullmatch(r"[0-9a-f]{64}", nonce)
    ):
        return
    sync()
    connection.sendall(
        json.dumps(
            {
                "version": 1,
                "state": "flushed",
                "nonce": nonce,
                "boot_id": boot_id,
                **identity,
            },
            separators=(",", ":"),
        ).encode("ascii")
        + b"\n"
    )


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("flush tools not configured")
    spec = importlib.util.spec_from_file_location("readiness", sys.argv[1])
    if spec is None or spec.loader is None:
        raise SystemExit("readiness helper unavailable")
    readiness = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(readiness)
    try:
        with open("/proc/cmdline", encoding="ascii") as source:
            boot = boot_value(readiness.identity(source.read(4097)))
        with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as source:
            boot_id = source.read(64).strip()
        readiness.response(boot, boot_id)
    except (OSError, ValueError):
        raise SystemExit("invalid flush boot configuration") from None

    def sync() -> None:
        # One request at a time: a stalled disk must not accumulate sync workers.
        subprocess.run(
            [sys.argv[2]],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
            timeout=8,
        )

    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as listener:
        listener.bind((socket.VMADDR_CID_ANY, PORT))
        listener.listen(1)
        while True:
            connection, peer = listener.accept()
            with connection, contextlib.suppress(OSError, ValueError, subprocess.SubprocessError):
                answer(connection, peer, boot, boot_id, sync)


if __name__ == "__main__":
    main()
