"""Pin an empty late mount namespace as Nix does after a builder exits."""

import json
import os
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import TypedDict


@dataclass(frozen=True)
class Options:
    hide_proc: bool = False
    history: bool = False
    namespaces: int = 1
    duplicates: int = 0
    close_original: bool = False


class NamespaceRecord(TypedDict):
    child_pid: int
    device: int
    inode: int
    descriptors: list[int]


def options(arguments: list[str]) -> Options:
    flags: set[str] = set()
    counts: dict[str, int] = {}
    index = 0
    while index < len(arguments):
        name = arguments[index]
        if name in flags or name in counts:
            raise SystemExit("Duplicate fixture option")
        if name in {"--hide-proc", "--history", "--close-original"}:
            flags.add(name)
        elif name in {"--namespaces", "--duplicates"}:
            index += 1
            if index >= len(arguments) or arguments[index] not in {"1", "2", "4"}:
                raise SystemExit("Expected bounded fixture count 1, 2 or 4")
            counts[name] = int(arguments[index])
        else:
            raise SystemExit("Unknown namespace fixture option")
        index += 1
    result = Options(
        hide_proc="--hide-proc" in flags,
        history="--history" in flags,
        namespaces=counts.get("--namespaces", 1),
        duplicates=counts.get("--duplicates", 0),
        close_original="--close-original" in flags,
    )
    if (counts or result.close_original) and not result.history:
        raise SystemExit("Generated descriptor options require --history")
    if result.close_original and result.duplicates == 0:
        raise SystemExit("Closing the original requires retained duplicates")
    return result


def retain_namespace(directory: Path, settings: Options) -> NamespaceRecord:
    directory.mkdir(mode=0o700)
    ready = directory / "child-ready"
    empty_proc = directory / "empty-proc"
    empty_proc.mkdir(mode=0o700)
    child = subprocess.Popen(
        [
            "/run/current-system/sw/bin/unshare",
            "--mount",
            "--propagation",
            "private",
            "/bin/sh",
            "-c",
            'set -eu; if [ "$2" = hide-proc ]; then '
            '/run/current-system/sw/bin/mount --bind "$3" /proc; fi; '
            'printf ready > "$1"; exec /run/current-system/sw/bin/sleep 300',
            "/bin/sh",
            str(ready),
            "hide-proc" if settings.hide_proc else "visible-proc",
            str(empty_proc),
        ]
    )
    descriptors: list[int] = []
    try:
        deadline = time.monotonic() + 10
        while not ready.exists():
            if child.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError("Namespace fixture failed before readiness")
            time.sleep(0.02)
        original = os.open(f"/proc/{child.pid}/ns/mnt", os.O_RDONLY)
        descriptors.append(original)
        identity = os.fstat(original)
        for _ in range(settings.duplicates):
            descriptors.append(os.dup(original))
        if settings.close_original:
            os.close(descriptors.pop(0))
        child.terminate()
        child.wait(timeout=5)
        return {
            "child_pid": child.pid,
            "device": identity.st_dev,
            "inode": identity.st_ino,
            "descriptors": descriptors,
        }
    except BaseException:
        for descriptor in descriptors:
            os.close(descriptor)
        raise
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)


def main() -> None:
    """@cc [owner:ghuntley,label:verification] namespace-descriptor-without-inhabitant
    The holder MUST retain its child's mount namespace after reaping that child,
    without entering it or opening guest files. Readiness MUST precede deletion.
    The hidden-proc mode MUST cover /proc only in the child's private namespace.
    Generated mode MUST retain every requested duplicate after optional original
    closure, atomically report exact descriptor identities only after all
    children are reaped, and keep those descriptors unchanged until the holder
    is stopped.
    """
    settings = options(sys.argv[1:])
    with tempfile.TemporaryDirectory(prefix="namespace-holder-", dir="/run") as directory:
        records: list[NamespaceRecord] = []
        try:
            for index in range(settings.namespaces):
                records.append(retain_namespace(Path(directory) / str(index), settings))
            marker = (
                "/run/zfs-fd-history.json"
                if settings.history
                else "/run/zfs-fd-hidden-proc"
                if settings.hide_proc
                else "/run/zfs-fd-held"
            )
            output = (
                json.dumps({"pid": os.getpid(), "namespaces": records}) + "\n"
                if settings.history
                else "ready\n"
            )
            pending = marker + ".pending"
            with os.fdopen(
                os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w"
            ) as file:
                file.write(output)
            os.rename(pending, marker)
            while True:
                time.sleep(60)
        finally:
            for record in records:
                for descriptor in record["descriptors"]:
                    os.close(descriptor)


if __name__ == "__main__":
    main()
