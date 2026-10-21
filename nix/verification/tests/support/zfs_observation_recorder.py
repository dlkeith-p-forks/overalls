"""Private bounded observation recorder for the disposable clone-cancellation fixture."""

import base64
import ctypes
import fcntl
import json
import os
import selectors
import signal
import stat
import subprocess
import sys
import time
import uuid
from contextlib import suppress
from functools import partial
from pathlib import Path
from types import FrameType
from typing import Literal, NotRequired, TypedDict

ROOT = Path("/run/clone-zfs-observations")
SAMPLE_COUNT = 128
STREAM_LIMIT = 65536
PROPERTIES = (
    "name,type,guid,mountpoint,mounted,compression,reservation,refreservation,dedup,sync,"
    "origin,used,available,logicalused,quota,compressratio,usedbychildren,usedbydataset,"
    "usedbyrefreservation,usedbysnapshots,refquota,readonly,canmount"
)
ARGUMENTS = ["list", "-Hp", "-t", "all", "-o", PROPERTIES, "-r", "zroot/lilly"]


class SnapshotBinding(TypedDict):
    dataset_guid: str
    snapshot_guid: str


class ReadinessContext(TypedDict):
    state: Literal["present", "missing", "invalid", "changed"]
    placement_id: NotRequired[str]
    snapshots: NotRequired[dict[str, SnapshotBinding]]


class ObservationSample(TypedDict):
    started_ns: int
    finished_ns: int
    returncode: int
    stdout_base64: str
    stderr_base64: str
    stdout_bytes: int
    stderr_bytes: int
    stdout_truncated: bool
    stderr_truncated: bool
    readiness: ReadinessContext
    sequence: NotRequired[int]


class ForwardSignal(BaseException):
    def __init__(self, number: int) -> None:
        self.number = number
        super().__init__()


def interrupted(number: int, _frame: FrameType | None) -> None:
    raise ForwardSignal(number)


def child_custody(parent: int) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] observation-child-parent-death
    The added child MUST retain inherited lock descriptors and its existing
    process group. It MUST die when its wrapper dies, including parent death
    before fencing is installed; no unfenced child may exec the native utility.
    """
    # Linux clears PDEATHSIG across fork. Restore the hostd child's fence
    # with an explicit native signature, then close the parent-death race.
    library = ctypes.CDLL(None, use_errno=True)
    prctl = library.prctl
    prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
    prctl.restype = ctypes.c_int
    result: object = prctl(1, signal.SIGKILL, 0, 0, 0)
    if result != 0 or os.getppid() != parent:
        os._exit(127)


def canonical_uuid(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)) == value
    except ValueError:
        return False


def object_fields(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("expected object")
    fields: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ValueError("expected string key")
        fields[key] = item
    return fields


def read_context(root: Path) -> ReadinessContext:
    """@cc [owner:ghuntley,label:verification;security] observation-context-exact-owner
    Samples MUST distinguish absent/invalid/changing context from readiness.
    Context MUST match the unique inherited owner.lock device/inode, be private and at most
    4096 bytes, and contain only validated UUID and at most eight GUID bindings.
    """
    try:
        owners: set[tuple[int, int]] = set()
        for descriptor in Path("/proc/self/fd").iterdir():
            try:
                if Path(os.readlink(descriptor)).name != "owner.lock":
                    continue
                metadata = os.fstat(int(descriptor.name))
                if stat.S_ISREG(metadata.st_mode):
                    owners.add((metadata.st_dev, metadata.st_ino))
            except (OSError, ValueError):
                continue
        if not owners:
            return {"state": "missing"}
        if len(owners) != 1:
            return {"state": "invalid"}
        device, inode = owners.pop()
        path = root / f"context-{device}-{inode}.json"
        metadata = path.lstat()
        if metadata.st_mode & 0o777 != 0o600 or not path.is_file() or metadata.st_nlink != 1:
            return {"state": "invalid"}
        with path.open("rb") as source:
            raw = source.read(4097)
        if len(raw) > 4096:
            return {"state": "invalid"}
        parsed: object = json.loads(raw)
        value = object_fields(parsed)
        if set(value) != {"placement_id", "snapshots"}:
            return {"state": "invalid"}
        placement = value["placement_id"]
        snapshots = value["snapshots"]
        if not isinstance(placement, str) or not canonical_uuid(placement):
            return {"state": "invalid"}
        snapshot_fields = object_fields(snapshots)
        if len(snapshot_fields) > 8:
            return {"state": "invalid"}
        bindings: dict[str, SnapshotBinding] = {}
        for name, raw_entry in snapshot_fields.items():
            if not name.startswith("zroot/lilly/vm-"):
                return {"state": "invalid"}
            parts = name.removeprefix("zroot/lilly/vm-").split("@")
            if (
                len(parts) != 2
                or not canonical_uuid(parts[0])
                or parts[1] not in ("lilly-b", "lilly-backup")
            ):
                return {"state": "invalid"}
            entry = object_fields(raw_entry)
            if set(entry) != {"dataset_guid", "snapshot_guid"}:
                return {"state": "invalid"}
            dataset, snapshot = entry["dataset_guid"], entry["snapshot_guid"]
            if not isinstance(dataset, str) or not isinstance(snapshot, str):
                return {"state": "invalid"}
            if not all(
                guid.isascii()
                and guid.isdecimal()
                and not guid.startswith("0")
                and len(guid) <= 20
                and int(guid) <= 18446744073709551615
                for guid in (dataset, snapshot)
            ):
                return {"state": "invalid"}
            bindings[name] = {"dataset_guid": dataset, "snapshot_guid": snapshot}
        return {"state": "present", "placement_id": placement, "snapshots": bindings}
    except FileNotFoundError:
        return {"state": "missing"}
    except (OSError, ValueError):
        return {"state": "invalid"}


def save_sample(root: Path, sample: ObservationSample) -> None:
    """@cc [owner:ghuntley,label:verification;security] zfs-observation-private-bounds
    The recorder MUST retain at most 128 samples with at most 64 KiB per output
    stream, mark truncation, and use private files below the armed fixture root.
    Persistence failure or lock contention MUST NOT change the native command's
    output/status or wait for another recorder. One bounded staging file is allowed.
    """
    try:
        with (root / "lock").open("a") as lock:
            os.fchmod(lock.fileno(), 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            # Disarming before collection prevents late commands from replacing
            # the captured ring after the collector has acquired this same lock.
            if not (root / "armed").is_file():
                return
            counter = root / "next"
            sequence = int(counter.read_text()) if counter.exists() else 0
            sample["sequence"] = sequence
            temporary = root / "sample.tmp"
            with temporary.open("w") as output:
                os.fchmod(output.fileno(), 0o600)
                json.dump(sample, output)
            temporary.replace(root / f"sample-{sequence % SAMPLE_COUNT:03d}.json")
            with counter.open("w") as output:
                os.fchmod(output.fileno(), 0o600)
                output.write(str(sequence + 1))
    except (OSError, ValueError):
        return


def forward(executable: str, arguments: list[str], root: Path = ROOT) -> int:
    """@cc [owner:ghuntley,label:verification;security] zfs-observation-exact-read-only-tee
    Only the armed exact recursive public-property argv may be recorded. Every
    command MUST run once using the selected host ZFS binary with unchanged argv,
    inherited stdin/environment and no new session/process group. Forward stdout,
    stderr and status unchanged, including bytes beyond recording limits. All
    other commands MUST exec directly without recording arguments or output.
    """
    if arguments != ARGUMENTS or not (root / "armed").is_file():
        os.execv(executable, [executable, *arguments])

    started = time.time_ns()
    context: ReadinessContext = read_context(root)
    captured = {"stdout": bytearray(), "stderr": bytearray()}
    sizes = {"stdout": 0, "stderr": 0}
    child = subprocess.Popen(
        [executable, *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        close_fds=False,
        preexec_fn=partial(child_custody, os.getpid()),
    )
    previous = {
        number: signal.signal(number, interrupted)
        for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
    }
    completed = False
    try:
        assert child.stdout is not None and child.stderr is not None
        streams = {child.stdout.fileno(): "stdout", child.stderr.fileno(): "stderr"}
        outputs = {"stdout": sys.stdout.fileno(), "stderr": sys.stderr.fileno()}
        with selectors.DefaultSelector() as selector:
            for descriptor in streams:
                selector.register(descriptor, selectors.EVENT_READ)
            while selector.get_map():
                for key, _events in selector.select():
                    name = streams[key.fd]
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fd)
                        continue
                    sizes[name] += len(chunk)
                    captured[name].extend(chunk[: max(0, STREAM_LIMIT - len(captured[name]))])
                    pending = memoryview(chunk)
                    while pending:
                        pending = pending[os.write(outputs[name], pending) :]
        status = child.wait()
        completed = True
    except ForwardSignal as interruption:
        status = -interruption.number
    except BrokenPipeError:
        status = -signal.SIGPIPE
    finally:
        # Avoid Popen.__exit__'s unbounded wait on a broken consumer or signal.
        # The command stays in hostd's custody throughout this cleanup.
        for number in previous:
            signal.signal(number, signal.SIG_IGN)
        if child.poll() is None:
            child.kill()
            # An uninterruptible native task retains the inherited lock FD;
            # hostd also kills the command's cgroup when this wrapper returns.
            with suppress(subprocess.TimeoutExpired):
                child.wait(timeout=1)
        if child.stdout is not None:
            child.stdout.close()
        if child.stderr is not None:
            child.stderr.close()
        for number, handler in previous.items():
            signal.signal(number, handler)
    if not completed:
        return status
    if context != read_context(root):
        context = {"state": "changed"}
    sample: ObservationSample = {
        "started_ns": started,
        "finished_ns": time.time_ns(),
        "returncode": status,
        "stdout_base64": base64.b64encode(captured["stdout"]).decode("ascii"),
        "stderr_base64": base64.b64encode(captured["stderr"]).decode("ascii"),
        "stdout_bytes": sizes["stdout"],
        "stderr_bytes": sizes["stderr"],
        "stdout_truncated": sizes["stdout"] > STREAM_LIMIT,
        "stderr_truncated": sizes["stderr"] > STREAM_LIMIT,
        "readiness": context,
    }
    save_sample(root, sample)
    return status


def finish(status: int) -> None:
    if status < 0:
        number = -status
        if number not in (signal.SIGKILL, signal.SIGSTOP):
            signal.signal(number, signal.SIG_DFL)
        os.kill(os.getpid(), number)
    sys.exit(status)


if __name__ == "__main__":
    finish(forward(sys.argv[1], sys.argv[2:]))
