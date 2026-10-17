"""Disposable guest effect barrier and exact process interruption fixture."""

import json
import os
import select
import signal
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Literal

ROOT = Path("/root/executor-loss")
SERVICE = "overalls-agent-executor.service"
Role = Literal["supervisor", "executor", "child"]


@dataclass(frozen=True)
class Identity:
    pid: int
    start: int
    parent: int
    role: Role


def systemctl(*arguments: str) -> str:
    return subprocess.check_output(
        ["systemctl", *arguments], stderr=subprocess.DEVNULL, text=True, timeout=10
    ).strip()


def cgroup() -> Path:
    value = systemctl("show", "--property=ControlGroup", "--value", SERVICE)
    assert value.startswith("/system.slice/") and ".." not in value
    path = Path("/sys/fs/cgroup") / value.removeprefix("/")
    assert (path / "cgroup.freeze").is_file(), "unified cgroup freezer unavailable"
    own_groups = [
        line.removeprefix("0::")
        for line in Path("/proc/self/cgroup").read_text().splitlines()
        if line.startswith("0::")
    ]
    assert len(own_groups) == 1
    assert own_groups[0] != value and not own_groups[0].startswith(value + "/")
    return path


def identity(pid: int) -> Identity:
    stat = Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()
    arguments = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
    role: Role = "child"
    if len(arguments) >= 2 and arguments[1] == b"agent-supervisor":
        role = "supervisor"
    elif len(arguments) >= 2 and arguments[1] == b"agent-executor":
        role = "executor"
    return Identity(pid, int(stat[19]), int(stat[1]), role)


def same_process(item: Identity) -> bool:
    try:
        return identity(item.pid).start == item.start
    except FileNotFoundError:
        return False


def read_identities() -> list[Identity]:
    value: object = json.loads((ROOT / "frozen.json").read_text())
    assert isinstance(value, list)
    result: list[Identity] = []
    for item in value:
        assert isinstance(item, dict)
        fields: dict[str, object] = {}
        for key, field in item.items():
            assert isinstance(key, str)
            fields[key] = field
        assert set(fields) == {"pid", "start", "parent", "role"}
        pid, start, parent, role = fields["pid"], fields["start"], fields["parent"], fields["role"]
        assert isinstance(pid, int) and pid > 1
        assert isinstance(start, int) and start > 0
        assert isinstance(parent, int) and parent > 0
        assert role in ("supervisor", "executor", "child")
        if role == "supervisor":
            result.append(Identity(pid, start, parent, "supervisor"))
        elif role == "executor":
            result.append(Identity(pid, start, parent, "executor"))
        else:
            result.append(Identity(pid, start, parent, "child"))
    assert len({item.pid for item in result}) == len(result)
    return result


def effect(retry: bool) -> None:
    """@cc [owner:ghuntley,label:verification] executor-native-effect-counter
    Each real guest tool invocation MUST append and fsync exactly one effect.
    The first invocation then blocks on the independent observer; only an
    explicitly new retry command may add the second effect. No result or
    registration receipt is written by this fixture.
    """
    with (ROOT / "effects").open("ab", buffering=0) as stream:
        stream.write(b"effect\n")
        os.fsync(stream.fileno())
    if not retry:
        with (ROOT / "notice").open("wb", buffering=0) as notice:
            notice.write(b"1")
        # This process belongs to the real executor cgroup and is killed in the
        # observed fault. The production timeout remains twenty seconds.
        signal.pause()
        raise AssertionError("effect barrier resumed without targeted fault")
    print("explicit retry effect complete")


def emergency_cleanup() -> None:
    """@cc [owner:ghuntley,label:verification;recovery] observer-independent-cleanup
    Both ordinary exceptions and systemd ExecStopPost MUST invoke this bounded
    kill/thaw path. Successful fault completion MUST make it a no-op; a completed
    emergency cleanup MUST NOT kill a subsequently restarted service again.
    """
    if (ROOT / "fault.done").exists() or (ROOT / "cleanup.done").exists():
        return
    (ROOT / "observer.failed").touch()
    try:
        systemctl("kill", "--signal=SIGKILL", "--kill-whom=all", SERVICE)
    finally:
        systemctl("thaw", SERVICE)
    (ROOT / "cleanup.done").touch()


def observe() -> None:
    """@cc [owner:ghuntley,label:verification;recovery] executor-independent-freezer
    The observer MUST run outside the executor cgroup, freeze only after a real
    fsynced effect, and retain exact process identities. Unsupported freezing,
    a deadline, or an unexpected process tree MUST fail closed. Emergency
    cleanup MUST kill the fixture cgroup and thaw it, with failure recorded.
    """
    path = cgroup()
    descriptor = os.open(ROOT / "notice", os.O_RDWR | os.O_NONBLOCK)
    succeeded = False
    try:
        (ROOT / "observer.ready").touch()
        readable, _, _ = select.select([descriptor], [], [], 180)
        assert readable and os.read(descriptor, 1) == b"1", "effect deadline"
        assert (ROOT / "effects").read_bytes() == b"effect\n"
        systemctl("freeze", SERVICE)
        assert "frozen 1" in (path / "cgroup.events").read_text()
        identities = [identity(int(pid)) for pid in (path / "cgroup.procs").read_text().split()]
        supervisors = [item for item in identities if item.role == "supervisor"]
        executors = [item for item in identities if item.role == "executor"]
        assert len(supervisors) == len(executors) == 1
        assert executors[0].parent == supervisors[0].pid
        assert os.path.samefile(f"/proc/{executors[0].pid}/exe", "/var/lib/overalls/bin/overalls")
        assert systemctl("show", "--property=MainPID", "--value", SERVICE) == str(
            supervisors[0].pid
        )
        # Every remaining process must descend from the actual executor; reject
        # concurrent updater or unrelated service work before selecting targets.
        parents = {item.pid: item.parent for item in identities}
        for item in identities:
            ancestor = item.pid
            seen: set[int] = set()
            while ancestor not in (supervisors[0].pid, executors[0].pid):
                assert ancestor not in seen and ancestor in parents
                seen.add(ancestor)
                ancestor = parents[ancestor]
            if item.role == "child":
                assert ancestor == executors[0].pid
        assert any(item.role == "child" for item in identities)
        (ROOT / "frozen.json").write_text(json.dumps([asdict(item) for item in identities]))
        deadline = time.monotonic() + 120
        while not (ROOT / "fault.done").exists():
            assert time.monotonic() < deadline, "fault authorization deadline"
            time.sleep(0.1)
        succeeded = True
    finally:
        os.close(descriptor)
        if not succeeded:
            emergency_cleanup()


def fault() -> None:
    """@cc [owner:ghuntley,label:verification;recovery] executor-targeted-loss
    Fault injection MUST require the frozen process identities captured after
    the effect. Kill the executor and its tool descendants, preserve the
    supervisor, and prove every killed identity absent after thaw. This is a
    scoped process fault with explicit child cleanup, not a natural timeout.
    """
    assert not (ROOT / "observer.failed").exists()
    path = cgroup()
    assert "frozen 1" in (path / "cgroup.events").read_text()
    identities = read_identities()
    supervisor = next(item for item in identities if item.role == "supervisor")
    victims = [item for item in identities if item.role != "supervisor"]
    assert all(same_process(item) for item in identities)
    for item in victims:
        os.kill(item.pid, signal.SIGKILL)
    systemctl("thaw", SERVICE)
    deadline = time.monotonic() + 20
    while any(same_process(item) for item in victims):
        assert time.monotonic() < deadline, "child cleanup deadline"
        time.sleep(0.1)
    assert same_process(supervisor)
    assert (ROOT / "effects").read_bytes() == b"effect\n"
    (ROOT / "fault.done").touch()


def main() -> None:
    os.umask(0o077)
    assert len(sys.argv) == 2
    action = sys.argv[1]
    if action == "prepare":
        ROOT.mkdir(mode=0o700)
        os.mkfifo(ROOT / "notice", mode=0o600)
        cgroup()
        systemctl("start", "--no-block", "fleet-executor-loss-observer.service")
    elif action == "observe":
        observe()
    elif action == "cleanup":
        emergency_cleanup()
    elif action == "effect":
        effect(False)
    elif action == "retry":
        effect(True)
    elif action == "frozen":
        assert not (ROOT / "observer.failed").exists()
        assert "frozen 1" in (cgroup() / "cgroup.events").read_text()
        assert (ROOT / "effects").read_bytes() == b"effect\n"
        assert all(same_process(item) for item in read_identities())
    elif action == "ready":
        assert (ROOT / "observer.ready").is_file()
        assert not (ROOT / "observer.failed").exists()
    elif action == "fault":
        fault()
    elif action in ("once", "twice"):
        assert (ROOT / "fault.done").exists() and not (ROOT / "observer.failed").exists()
        expected = 1 if action == "once" else 2
        assert (ROOT / "effects").read_bytes() == b"effect\n" * expected
        identities = read_identities()
        assert all(not same_process(item) for item in identities if item.role != "supervisor")
        assert all(same_process(item) for item in identities if item.role == "supervisor")
    else:
        raise AssertionError("unknown fixture action")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(
            json.dumps({"event": "executor_loss_fixture_failed", "category": type(error).__name__}),
            file=sys.stderr,
        )
        sys.exit(1)
