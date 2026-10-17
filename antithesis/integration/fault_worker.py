"""Private, bounded, at-most-once crash spool for the inner emulated host."""

import argparse
import contextlib
import fcntl
import json
import os
import re
import stat
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

from crash import ProcessIdentity, crash

UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
MAXIMUM = 9223372036854775807


@dataclass(frozen=True)
class Request:
    request_id: str
    placement_id: str
    execution_epoch: int
    generation: int
    qemu_pid: int
    qemu_start_ticks: int

    @classmethod
    def read(cls, path: Path) -> "Request":
        raw = read_object(path)
        names = {
            "version",
            "operation",
            "request_id",
            "placement_id",
            "execution_epoch",
            "generation",
            "qemu_pid",
            "qemu_start_ticks",
        }
        if (
            set(raw) != names
            or type(raw["version"]) is not int
            or raw["version"] != 1
            or raw["operation"] != "crash_guest"
        ):
            raise ValueError("invalid fault request")
        strings: dict[str, str] = {}
        numbers: dict[str, int] = {}
        for key in ("request_id", "placement_id"):
            value = raw[key]
            if not isinstance(value, str) or not UUID.fullmatch(value):
                raise ValueError("invalid fault identity")
            strings[key] = value
        for key in ("execution_epoch", "generation", "qemu_pid", "qemu_start_ticks"):
            value = raw[key]
            if type(value) is not int or not 1 <= value <= MAXIMUM:
                raise ValueError("invalid fault generation")
            numbers[key] = value
        if numbers["qemu_pid"] <= 1 or path.name != strings["request_id"] + ".json":
            raise ValueError("invalid fault process")
        return cls(
            strings["request_id"],
            strings["placement_id"],
            numbers["execution_epoch"],
            numbers["generation"],
            numbers["qemu_pid"],
            numbers["qemu_start_ticks"],
        )


def read_object(path: Path) -> dict[str, object]:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 4096:
            raise ValueError("invalid fault file")
        raw: object = json.loads(stream.read(4097))
    if not isinstance(raw, dict) or not all(isinstance(key, str) for key in raw):
        raise ValueError("invalid fault object")
    return raw


def sync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def publish(path: Path, value: dict[str, object]) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=".receipt-", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="ascii") as stream:
            json.dump(value, stream, separators=(",", ":"), sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        # The single locked worker is the only receipt writer.
        if path.exists():
            raise ValueError("fault receipt already exists")
        temporary.replace(path)
        sync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def execute(request: Request, state_root: Path, qemu: Path) -> dict[str, object]:
    """@cc [owner:ghuntley,label:security;verification] crash-retained-placement-fence
    A crash MUST match the requested placement, epoch, generation, PID and start
    tick against the private retained launch under the runner's placement lock.
    The executable MUST come from the pinned operator configuration, never the
    request. A refusal MUST NOT signal any process or claim a confirmed exit.
    """
    directory = state_root / request.placement_id
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("unknown fault placement")
    descriptor = os.open(directory / ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        launch = read_object(directory / "launch.json")
        for key in ("placement_id", "execution_epoch", "generation"):
            if launch.get(key) != getattr(request, key):
                raise ValueError("fault boot tuple changed")
        expected = {
            "pid": request.qemu_pid,
            "start_ticks": request.qemu_start_ticks,
            "executable": str(qemu.resolve(strict=True)),
        }
        if launch.get("qemu") != expected:
            raise ValueError("fault process tuple changed")
        proof = crash(ProcessIdentity(request.qemu_pid, request.qemu_start_ticks), qemu)
        return {
            "state": "exited",
            "sent_monotonic_ns": proof["sent_monotonic_ns"],
            "exited_monotonic_ns": proof["exited_monotonic_ns"],
        }


def receipt(request: Request) -> dict[str, object]:
    return {
        "version": 1,
        "request_id": request.request_id,
        "placement_id": request.placement_id,
        "execution_epoch": request.execution_epoch,
        "generation": request.generation,
        "qemu_pid": request.qemu_pid,
        "qemu_start_ticks": request.qemu_start_ticks,
        "state": "unavailable",
        "sent_monotonic_ns": None,
        "exited_monotonic_ns": None,
    }


def process(spool: Path, state_root: Path, qemu: Path, path: Path, recovered: bool) -> None:
    request = Request.read(path)
    result_path = spool / "receipts" / path.name
    if result_path.exists():
        if not recovered:
            path.unlink()
            sync_directory(path.parent)
        return
    result = receipt(request)
    if not recovered:
        claim = spool / "claims" / path.name
        if claim.exists():
            return
        path.replace(claim)
        sync_directory(claim.parent)
        sync_directory(path.parent)
        with contextlib.suppress(OSError, ValueError, IndexError):
            result.update(execute(request, state_root, qemu))
    publish(result_path, result)


def serve(spool: Path, state_root: Path, qemu: Path) -> None:
    """@cc [owner:ghuntley,label:recovery] crash-spool-no-uncertain-repeat
    The worker MUST durably claim a request before signaling. After restart an
    unreceipted claim MUST become unavailable, never a repeated signal or an
    inferred successful exit. At most one worker may consume a spool.
    """
    for name in ("requests", "claims", "receipts"):
        (spool / name).mkdir(mode=0o700, parents=True, exist_ok=True)
    with (spool / "worker.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for path in sorted((spool / "claims").glob("*.json")):
            process(spool, state_root, qemu, path, recovered=True)
        while True:
            for path in sorted((spool / "requests").glob("*.json"))[:64]:
                try:
                    process(spool, state_root, qemu, path, recovered=False)
                except (OSError, ValueError):
                    continue
            time.sleep(0.25)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spool", type=Path, required=True)
    parser.add_argument("--state-root", type=Path, required=True)
    parser.add_argument("--qemu", type=Path, required=True)
    args = parser.parse_args()
    for path in (args.spool, args.state_root, args.qemu):
        if not path.is_absolute() or ".." in path.parts:
            raise ValueError("invalid worker path")
    serve(args.spool, args.state_root, args.qemu)


if __name__ == "__main__":
    main()
