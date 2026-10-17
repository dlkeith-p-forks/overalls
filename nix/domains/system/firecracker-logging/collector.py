"""Bounded native FIFO reader. This process has no VM lifecycle authority."""

import contextlib
import json
import os
import re
import selectors
import stat
import sys
import time
import uuid
from pathlib import Path
from typing import Literal, TypedDict

MANIFESTS = Path("/var/lib/overalls-firecracker")
LOGS = Path("/var/log/overalls/firecracker")
KEY = re.compile(r"[0-9a-f-]{36}-[0-9]+-[0-9]+")
MAX_LINE = 65536
FILE_BYTES = 16 * 1024 * 1024

type StreamKind = Literal["log", "metrics"]


class Manifest(TypedDict):
    placement_id: str
    execution_epoch: int
    generation: int
    uid: int
    log: str
    metrics: str


class Stream(TypedDict):
    fd: int
    manifest: Manifest
    identity: tuple[str, StreamKind]
    buffer: bytes
    discard: bool
    dropped: int


def safe_open(path: str, flags: int) -> int:
    parts = Path(path).parts
    if not parts or parts[0] != "/" or ".." in parts:
        raise ValueError("invalid path")
    directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts[1:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        return os.open(parts[-1], flags | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory)
    finally:
        os.close(directory)


# Lilly writes stream manifests as its service user (ADR-0182), given as the
# third argument; no other owner is accepted.
MANIFEST_OWNERS: set[int] = set()


def read_manifest(path: Path) -> Manifest:
    fd = safe_open(str(path), os.O_RDONLY)
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid not in MANIFEST_OWNERS
            or info.st_mode & 0o077
            or info.st_nlink != 1
        ):
            raise ValueError("invalid manifest")
        raw = os.read(fd, 8193)
        if len(raw) > 8192:
            raise ValueError("oversized manifest")
        value: object = json.loads(raw)
        if not isinstance(value, dict):
            raise TypeError("invalid manifest")
        placement_id = value.get("placement_id")
        execution_epoch = value.get("execution_epoch")
        generation = value.get("generation")
        uid = value.get("uid")
        log = value.get("log")
        metrics = value.get("metrics")
        if (
            not isinstance(placement_id, str)
            or type(execution_epoch) is not int
            or type(generation) is not int
            or type(uid) is not int
            or not isinstance(log, str)
            or not isinstance(metrics, str)
        ):
            raise TypeError("invalid manifest")
        key = f"{placement_id}-{execution_epoch}-{generation}"
        if not KEY.fullmatch(key) or path.stem != key or not 1000002 <= uid <= 1262142:
            raise ValueError("invalid manifest identity")
        return Manifest(
            placement_id=placement_id,
            execution_epoch=execution_epoch,
            generation=generation,
            uid=uid,
            log=log,
            metrics=metrics,
        )
    finally:
        os.close(fd)


def write_record(key: str, record: dict[str, str | int], budget: int) -> int:
    encoded = (json.dumps(record, separators=(",", ":")) + "\n").encode()
    target = LOGS / (key + ".log")
    if target.exists() and target.stat().st_size + len(encoded) > FILE_BYTES:
        for index in range(7, 0, -1):
            src = target if index == 1 else Path(str(target) + f".{index - 1}")
            dst = Path(str(target) + f".{index}")
            if src.exists():
                src.replace(dst)
    files = sorted(LOGS.glob("*.log*"), key=lambda p: p.stat().st_mtime_ns)
    own = [path for path in files if path.name.startswith(key[:36] + "-")]
    dropped = 0
    # Eight files across all generations of a placement, not eight per boot.
    while len(own) > (8 if target in own else 7):
        old = own.pop(0)
        old.unlink()
        files.remove(old)
        dropped += 1
    size = sum(p.stat().st_size for p in files)
    for old in files:
        if size + len(encoded) <= budget:
            break
        size -= old.stat().st_size
        old.unlink()
        dropped += 1
    if len(encoded) <= budget:
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, encoded)
        finally:
            os.close(fd)
    return dropped


def main(budget: int, max_streams: int) -> None:
    os.umask(0o077)
    selector = selectors.DefaultSelector()
    streams: dict[tuple[str, StreamKind], Stream] = {}
    loss = dict(native_dropped_logs=0, dropped_lines=0, evicted_files=0, read_errors=0)
    last_scan: float = 0
    last_report: float = 0
    while True:
        now = time.monotonic()
        if now - last_scan >= 5:
            last_scan = now
            for path in MANIFESTS.glob("*.json"):
                try:
                    manifest = read_manifest(path)
                    for kind in ("log", "metrics"):
                        identity: tuple[str, StreamKind] = (path.stem, kind)
                        if identity in streams or len(streams) >= max_streams:
                            continue
                        fd = safe_open(manifest[kind], os.O_RDONLY | os.O_NONBLOCK)
                        info = os.fstat(fd)
                        if not stat.S_ISFIFO(info.st_mode) or info.st_uid != manifest["uid"]:
                            os.close(fd)
                            raise ValueError("invalid fifo")
                        state = Stream(
                            fd=fd,
                            manifest=manifest,
                            identity=identity,
                            buffer=b"",
                            discard=False,
                            dropped=0,
                        )
                        streams[identity] = state
                        selector.register(fd, selectors.EVENT_READ, state)
                except FileNotFoundError:
                    # A manifest is published only after both FIFOs exist. Jail
                    # cleanup removes them after the VM is stopped. Lilly owns
                    # the directory (ADR-0182) and prunes stale manifests; the
                    # collector has no DAC override, so it only tries.
                    with contextlib.suppress(PermissionError):
                        path.unlink(missing_ok=True)
                except (OSError, ValueError, KeyError, TypeError):
                    loss["read_errors"] += 1
            for identity, state in list(streams.items()):
                if not Path(state["manifest"][identity[1]]).exists():
                    selector.unregister(state["fd"])
                    os.close(state["fd"])
                    del streams[identity]
        for event, _mask in selector.select(timeout=1):
            state: Stream = event.data
            try:
                raw = os.read(state["fd"], MAX_LINE)
            except BlockingIOError:
                continue
            if not raw:
                # Reopen at the next bounded scan; do not spin on writer EOF.
                selector.unregister(state["fd"])
                os.close(state["fd"])
                del streams[state["identity"]]
                continue
            pieces = (state["buffer"] + raw).split(b"\n")
            state["buffer"] = pieces.pop()
            for line in pieces:
                if state["discard"] or len(line) > MAX_LINE:
                    state["discard"] = False
                    loss["dropped_lines"] += 1
                    continue
                manifest = state["manifest"]
                if state["identity"][1] == "metrics":
                    try:
                        metrics = json.loads(line)
                        count = metrics.get("logger", {}).get("missed_log_count", 0)
                        if isinstance(count, int) and count >= 0:
                            loss["native_dropped_logs"] += count
                    except (ValueError, AttributeError):
                        loss["read_errors"] += 1
                    continue
                record: dict[str, str | int] = {
                    key: manifest[key] for key in ("placement_id", "execution_epoch", "generation")
                }
                record.update(
                    event="firecracker.native",
                    event_id=uuid.uuid4().hex,
                    message=line.decode("utf-8", "replace"),
                )
                loss["evicted_files"] += write_record(state["identity"][0], record, budget)
            if len(state["buffer"]) > MAX_LINE:
                state["buffer"] = b""
                state["discard"] = True
        if now - last_report >= 60:
            print(
                json.dumps(
                    {"event": "firecracker.logging_health", **loss, "streams": len(streams)}
                ),
                flush=True,
            )
            print(
                json.dumps(
                    {
                        "event": "metrics.summary",
                        "metrics": {
                            "firecracker_dropped_logs": loss["native_dropped_logs"],
                            "firecracker_evicted_files": loss["evicted_files"],
                        },
                    }
                ),
                flush=True,
            )
            loss = dict.fromkeys(loss, 0)
            last_report = now


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: collector.py MAX_BYTES MAX_STREAMS SERVICE_UID")
    MANIFEST_OWNERS.add(int(sys.argv[3]))
    main(int(sys.argv[1]), int(sys.argv[2]))
