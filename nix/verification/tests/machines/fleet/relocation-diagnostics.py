"""Read-only, bounded local evidence for a stalled fleet relocation."""

import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Literal, TypedDict

ProcessState = Literal["R", "S", "D", "Z", "T", "t", "I", "X"]


class ProcessStat(TypedDict):
    parent: int
    state: ProcessState
    kernel_thread: bool


def process_stat(path: Path) -> ProcessStat | None:
    """@cc [owner:ghuntley,label:verification;security] kernel-thread-from-native-flags
    Read at most 4096 bytes of native stat. Only a validated PF_KTHREAD flag
    MAY identify a kernel thread; missing, malformed or oversized state MUST
    remain unknown. Raw stat contents and process names MUST stay private.
    """
    states: dict[bytes, ProcessState] = {
        value.encode("ascii"): value for value in ("R", "S", "D", "Z", "T", "t", "I", "X")
    }
    try:
        with path.open("rb") as stream:
            record = stream.read(4097)
        if len(record) > 4096:
            return None
        fields = record.rsplit(b")", 1)[1].split()
        state = states.get(fields[0])
        parent = int(fields[1])
        flags = int(fields[6])
        if state is None or parent < 0 or not 0 <= flags <= 18_446_744_073_709_551_615:
            return None
        return {"parent": parent, "state": state, "kernel_thread": bool(flags & (1 << 21))}
    except (OSError, ValueError, IndexError):
        return None


def pool_lock_owner(lock_file: Path, proc: Path = Path("/proc")) -> dict[str, object]:
    """@cc [owner:ghuntley,label:verification;security] bounded-pool-lock-owner
    Read only the selected lock inode and at most 1 MiB of the kernel lock table.
    Report a numeric exclusive flock owner or explicit unknown/unheld state;
    never emit paths, raw kernel records or exception text. Missing, malformed,
    oversized or racing observations MUST NOT establish that a lock is free.
    This point-in-time observation MUST NOT authorize mutation or remove a lock.
    """
    unknown = {"state": "unknown"}
    try:
        before = lock_file.stat()
        identity = (os.major(before.st_dev), os.minor(before.st_dev), before.st_ino)
        with (proc / "locks").open("rb") as stream:
            records = stream.read(1_048_577)
        if len(records) > 1_048_576:
            return unknown
        owners = set()
        for line in records.decode("ascii").splitlines():
            fields = line.split()
            waiting = len(fields) > 1 and fields[1] == "->"
            if waiting:
                fields.pop(1)
            if len(fields) != 8:
                return unknown
            major, minor, inode = fields[5].split(":")
            record_identity = (int(major, 16), int(minor, 16), int(inode))
            owner = int(fields[4])
            if waiting:
                continue  # Waiting requests are not holders.
            if record_identity == identity:
                if fields[1:4] != ["FLOCK", "ADVISORY", "WRITE"]:
                    return unknown
                if owner <= 0:
                    return unknown
                owners.add(owner)
        after = lock_file.stat()
        if (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino):
            return unknown
        if not owners:
            return {"state": "unheld"}
        if len(owners) == 1:
            return {"state": "held", "pid": owners.pop()}
        return unknown
    except (OSError, ValueError, UnicodeError):
        return unknown


def transfer_processes(proc: Path = Path("/proc")) -> dict[str, object]:
    """@cc [owner:ghuntley,label:verification;security] bounded-transfer-process-evidence
    Read-only observations MUST scan at most 4096 process entries for two seconds
    and emit at most 64 selected processes. Output MUST contain only numeric
    process relationships and closed executable, state, wait and descriptor enums.
    Never read argv, environment, descriptor contents or expose paths/kernel text.
    Missing/racing observations MUST remain unknown or mark the scan incomplete.
    Validated kernel threads MAY be excluded before executable lookup because
    they cannot be the userspace transfer helper or its ZFS child. An unknown
    stat or executable for a userspace process MUST keep the scan incomplete.
    Numeric input byte counts may identify an active native stream for fault
    injection only. These observations MUST NOT establish transfer completion or authority.
    """
    executables = {
        "lilly-transfer-stream",
        "lilly-source-export",
        "lilly-export-channel",
        "lilly-hostd",
        "zfs",
        "ssh",
        "beam.smp",
    }
    waits = {
        "pipe_read": "pipe_read",
        "pipe_write": "pipe_write",
        "do_wait": "child_wait",
        "do_poll": "poll",
        "poll_schedule_timeout.constprop.0": "poll",
        "ep_poll": "poll",
        "ep_poll.constprop.0": "poll",
        "unix_stream_read_generic": "socket_read",
        "sock_recvmsg": "socket_read",
        "wait_woken": "wait",
        "futex_wait_queue": "futex",
        "futex_wait_queue_me": "futex",
        "io_schedule": "io",
        "0": "running_or_unavailable",
    }
    result = {"complete": True, "entries": []}
    deadline = time.monotonic() + 2

    def descriptor(path: Path) -> str:
        try:
            target = os.readlink(path)
            if target.startswith("pipe:["):
                return "pipe"
            if target.startswith("socket:["):
                return "socket"
            return "other"
        except OSError:
            return "unknown"

    try:
        with os.scandir(proc) as entries:
            for index, entry in enumerate(entries):
                if index >= 4096 or time.monotonic() >= deadline or len(result["entries"]) >= 64:
                    result["complete"] = False
                    break
                if not entry.name.isascii() or not entry.name.isdecimal():
                    continue
                path = proc / entry.name
                try:
                    stat = process_stat(path / "stat")
                    if stat is None:
                        result["complete"] = False
                        continue
                    if stat["kernel_thread"]:
                        continue
                    executable = Path(os.readlink(path / "exe")).name
                    if executable not in executables:
                        continue
                    try:
                        with (path / "wchan").open() as stream:
                            wait = waits.get(stream.read(128).strip(), "other")
                    except OSError:
                        wait = "unknown"
                    read_bytes: int | str = "unknown"
                    if executable == "zfs":
                        try:
                            with (path / "io").open() as stream:
                                counters = stream.read(4096).splitlines()
                            inputs = [
                                line.removeprefix("rchar: ")
                                for line in counters
                                if line.startswith("rchar: ")
                            ]
                            if len(inputs) == 1 and inputs[0].isdecimal():
                                count = int(inputs[0])
                                if 0 <= count <= 9_223_372_036_854_775_807:
                                    read_bytes = count
                        except OSError:
                            pass
                    result["entries"].append(
                        {
                            "pid": int(entry.name),
                            "parent": stat["parent"],
                            "executable": executable,
                            "state": stat["state"],
                            "wait": wait,
                            "stdin": descriptor(path / "fd" / "0"),
                            "stdout": descriptor(path / "fd" / "1"),
                            "read_bytes": read_bytes,
                        }
                    )
                except (OSError, ValueError, IndexError):
                    result["complete"] = False
    except OSError:
        result["complete"] = False
    return result


def observe(placement: str) -> None:
    """@cc [owner:ghuntley,label:verification;security] relocation-local-diagnostics
    Observations MUST be read-only and restricted to validated placement paths,
    fixed state enums and existence booleans, plus bounded transfer process state
    and the selected pool lock's numeric owner.
    Never emit journal contents, native
    resume tokens, credentials, exception text or guest disk/console contents.
    Unknown or unreadable evidence MUST remain explicitly unknown.
    """
    assert str(uuid.UUID(placement)) == placement
    pool = Path("/var/lib/lilly/pool")
    metadata = pool / ".lilly-zfs"
    execution = Path("/var/lib/lilly/vms") / placement

    def field(path: Path, key: str, allowed: list[str]) -> str:
        try:
            with path.open() as stream:
                value = json.loads(stream.read(65537))[key]
            return value if value in allowed else "unknown"
        except (OSError, ValueError, KeyError, TypeError):
            return "unknown"

    def exists(path: Path) -> bool | str:
        try:
            path.lstat()
            return True
        except FileNotFoundError:
            return False
        except OSError:
            return "unknown"

    journal = metadata / "imports" / placement / "import.json"
    claim = metadata / "active" / placement / "claim.json"
    result = {
        "pool_lock": pool_lock_owner(pool / ".lilly-storage" / "owner.lock"),
        "transfer_processes": transfer_processes(),
        "import_phase": field(journal, "phase", ["active", "retiring", "retired"]),
        "stream_state": field(journal, "stream_state", ["receiving", "received"]),
        "disk_claim": field(
            claim, "state", ["importing", "import-pruned", "import-publishing", "ready"]
        ),
    }
    for name in ["vm.json", "intent.bin", "deleted.json"]:
        result[name] = exists(execution / name)
    for name in ["disk.json", "disk-ready.json"]:
        result[name] = exists(claim.parent / name)

    try:
        native = subprocess.run(
            [
                "zfs",
                "get",
                "-H",
                "-o",
                "value",
                "receive_resume_token",
                "zroot/lilly/vm-" + placement,
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        # The value never leaves this process, even in a failure message.
        result["resume_present"] = (
            native.stdout.strip() not in ["", "-"] if native.returncode == 0 else "unknown"
        )
    except (OSError, subprocess.TimeoutExpired):
        result["resume_present"] = "unknown"

    try:
        status = subprocess.run(
            [
                "systemctl",
                "show",
                "--property=ActiveState",
                "--value",
                "lilly-vm-" + placement + ".service",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        value = status.stdout.strip()
        result["unit"] = (
            value
            if status.returncode == 0
            and value in ["active", "inactive", "activating", "deactivating", "failed"]
            else "unknown"
        )
    except (OSError, subprocess.TimeoutExpired):
        result["unit"] = "unknown"
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    observe(sys.argv[1])
