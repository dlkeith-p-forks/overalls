"""Bounded private readiness probe for a disposable NixOS fixture only."""

import json
import socket
import sys
import time


def ready(path: str) -> bool:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
        channel.settimeout(2)
        channel.connect(path)
        body = b""
        while b"\n" not in body:
            chunk = channel.recv(4097 - len(body))
            if not chunk or len(body) + len(chunk) > 4096:
                raise AssertionError("Invalid readiness frame")
            body += chunk
        value: object = json.loads(body)
        if not isinstance(value, dict):
            raise AssertionError("Invalid readiness schema")
        base = {"version", "ready", "phase"}
        if set(value) not in (base, base | {"protocol_version", "terminal_ready"}):
            raise AssertionError("Invalid readiness fields")
        if type(value["version"]) is not int or value["version"] != 1:
            raise AssertionError("Invalid readiness version")
        result = value["ready"]
        if not isinstance(result, bool) or value["phase"] not in (
            "connecting",
            "connected",
            "fenced",
            "unavailable",
        ):
            raise AssertionError("Invalid readiness fields")
        if set(value) == base:
            if result or value["phase"] != "unavailable":
                raise AssertionError("Invalid unavailable readiness")
        else:
            if type(value["protocol_version"]) is not int or value["protocol_version"] != 4:
                raise AssertionError("Invalid runtime protocol")
            if not isinstance(value["terminal_ready"], bool):
                raise AssertionError("Invalid terminal readiness")
            if result and (value["phase"] != "connected" or not value["terminal_ready"]):
                raise AssertionError("Invalid positive readiness")
        return result


def verify(path: str, expected: bool, duration: float) -> None:
    """@cc [owner:ghuntley,label:verification] readiness-watch-fail-closed
    Every complete reply during the bounded observation MUST match the expected
    readiness. Missing/refused sockets MAY count as false only during a negative
    watch; a single sample MUST obtain a complete reply. Malformed replies MUST
    fail either observation.
    """
    deadline = time.monotonic() + duration
    while True:
        try:
            actual = ready(path)
        except (FileNotFoundError, ConnectionRefusedError):
            if duration == 0:
                raise
            actual = False
        assert actual == expected, "Unexpected runtime readiness"
        if time.monotonic() >= deadline:
            return
        time.sleep(0.1)


if __name__ == "__main__":
    assert len(sys.argv) in (3, 4)
    assert sys.argv[2] in ("true", "false")
    duration = float(sys.argv[3]) if len(sys.argv) == 4 else 0.0
    assert 0 <= duration <= 30
    verify(sys.argv[1], sys.argv[2] == "true", duration)
