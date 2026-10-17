"""Finite kernel metadata for the disposable Brady watcher's exact VMM target."""

import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from uuid import UUID

PID_MAX = 4_194_304
LILLY_CGROUP = Path("/sys/fs/cgroup/system.slice/lilly.service")


@dataclass(frozen=True)
class WatcherSnapshot:
    vmm_processes: int
    target_watchers: int
    target_pidfds: int


def read_ascii(path: Path, limit: int) -> str:
    assert 1 <= limit <= 32_768
    with path.open("rb") as stream:
        content = stream.read(limit + 1)
    assert len(content) <= limit, "native watcher metadata exceeded its bound"
    return content.decode("ascii")


def process_ids(cgroup: Path) -> tuple[int, ...]:
    lines = read_ascii(cgroup / "cgroup.procs", 32_768).splitlines()
    assert len(lines) <= 4096
    result: list[int] = []
    for line in lines:
        assert 1 <= len(line) <= 7 and line.isdecimal() and line == str(int(line))
        pid = int(line)
        assert 1 <= pid <= PID_MAX
        result.append(pid)
    return tuple(result)


def process_name(pid: int) -> str | None:
    try:
        return read_ascii(Path(f"/proc/{pid}/comm"), 32).strip()
    except (ProcessLookupError, FileNotFoundError):
        return None


def pidfd_targets(pid: int) -> tuple[int, ...]:
    result: list[int] = []
    try:
        for index, entry in enumerate(Path(f"/proc/{pid}/fdinfo").iterdir()):
            assert index < 64, "native watcher descriptor count exceeded its bound"
            try:
                lines = read_ascii(entry, 4096).splitlines()
            except (ProcessLookupError, FileNotFoundError):
                continue
            for line in lines:
                if line.startswith("Pid:"):
                    value = line.removeprefix("Pid:").strip()
                    if value == "-1":
                        continue
                    assert 1 <= len(value) <= 7 and value.isdecimal() and value == str(int(value))
                    target = int(value)
                    assert 1 <= target <= PID_MAX
                    result.append(target)
    except (ProcessLookupError, FileNotFoundError):
        return ()
    return tuple(result)


def snapshot(placement: str) -> WatcherSnapshot:
    """@cc [owner:ghuntley,label:verification;security] brady-watcher-finite-kernel-metadata
    Diagnostics MUST count only Firecracker processes in the exact placement's
    cgroup and Lilly watcher pidfds bound to those processes. Reads MUST remain
    bounded and read-only; arguments, journals, identifiers and file contents
    MUST NOT enter the output. Missing registration MUST NOT fabricate a match.
    """
    assert str(UUID(placement)) == placement
    cgroup = Path(f"/sys/fs/cgroup/lilly.slice/lilly-vm-{placement}.service")
    vmms = {pid for pid in process_ids(cgroup) if process_name(pid) == "firecracker"}
    watchers = 0
    descriptors = 0
    for pid in process_ids(LILLY_CGROUP):
        if process_name(pid) != "lilly-vm-watch":
            continue
        matches = sum(target in vmms for target in pidfd_targets(pid))
        watchers += int(matches > 0)
        descriptors += matches
    return WatcherSnapshot(len(vmms), watchers, descriptors)


def main() -> int:
    try:
        assert len(sys.argv) == 2
        result = snapshot(sys.argv[1])
    except (OSError, ValueError, AssertionError):
        print("Native watcher snapshot unavailable", file=sys.stderr)
        return 1
    print(json.dumps(asdict(result), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
