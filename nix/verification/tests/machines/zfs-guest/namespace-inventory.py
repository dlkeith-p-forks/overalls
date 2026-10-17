"""Read fixture namespace descriptors and their mounts without changing the holder."""

import json
import os
import sys
from pathlib import Path
from typing import TypedDict
from uuid import UUID


class Descriptor(TypedDict):
    fd: int
    device: int
    inode: int


def positive(value: str) -> int:
    if not value.isascii() or not value.isdecimal() or int(value) <= 0:
        raise SystemExit("Expected positive fixture process or descriptor number")
    return int(value)


def inventory(pid: int) -> list[Descriptor]:
    result: list[Descriptor] = []
    for path in Path(f"/proc/{pid}/fd").iterdir():
        link = os.readlink(path)
        if link.startswith("mnt:[") and link.endswith("]"):
            metadata = path.stat()
            result.append(
                {"fd": positive(path.name), "device": metadata.st_dev, "inode": metadata.st_ino}
            )
    return result


def mounts(pid: int, descriptor: int, vm_id: str) -> list[str]:
    """@cc [owner:ghuntley,label:verification] namespace-fixture-current-mounts
    The observer MUST enter the actual retained descriptor and read its current
    mountinfo through a proc directory pinned before entry. Hidden foreign proc
    MUST NOT replace that inventory with a host snapshot. Emit only mountpoints
    of the exact synthetic guest dataset, never unrelated runtime contents.
    """
    if str(UUID(vm_id)) != vm_id or not vm_id.startswith("dddddddd-dddd-4ddd-8ddd-000000000"):
        raise SystemExit("Expected canonical synthetic guest identity")
    proc = os.open("/proc", os.O_RDONLY | os.O_DIRECTORY)
    namespace = os.open(f"/proc/{pid}/fd/{descriptor}", os.O_RDONLY)
    try:
        os.setns(namespace, os.CLONE_NEWNS)
        with os.fdopen(os.open("self/mountinfo", os.O_RDONLY, dir_fd=proc)) as file:
            lines = file.readlines()
        result: list[str] = []
        for line in lines:
            left, separator, right = line.partition(" - ")
            fields = right.split()
            if not separator or len(fields) < 3:
                raise RuntimeError("Malformed kernel mount inventory")
            if fields[1] == f"tank/lilly/vm-{vm_id}":
                columns = left.split()
                if len(columns) < 6:
                    raise RuntimeError("Malformed kernel mount columns")
                result.append(columns[4])
        return result
    finally:
        os.close(namespace)
        os.close(proc)


def main() -> None:
    arguments = sys.argv[1:]
    if len(arguments) == 2 and arguments[0] == "inventory":
        print(json.dumps(inventory(positive(arguments[1]))))
    elif len(arguments) == 4 and arguments[0] == "mounts":
        print(json.dumps(mounts(positive(arguments[1]), positive(arguments[2]), arguments[3])))
    else:
        raise SystemExit("Expected bounded fixture inventory or mount inspection")


if __name__ == "__main__":
    main()
