"""Observe the actual VM-owned process tree without reading arguments or console data."""

import json
import sys
import uuid
from pathlib import Path
from typing import TypedDict


class ProcessRow(TypedDict):
    pid: int
    start: int
    executable: str
    device: int
    inode: int


# @cc [owner:ghuntley,label:verification] fleet-vmm-survival-identity
# Survival assertions MUST compare host PIDs and kernel start times of the actual
# Firecracker process tree. A newly started replacement or an active unit alone
# MUST NOT establish uninterrupted execution.
def snapshot(vm: str) -> list[ProcessRow]:
    assert str(uuid.UUID(vm)) == vm
    group = Path(f"/sys/fs/cgroup/lilly.slice/lilly-vm-{vm}.service")
    assert group.is_dir()
    pids = set()
    for file in group.rglob("cgroup.procs"):
        pids.update(int(value) for value in file.read_text().split())
    rows: list[ProcessRow] = []
    for pid in sorted(pids):
        process = Path(f"/proc/{pid}")
        # procfs exposes a magic link: its text is relative to the process's
        # mount namespace (the jailed VMM reports /firecracker). Follow it in
        # the kernel for identity, without resolving that text in the host root.
        executable = (process / "exe").readlink().name
        identity = (process / "exe").stat()
        # Field 22 follows the potentially space-containing parenthesized comm.
        start = int((process / "stat").read_text().rsplit(") ", 1)[1].split()[19])
        rows.append(
            ProcessRow(
                pid=pid,
                start=start,
                executable=executable,
                device=identity.st_dev,
                inode=identity.st_ino,
            )
        )
    assert any("firecracker" in row["executable"] for row in rows)
    return rows


if __name__ == "__main__":
    print(json.dumps(snapshot(sys.argv[1])))
