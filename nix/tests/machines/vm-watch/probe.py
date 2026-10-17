"""Native lilly-vm-watch behaviour against real pidfd and cgroup2 events."""

import subprocess
import sys
import time

helper = sys.argv[1]


def unit_pid(unit: str) -> tuple[str, int]:
    subprocess.run(
        ["systemd-run", "--unit", unit, "--slice", "lilly.slice", "sleep", "infinity"],
        check=True,
        capture_output=True,
        timeout=10,
    )
    pid = int(
        subprocess.run(
            ["systemctl", "show", "-P", "MainPID", unit],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
    )
    return f"/sys/fs/cgroup/lilly.slice/{unit}.service", pid


def watcher(cgroup: str, pid: int) -> subprocess.Popen[str]:
    process = subprocess.Popen(
        [helper, cgroup, str(pid)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    assert process.stdout is not None
    line = process.stdout.readline().strip()
    assert line == "armed", line
    return process


def finished(process: subprocess.Popen[str]) -> str:
    assert process.stdout is not None
    return process.stdout.readline().strip()


# @cc [owner:ghuntley,label:verification;isolation] vm-watch-native-kernel-exit
# This probe MUST use the packaged helper against real systemd units: SIGKILL
# of the watched PID and an emptied unit cgroup both report exited promptly,
# a PID outside the named cgroup is refused, and closing stdin detaches
# silently. It claims nothing about Firecracker or Lilly's actor.
cgroup, pid = unit_pid("vmwatch-kill")
process = watcher(cgroup, pid)
started = time.monotonic()
subprocess.run(["kill", "-9", str(pid)], check=True, timeout=5)
assert finished(process) == "exited"
elapsed = time.monotonic() - started
assert process.wait(timeout=5) == 0
assert elapsed < 0.05, f"exit reported after {elapsed:.3f}s"

cgroup, pid = unit_pid("vmwatch-stop")
process = watcher(cgroup, pid)
subprocess.run(["systemctl", "stop", "vmwatch-stop"], check=True, timeout=10)
assert finished(process) == "exited"

cgroup, pid = unit_pid("vmwatch-foreign")
foreign = subprocess.Popen(["sleep", "infinity"])
refused = subprocess.run(
    [helper, cgroup, str(foreign.pid)], capture_output=True, text=True, timeout=10
)
assert refused.returncode != 0 and refused.stdout == "error\n", refused
foreign.kill()

process = watcher(cgroup, pid)
assert process.stdin is not None
process.stdin.close()
assert process.wait(timeout=5) == 0
assert finished(process) == ""

for bad in [["/sys/fs/cgroup/.", str(pid)], ["/tmp", str(pid)], [cgroup, "0"], [cgroup]]:
    result = subprocess.run([helper, *bad], capture_output=True, text=True, timeout=10)
    assert result.returncode != 0 and result.stdout == "error\n", (bad, result)

print(
    f"vm-watch: kill reported in {elapsed * 1000:.1f} ms; stop, foreign PID, detach and grammar passed"
)
