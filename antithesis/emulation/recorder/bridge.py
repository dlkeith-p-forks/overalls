"""Closed in-guest actuator and independent read-only evidence publisher."""

import hashlib
import json
import os
import pwd
import re
import socket
import sqlite3
import struct
import subprocess
import tempfile
import time
from contextlib import suppress
from pathlib import Path

REQUESTS = Path("/run/overalls-requests")
RESULTS = Path("/run/overalls-results")
OBSERVATION = Path("/run/overalls-observation")
CONTROL = Path("/run/recorder-peer/control.sock")
CHECKPOINT = Path("/var/lib/overalls-request-sdk/state.json")
QUALITY = Path("/var/lib/recorder-peer/marker/quality")
EFFECTS = Path("/var/lib/recorder-peer/effects.log")
ARCHIVE = Path("/archive/state/archive.sqlite")
PRESSURE = Path("/archive/pressure/filled.bin")
ARCHIVE_LIMIT = 64 * 1024 * 1024
TRACE_ACCOUNT = "ktr-" + hashlib.sha256(b"recorder-peer").hexdigest()[:16]
NAME = re.compile(r"[0-9a-f]{32}\.json\Z")
UNITS = {
    "producer": "recorder-peer.service",
    "recorder": "overalls-request-sdk.service",
    "spool": "overalls-trace-recorder.service",
}
ACTIONS = {"start", "stop", "restart", "kill"}


def atomic_bytes(path: Path, body: bytes) -> None:
    """Publish one complete result or witness, never a torn partial file."""
    descriptor, temporary_name = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def result(path: Path, record: dict[str, object]) -> None:
    atomic_bytes(path, (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode())


def producer(command: object) -> dict[str, object]:
    if not isinstance(command, dict) or len(command) > 4:
        return {"status": "invalid"}
    allowed = {
        "hello": {"op"},
        "admit": {"op", "count"},
        "finish": {"op", "id", "outcome"},
        "finish_many": {"op", "ids"},
        "kill_worker": {"op", "id"},
        "trace": {"op", "sequence", "size"},
        "recorder_uncertain_admit": {"op"},
    }
    op = command.get("op")
    if not isinstance(op, str) or op not in allowed:
        return {"status": "invalid"}
    fields = set(command)
    if fields != allowed[op] and not (op == "trace" and fields == allowed[op] | {"lose_ack"}):
        return {"status": "invalid"}
    payload = json.dumps(command, separators=(",", ":")).encode()
    if len(payload) > 4096:
        return {"status": "invalid"}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(12)
            connection.connect(str(CONTROL))
            connection.sendall(struct.pack(">I", len(payload)) + payload)
            size = struct.unpack(">I", receive_exact(connection, 4))[0]
            if size > 4096:
                return {"status": "unavailable"}
            parsed: object = json.loads(receive_exact(connection, size))
        if isinstance(parsed, dict) and isinstance(parsed.get("status"), str):
            return parsed
    except (OSError, ValueError, json.JSONDecodeError, struct.error):
        pass
    return {"status": "unavailable"}


def receive_exact(connection: socket.socket, length: int) -> bytes:
    data = bytearray()
    while len(data) < length:
        part = connection.recv(length - len(data))
        if not part:
            raise OSError("truncated producer reply")
        data.extend(part)
    return bytes(data)


def service(action: object, target: object) -> dict[str, object]:
    if (
        not isinstance(action, str)
        or action not in ACTIONS
        or not isinstance(target, str)
        or target not in UNITS
    ):
        return {"status": "invalid"}
    argv = ["/run/current-system/sw/bin/systemctl"]
    if action == "kill":
        argv += ["kill", "--signal=SIGKILL", "--kill-who=main", UNITS[target]]
    else:
        argv += [action, UNITS[target]]
    completed = subprocess.run(
        argv,
        check=False,
        capture_output=True,
        timeout=20,
    )
    return {"status": "ok" if completed.returncode == 0 else "unavailable"}


def pressure(fill: bool) -> dict[str, object]:
    if not fill:
        PRESSURE.unlink(missing_ok=True)
        return {"status": "ok"}
    if PRESSURE.exists():
        return {"status": "invalid"}
    # This path is on the dedicated 64 MiB ext4 block device, never root.
    filesystem = os.statvfs(PRESSURE.parent)
    total = filesystem.f_blocks * filesystem.f_frsize
    if (
        PRESSURE.parent.stat().st_dev == Path("/").stat().st_dev
        or not 32 * 1024 * 1024 <= total <= ARCHIVE_LIMIT
    ):
        return {"status": "unavailable"}
    descriptor = os.open(PRESSURE, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    exhausted = False
    try:
        block = b"\0" * 65536
        for _ in range(ARCHIVE_LIMIT // len(block)):
            try:
                os.write(descriptor, block)
            except OSError as error:
                if error.errno == 28:
                    exhausted = True
                    break
                raise
        try:
            os.fsync(descriptor)
        except OSError as error:
            if error.errno != 28:
                raise
            exhausted = True
    finally:
        os.close(descriptor)
    return {"status": "ok" if exhausted else "unavailable", "enospc": exhausted}


def replay() -> dict[str, object]:
    if active(UNITS["spool"]):
        return {"status": "unavailable"}
    completed = subprocess.run(
        [
            "/run/current-system/sw/bin/runuser",
            "-u",
            TRACE_ACCOUNT,
            "--",
            "/run/current-system/sw/bin/overalls-trace-spool",
            "/etc/overalls-recorder-trace-config",
            "--replay",
        ],
        check=False,
        capture_output=True,
        timeout=20,
    )
    return {"status": "ok" if completed.returncode == 0 else "unavailable"}


def dispatch(raw: object) -> dict[str, object]:
    """@cc [owner:ghuntley,label:security;verification] recorder-closed-faults
    Only exact service identities and fixed actions may be signaled. A producer
    command MUST pass the BEAM peer's closed parser; no shell or arbitrary path
    from the request can reach the guest actuator.
    """
    if not isinstance(raw, dict) or not all(isinstance(key, str) for key in raw):
        return {"status": "invalid"}
    op = raw.get("op")
    if op == "producer" and set(raw) == {"op", "command"}:
        return producer(raw["command"])
    if op == "service" and set(raw) == {"op", "action", "target"}:
        return service(raw["action"], raw["target"])
    if op == "pressure_fill" and set(raw) == {"op"}:
        return pressure(True)
    if op == "pressure_clear" and set(raw) == {"op"}:
        return pressure(False)
    if op == "replay" and set(raw) == {"op"}:
        return replay()
    if op == "status" and set(raw) == {"op"}:
        return {"status": "ok", "producer": CONTROL.is_socket(), "archive": ARCHIVE.is_file()}
    return {"status": "invalid"}


def copy_file(source: Path, name: str) -> None:
    target = OBSERVATION / name
    try:
        body = source.read_bytes()
        if len(body) > 2 * 1024 * 1024:
            raise ValueError("oversized fixture witness")
    except (OSError, ValueError):
        target.unlink(missing_ok=True)
        return
    atomic_bytes(target, body)


def active(unit: str) -> bool:
    completed = subprocess.run(
        ["/run/current-system/sw/bin/systemctl", "is-active", "--quiet", unit],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=2,
    )
    return completed.returncode == 0


def unit_identity(unit: str, account: str, expected_cgroup: str) -> dict[str, object] | None:
    """@cc [owner:ghuntley,label:security;verification] recorder-kernel-unit-identity
    An identity witness MUST come from the named systemd MainPID with a stable
    kernel start tick, exact expected UID and exact cgroup. Unavailable or
    changed evidence MUST remove the witness instead of preserving old proof.
    """
    completed = subprocess.run(
        [
            "/run/current-system/sw/bin/systemctl",
            "show",
            "--property=MainPID",
            "--value",
            unit,
        ],
        check=False,
        capture_output=True,
        timeout=2,
    )
    if completed.returncode != 0:
        return None
    try:
        pid = int(completed.stdout.strip())
        if pid < 1:
            return None
        process = Path(f"/proc/{pid}")
        before = process.joinpath("stat").read_text(encoding="ascii").rsplit(") ", 1)[1].split()[19]
        cgroup = process.joinpath("cgroup").read_text(encoding="ascii").strip()
        uid = process.stat().st_uid
        after = process.joinpath("stat").read_text(encoding="ascii").rsplit(") ", 1)[1].split()[19]
        expected = pwd.getpwnam(account).pw_uid
        if before != after or uid != expected or cgroup != expected_cgroup:
            return None
        return {"pid": pid, "uid": uid, "start_ticks": int(before), "cgroup": cgroup}
    except (OSError, ValueError, IndexError, KeyError):
        return None


def archive_signature() -> tuple[tuple[int, int], ...] | None:
    if not ARCHIVE.is_file():
        return None
    entries: list[tuple[int, int]] = []
    for path in (ARCHIVE, Path(str(ARCHIVE) + "-wal")):
        if path.exists():
            item = path.stat()
            entries.append((item.st_mtime_ns, item.st_size))
    return tuple(entries)


def publish(
    previous_archive: tuple[tuple[int, int], ...] | None,
) -> tuple[tuple[int, int], ...] | None:
    """Read real private state independently of the BEAM and Rust processes."""
    copy_file(Path("/proc/sys/kernel/random/boot_id"), "boot_id")
    copy_file(CHECKPOINT, "state.json")
    copy_file(QUALITY, "quality")
    copy_file(EFFECTS, "effects.log")
    identity = unit_identity(
        UNITS["producer"], "recorder-peer", "0::/fixture.slice/recorder-peer.service"
    )
    if identity is not None:
        result(OBSERVATION / "identity.json", identity)
    else:
        (OBSERVATION / "identity.json").unlink(missing_ok=True)
    spool_identity = unit_identity(
        UNITS["spool"], TRACE_ACCOUNT, "0::/system.slice/overalls-trace-recorder.service"
    )
    if spool_identity is not None:
        result(OBSERVATION / "spool_identity.json", spool_identity)
    else:
        (OBSERVATION / "spool_identity.json").unlink(missing_ok=True)
    target = OBSERVATION / "archive.sqlite"
    signature = archive_signature()
    if signature is not None and (signature != previous_archive or not target.is_file()):
        descriptor, name = tempfile.mkstemp(prefix=".archive.", dir=OBSERVATION)
        os.close(descriptor)
        temporary = Path(name)
        try:
            with (
                sqlite3.connect(f"file:{ARCHIVE}?mode=ro", uri=True, timeout=1) as source,
                sqlite3.connect(temporary) as destination,
            ):
                source.backup(destination)
            temporary.replace(target)
        except sqlite3.Error:
            target.unlink(missing_ok=True)
            signature = None
        finally:
            temporary.unlink(missing_ok=True)
    elif signature is None:
        target.unlink(missing_ok=True)
    archive = os.statvfs("/archive")
    result(
        OBSERVATION / "filesystem.json",
        {
            "archive_device": Path("/archive").stat().st_dev,
            "root_device": Path("/").stat().st_dev,
            "free_bytes": archive.f_bavail * archive.f_frsize,
            "total_bytes": archive.f_blocks * archive.f_frsize,
        },
    )
    result(
        OBSERVATION / "status.json",
        {
            "sample_ns": time.time_ns(),
            "producer": CONTROL.is_socket() and identity is not None and active(UNITS["producer"]),
            "recorder": CHECKPOINT.is_file()
            and Path("/run/overalls-request-sdk/recorder.sock").is_socket()
            and active(UNITS["recorder"]),
            "spool": Path("/run/overalls-trace-recorder/ingest.sock").is_socket()
            and spool_identity is not None
            and active(UNITS["spool"]),
            "archive": ARCHIVE.is_file() and target.is_file(),
        },
    )
    return signature


def main() -> None:
    REQUESTS.mkdir(parents=True, exist_ok=True)
    RESULTS.mkdir(parents=True, exist_ok=True)
    OBSERVATION.mkdir(parents=True, exist_ok=True)
    previous_archive: tuple[tuple[int, int], ...] | None = None
    while True:
        for path in sorted(REQUESTS.iterdir()):
            if not NAME.fullmatch(path.name) or not path.is_file():
                continue
            destination = RESULTS / path.name
            if destination.exists():
                path.unlink(missing_ok=True)
                continue
            try:
                payload = path.read_bytes()
                if len(payload) > 4096:
                    response: dict[str, object] = {"status": "invalid"}
                else:
                    request: object = json.loads(payload)
                    response = dispatch(request)
            except (OSError, ValueError, json.JSONDecodeError, subprocess.TimeoutExpired):
                response = {"status": "unavailable"}
            result(destination, response)
            path.unlink(missing_ok=True)
        with suppress(OSError, sqlite3.Error):
            previous_archive = publish(previous_archive)
        time.sleep(0.2)


if __name__ == "__main__":
    main()
