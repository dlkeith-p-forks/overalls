"""Exact emulated VMM process fault; kernel exit observation is separate from delivery."""

import os
import select
import signal
import time
from dataclasses import dataclass
from pathlib import Path
from typing import TypedDict


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    start_ticks: int

    def validate(self) -> None:
        if type(self.pid) is not int or self.pid <= 1:
            raise ValueError("invalid process identity")
        if type(self.start_ticks) is not int or self.start_ticks <= 0:
            raise ValueError("invalid process identity")


class ExitReceipt(TypedDict):
    version: int
    state: str
    pid: int
    start_ticks: int
    signal: int
    sent_monotonic_ns: int
    exited_monotonic_ns: int


def identity(pid: int) -> ProcessIdentity:
    """Read the kernel start tick without treating zombie state as live."""
    if type(pid) is not int or pid <= 1:
        raise ValueError("invalid process identity")
    fields = Path(f"/proc/{pid}/stat").read_text(encoding="ascii").rsplit(") ", 1)[1].split()
    if fields[0] in {"Z", "X"}:
        raise ProcessLookupError("process already exited")
    result = ProcessIdentity(pid, int(fields[19]))
    result.validate()
    return result


def crash(expected: ProcessIdentity, executable: Path, timeout_ms: int = 5000) -> ExitReceipt:
    """@cc [owner:ghuntley,label:security;verification] exact-pidfd-crash-and-exit
    The actuator MUST signal only a pidfd whose live kernel PID/start tick and
    executable match the trusted retained VMM identity (or its exact sibling
    Nix QEMU wrapped binary) after opening that pidfd.
    Signal delivery alone MUST NOT produce an exit receipt; that same pidfd
    MUST become readable before the bounded deadline. Mismatch or uncertainty
    MUST fail without a substitute PID, shell command or inferred absence.
    """
    expected.validate()
    if not executable.is_absolute() or ".." in executable.parts:
        raise ValueError("invalid executable identity")
    if type(timeout_ms) is not int or not 1 <= timeout_ms <= 30000:
        raise ValueError("invalid fault deadline")
    expected_executable = executable.resolve(strict=True)
    descriptor = os.pidfd_open(expected.pid)
    try:
        poller = select.poll()
        poller.register(descriptor, select.POLLIN)
        if poller.poll(0) or identity(expected.pid) != expected:
            raise ProcessLookupError("VMM identity changed before fault")
        allowed = {expected_executable}
        if expected_executable.name == "qemu-system-x86_64":
            allowed.add(expected_executable.with_name(".qemu-system-x86_64-wrapped"))
        if Path(f"/proc/{expected.pid}/exe").resolve(strict=True) not in allowed:
            raise ValueError("VMM executable does not match retained owner")
        sent = time.monotonic_ns()
        signal.pidfd_send_signal(descriptor, signal.SIGKILL)
        observed = poller.poll(timeout_ms)
        if len(observed) != 1 or observed[0][0] != descriptor or not observed[0][1] & select.POLLIN:
            raise TimeoutError("VMM exit remains unconfirmed")
        return {
            "version": 1,
            "state": "exited",
            "pid": expected.pid,
            "start_ticks": expected.start_ticks,
            "signal": int(signal.SIGKILL),
            "sent_monotonic_ns": sent,
            "exited_monotonic_ns": time.monotonic_ns(),
        }
    finally:
        os.close(descriptor)
