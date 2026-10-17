"""Private durable state and bounded, payload-free subprocess failures."""

import json
import os
import selectors
import signal
import stat
import subprocess
import tempfile
import time
from collections.abc import Callable, Mapping, Sequence
from contextlib import suppress
from pathlib import Path

from schema import JSON, Failure, json_value


class BackupError(Exception):
    def __init__(self, stage: Failure) -> None:
        super().__init__(stage)
        self.stage = stage


def private_directory(path: str | Path) -> Path:
    path = Path(path).absolute()
    if ".." in path.parts:
        raise BackupError("configuration")
    for ancestor in reversed(path.parents):
        ancestor.mkdir(mode=0o700, exist_ok=True)
        observed = ancestor.lstat()
        if (
            not stat.S_ISDIR(observed.st_mode)
            # The namespace's root is the trust anchor. Its owner may be
            # unmapped in a user namespace; descendants must be trusted.
            or (ancestor != Path("/") and observed.st_uid not in (0, os.geteuid()))
            or (
                observed.st_mode & 0o022
                and not (observed.st_uid == 0 and observed.st_mode & stat.S_ISVTX)
            )
        ):
            raise BackupError("configuration")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    observed = path.lstat()
    if (
        not stat.S_ISDIR(observed.st_mode)
        or observed.st_uid != os.geteuid()
        or observed.st_mode & 0o077
    ):
        raise BackupError("configuration")
    return path


def atomic_json(path: str | Path, value: object) -> None:
    """@cc [owner:ghuntley,label:recovery] backup-state-durable-publication
    State publication MUST fsync contents and parent directory and atomically
    replace the destination; interrupted writes MUST NOT publish partial JSON.
    """
    path = Path(path)
    parent = private_directory(path.parent)
    descriptor, temporary = tempfile.mkstemp(prefix=".pending-", dir=parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(json_value(value), stream, separators=(",", ":"), allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        Path(temporary).unlink(missing_ok=True)


def read_json(path: str | Path, maximum: int = 4 * 1024 * 1024) -> JSON:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        observed = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(observed.st_mode)
            or observed.st_uid != os.geteuid()
            or observed.st_mode & 0o077
            or observed.st_nlink != 1
        ):
            raise BackupError("configuration")
        data = stream.read(maximum + 1)
        if len(data) > maximum:
            raise BackupError("configuration")
        return json_value(json.loads(data))


def group_has_live_members(identity: int) -> bool:
    """@cc [owner:ghuntley,label:recovery] backup-reader-group-death-proof
    While the unreaped group leader pins identity, cleanup MUST consider every
    visible non-zombie thread with that process-group identity a live reader.
    Disappearing proc entries are absent; unavailable inventory MUST fail closed.
    """
    for entry in Path("/proc").iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            tasks = list((entry / "task").iterdir())
        except FileNotFoundError:
            continue
        for task in tasks:
            try:
                fields = (task / "stat").read_text().rsplit(") ", 1)[1].split()
            except FileNotFoundError:
                continue
            if int(fields[2]) == identity and fields[0] != "Z":
                return True
    return False


def run(
    arguments: Sequence[str | Path],
    *,
    stage: Failure,
    environment: Mapping[str, str] | None = None,
    timeout: float = 3600,
    maximum: int = 4 * 1024 * 1024,
    guard: Callable[[], None] | None = None,
) -> bytes:
    """@cc [owner:ghuntley,label:capacity;recovery] backup-command-bounded-readers
    Output and elapsed time MUST be bounded while the child runs. Timeout,
    cancellation or a failing capacity guard MUST stop and reap backup readers
    before control returns to snapshot cleanup. Raw stderr MUST not be logged.
    """
    try:
        with subprocess.Popen(
            arguments,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        ) as process:
            assert process.stdout is not None
            deadline, next_guard = time.monotonic() + timeout, time.monotonic()
            body = bytearray()
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                try:
                    while True:
                        now = time.monotonic()
                        if guard is not None and now >= next_guard:
                            guard()
                            next_guard = time.monotonic() + 5
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise BackupError(stage)
                        if not selector.select(min(remaining, 5)):
                            continue
                        chunk = os.read(
                            process.stdout.fileno(), min(65536, maximum + 1 - len(body))
                        )
                        if not chunk:
                            # WNOWAIT observes exit without releasing the PID/PGID
                            # identity before finally retires all group readers.
                            while True:
                                exited = os.waitid(
                                    os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT
                                )
                                if exited is not None:
                                    if exited.si_code != os.CLD_EXITED or exited.si_status != 0:
                                        raise BackupError(stage)
                                    return bytes(body)
                                if time.monotonic() >= deadline:
                                    raise BackupError(stage)
                                time.sleep(0.001)
                        body.extend(chunk)
                        if len(body) > maximum:
                            raise BackupError(stage)
                finally:
                    # Keep the unreaped leader pinning the PGID until every
                    # member has stopped; zombies hold no reader descriptors.
                    with suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGKILL)
                    empty_scans = 0
                    while True:
                        # A descendant may fork as the first group signal is
                        # delivered. The pinned PGID permits repeated retirement.
                        with suppress(ProcessLookupError):
                            os.killpg(process.pid, signal.SIGKILL)
                        try:
                            if group_has_live_members(process.pid):
                                empty_scans = 0
                            else:
                                empty_scans += 1
                                if empty_scans == 2:
                                    break
                        except OSError:
                            # Unavailable inspection is not death proof. Keep the
                            # leader pinned and withhold snapshot cleanup.
                            empty_scans = 0
                        time.sleep(0.001)
                    process.wait()
    except (OSError, subprocess.SubprocessError):
        raise BackupError(stage) from None
