"""Bounded read-only witness requests across the private inner-host 9p share."""

import argparse
import contextlib
import fcntl
import json
import os
import socket
import time
from pathlib import Path

from fault_worker import MAXIMUM, UUID, publish, read_object, sync_directory

OPERATIONS = {"identity", "witness", "terminal_witness", "terminal_input_stall"}


def validate(raw: object) -> dict[str, object]:
    if (
        not isinstance(raw, dict)
        or not isinstance(raw.get("operation"), str)
        or raw["operation"] not in OPERATIONS
    ):
        raise ValueError("invalid witness operation")
    operation = raw["operation"]
    keys = {"operation"}
    if operation != "identity":
        keys |= {"placement_id", "execution_epoch", "generation"}
        placement = raw.get("placement_id")
        if not isinstance(placement, str) or UUID.fullmatch(placement) is None:
            raise ValueError("invalid witness placement")
        for key in ("execution_epoch", "generation"):
            value = raw.get(key)
            if type(value) is not int or not 1 <= value <= MAXIMUM:
                raise ValueError("invalid witness tuple")
    if operation == "terminal_input_stall":
        keys.add("session_id")
        session = raw.get("session_id")
        if type(session) is not int or not 1 <= session <= MAXIMUM:
            raise ValueError("invalid witness terminal")
    if set(raw) != keys:
        raise ValueError("invalid witness fields")
    return raw


def query(path: Path, request: dict[str, object]) -> dict[str, object]:
    """@cc [owner:ghuntley,label:security;verification] inner-witness-fixed-route
    Witness requests MUST use only the operator-fixed read-only witness socket
    and the closed observation allowlist. No control operation, challenge,
    caller path, or unbounded frame may cross the transport.
    """
    body = (json.dumps(validate(request), separators=(",", ":")) + "\n").encode("ascii")
    if len(body) > 4096:
        raise ValueError("oversized witness request")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(35)
        connection.connect(str(path))
        connection.sendall(body)
        reply = bytearray()
        while not reply.endswith(b"\n"):
            part = connection.recv(16385 - len(reply))
            if not part:
                raise ValueError("truncated witness response")
            reply.extend(part)
            if len(reply) > 16384:
                raise ValueError("oversized witness response")
        value: object = json.loads(reply)
        if not isinstance(value, dict) or "boot_challenge" in value:
            raise ValueError("invalid witness response")
        return value


def process(spool: Path, witness_socket: Path, path: Path) -> None:
    raw = read_object(path)
    request_id = raw.get("request_id")
    if (
        set(raw) != {"request_id", "request"}
        or not isinstance(request_id, str)
        or UUID.fullmatch(request_id) is None
        or path.name != request_id + ".json"
    ):
        raise ValueError("invalid witness envelope")
    request = validate(raw["request"])
    result = spool / "witness_results" / path.name
    if not result.exists():
        response: dict[str, object] = {"state": "error", "error": "operation_failed"}
        with contextlib.suppress(OSError, ValueError):
            response = query(witness_socket, request)
        publish(result, {"request_id": request_id, "response": response})
    path.unlink()
    sync_directory(path.parent)


def serve(spool: Path, witness_socket: Path) -> None:
    for name in ("witness_requests", "witness_results"):
        (spool / name).mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(spool / "witness.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        while True:
            for path in sorted((spool / "witness_requests").glob("*.json"))[:64]:
                with contextlib.suppress(OSError, ValueError):
                    process(spool, witness_socket, path)
            time.sleep(0.05)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spool", type=Path, required=True)
    parser.add_argument("--socket", type=Path, required=True)
    args = parser.parse_args()
    for path in (args.spool, args.socket):
        if not path.is_absolute() or ".." in path.parts:
            raise ValueError("invalid witness worker path")
    serve(args.spool, args.socket)


if __name__ == "__main__":
    main()
