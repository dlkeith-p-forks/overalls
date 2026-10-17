"""Closed, line-bounded guest control on a dedicated virtio-serial port."""

import json
import os
import re
import select
import subprocess
import time
from pathlib import Path
from typing import TypedDict

from oracle import observe, write_marker

EXPECTED_PUBLIC = b"isolated-brady-origin\n"
EXPECTED_PUBLIC_SHA256 = "4e9d451a3fcee7112d27aa982c0fe155d5185888769148ddda3fe7c8af1aae50"

PORT = Path("/dev/virtio-ports/org.overalls.storage.control")
MAX_LINE = 4096
IDENTIFIER = re.compile(r"[0-9a-f]{16}\Z")
SERVICE = {
    "brady": "brady.service",
    "origin": "brady-origin.service",
    "pressure": "brady-pressure.service",
}
LINK = {"guest": ("guest", "eth0"), "guest2": ("guest2", "eth0"), "origin": ("origin", "eth0")}
DISK = {"a": "KTROUTER-MIRROR-A", "b": "KTROUTER-MIRROR-B"}


class Request(TypedDict):
    version: int
    id: str
    action: str
    target: str | None
    value: int | str | None


def decode(line: bytes) -> Request:
    """@cc [owner:ghuntley,label:security] closed-router-fault-api
    Reject unknown fields and all paths, argv, shell, nft and QMP payloads.
    Every effect below selects fixed trusted executable arguments.
    """
    raw: object = json.loads(line)
    if not isinstance(raw, dict) or set(raw) != {"version", "id", "action", "target", "value"}:
        raise ValueError("invalid request fields")
    if (
        type(raw["version"]) is not int
        or raw["version"] != 1
        or not isinstance(raw["id"], str)
        or not IDENTIFIER.fullmatch(raw["id"])
    ):
        raise ValueError("invalid request identity")
    if not isinstance(raw["action"], str):
        raise ValueError("invalid action")
    target, value = raw["target"], raw["value"]
    if target is not None and not isinstance(target, str):
        raise ValueError("invalid target")
    if value is not None and not (type(value) is int or isinstance(value, str)):
        raise ValueError("invalid value")
    return Request(version=1, id=raw["id"], action=raw["action"], target=target, value=value)


def run(argv: list[str], timeout: int = 20) -> str:
    completed = subprocess.run(argv, capture_output=True, text=True, check=True, timeout=timeout)
    if len(completed.stdout) > 65536:
        raise ValueError("oversized control result")
    return completed.stdout.strip()


def effect(request: Request) -> dict[str, object]:
    action, target, value = request["action"], request["target"], request["value"]
    if action == "observe" and target is None and value is None:
        return observe()
    if action == "write_marker" and target is None and value is None:
        return dict(write_marker(request["id"]))
    if action in ("service_stop", "service_start") and target in SERVICE and value is None:
        unit = SERVICE[target]
        run(["systemctl", "stop" if action == "service_stop" else "start", unit], 45)
        return {
            "unit": unit,
            "active": run(["systemctl", "show", "-p", "ActiveState", "--value", unit]) == "active",
        }
    if action == "link" and target in LINK and value in ("up", "down"):
        namespace, device = LINK[target]
        run(["ip", "-n", namespace, "link", "set", device, value])
        return {"namespace": namespace, "device": device, "state": value}
    if action == "quota" and target in ("parent", "cache") and type(value) is int:
        bounds = {"parent": (64, 256, "tank/lilly"), "cache": (1, 64, "tank/brady")}
        lower, upper, dataset = bounds[target]
        if not lower <= value <= upper:
            raise ValueError("quota outside fixture bounds")
        amount = value * 1024 * 1024
        properties = [f"quota={amount}"] + ([f"refquota={amount}"] if target == "cache" else [])
        run(["zfs", "set", *properties, dataset])
        observed = int(run(["zfs", "get", "-Hpo", "value", "quota", dataset]))
        if observed != amount:
            raise ValueError("quota readback mismatch")
        return {"dataset": dataset, "quota_bytes": observed}
    if action in ("disk_offline", "disk_online") and target in DISK and value is None:
        member = "/dev/disk/by-id/virtio-" + DISK[target]
        run(["zpool", "offline" if action == "disk_offline" else "online", "tank", member], 45)
        return {
            "member": target,
            "pool_health": run(["zpool", "list", "-H", "-o", "health", "tank"]),
        }
    if action == "probe" and target in ("public_http", "public_https", "private_http"):
        if target == "private_http" and value is not None:
            raise ValueError("private probe takes no marker")
        public_key = ""
        if target != "private_http" and (
            not isinstance(value, str) or not IDENTIFIER.fullmatch(value)
        ):
            raise ValueError("invalid public probe marker")
        if isinstance(value, str):
            public_key = value
        url = (
            "https://origin.brady.test/public/" + public_key
            if target == "public_https"
            else "http://origin.brady.test/auth"
            if target == "private_http"
            else "http://origin.brady.test/public/" + public_key
        )
        argv = [
            "ip",
            "netns",
            "exec",
            "guest",
            "curl",
            "--noproxy",
            "*",
            "--silent",
            "--show-error",
            "--fail",
            "--max-time",
            "8",
        ]
        if target == "public_https":
            argv.extend(["--cacert", "/run/brady-fixture/ca.pem"])
        result = subprocess.run([*argv, url], capture_output=True, timeout=12, check=True)
        if result.stdout != EXPECTED_PUBLIC:
            raise ValueError("unexpected origin bytes")
        return {"route": target, "bytes": len(EXPECTED_PUBLIC), "sha256": EXPECTED_PUBLIC_SHA256}
    raise ValueError("unknown or malformed action")


def transact(line: bytes) -> bytes:
    request_id: str | None = None
    try:
        request = decode(line)
        request_id = request["id"]
        result: dict[str, object] = {
            "version": 1,
            "id": request_id,
            "status": "ok",
            "observation": effect(request),
        }
    except (ValueError, OSError, subprocess.SubprocessError, TimeoutError, json.JSONDecodeError):
        result = {"version": 1, "id": request_id, "status": "unavailable", "observation": None}
    return (json.dumps(result, separators=(",", ":"), sort_keys=True) + "\n").encode("ascii")


def read_frame(descriptor: int) -> bytes:
    deadline = time.monotonic() + 60
    data = bytearray()
    overflow = False
    while time.monotonic() < deadline:
        ready, _, _ = select.select([descriptor], [], [], max(0.0, deadline - time.monotonic()))
        if not ready:
            break
        chunk = os.read(descriptor, 1)
        if not chunk:
            time.sleep(0.05)
            continue
        if len(data) < MAX_LINE:
            data.extend(chunk)
        else:
            overflow = True
        if chunk == b"\n":
            if overflow:
                raise ValueError("oversized control frame")
            return bytes(data)
    raise TimeoutError("incomplete control frame")


def main() -> None:
    deadline = time.monotonic() + 60
    while not PORT.exists():
        if time.monotonic() >= deadline:
            raise TimeoutError("virtio control port unavailable")
        time.sleep(0.2)
    descriptor = os.open(PORT, os.O_RDWR | os.O_NOCTTY)
    with os.fdopen(descriptor, "r+b", buffering=0) as stream:
        while True:
            try:
                line = read_frame(descriptor)
            except (ValueError, TimeoutError):
                stream.write(b'{"version":1,"id":null,"status":"unavailable","observation":null}\n')
                continue
            stream.write(transact(line))


if __name__ == "__main__":
    main()
