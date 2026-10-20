"""Drive one bounded single-user OmniOS QEMU boot over its serial console.

The pinned stock image has no network identity during Nix assembly, so the
only control channel is the loader and single-user console. Each command must
print an exact status marker; any nonzero status or deadline fails the build.
"""

from __future__ import annotations

import argparse
import errno
import os
import pty
import re
import select
import subprocess
import time
import tty
from dataclasses import dataclass
from pathlib import Path

PROMPT = b"# "
MAX_RECENT = 1024 * 1024
CHARACTER_DELAY = 0.02


@dataclass(frozen=True)
class Drive:
    path: Path
    readonly: bool


class Options(argparse.Namespace):
    qemu: Path
    log: Path
    commands: Path
    timeout: int
    memory: int
    drive: list[str]
    extra: list[str]


def drive(value: str) -> Drive:
    mode, _, path = value.partition(":")
    if mode not in ("ro", "rw") or not path:
        raise argparse.ArgumentTypeError("drive must be ro:PATH or rw:PATH")
    return Drive(Path(path), mode == "ro")


def qemu_arguments(options: Options, drives: list[Drive]) -> list[str]:
    arguments = [
        str(options.qemu),
        "-machine",
        "q35,accel=kvm",
        "-cpu",
        "host",
        "-smp",
        "2",
        "-m",
        str(options.memory),
        "-display",
        "none",
        "-nodefaults",
        "-no-reboot",
        # The stock image copies share ZFS vdev GUIDs. Expose only the boot
        # disk to the loader so it never binds the scratch copy's vdev.
        "-boot",
        "strict=on",
        "-rtc",
        "base=2026-10-17T00:00:00,clock=vm",
        "-serial",
        "stdio",
    ]
    for index, item in enumerate(drives):
        identifier = f"disk{index}"
        readonly = ",readonly=on" if item.readonly else ""
        boot = ",bootindex=1" if index == 0 else ""
        arguments.extend(
            [
                "-drive",
                f"if=none,id={identifier},format=raw,file={item.path}{readonly}",
                "-device",
                f"virtio-blk-pci,drive={identifier},addr={index + 4}{boot}",
            ]
        )
    arguments.extend(options.extra)
    return arguments


def load_commands(path: Path) -> list[str]:
    commands = [line for line in path.read_text(encoding="ascii").splitlines() if line.strip()]
    if not commands or any("\n" in command or len(command) > 1024 for command in commands):
        raise ValueError("bounded single-line serial commands are required")
    return commands


def run(options: Options) -> None:
    """@cc [owner:ghuntley,label:build;verification] omnios-serial-session
    The session MUST boot only the supplied disks offline, enter single-user
    mode through the loader prompt, execute each command with an exact status
    marker and refuse a nonzero status, missing marker or deadline. The final
    command MUST power off and QEMU MUST exit by itself before success.
    """
    drives = [drive(value) for value in options.drive]
    commands = load_commands(options.commands)
    if not drives or not 60 <= options.timeout <= 7200:
        raise ValueError("a boot disk and bounded timeout are required")
    master, slave = pty.openpty()
    tty.setraw(slave)
    process = subprocess.Popen(
        qemu_arguments(options, drives),
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
    )
    os.close(slave)
    recent = bytearray()
    phase = "loader"
    step = -1
    pending = b""
    next_send = 0.0
    deadline = time.monotonic() + options.timeout
    powered_off = False
    try:
        with options.log.open("wb", buffering=0) as log:
            while time.monotonic() < deadline:
                if pending and time.monotonic() >= next_send:
                    os.write(master, pending[:1])
                    pending = pending[1:]
                    next_send = time.monotonic() + CHARACTER_DELAY
                ready, _, _ = select.select([master], [], [], 0.05)
                if ready:
                    try:
                        data = os.read(master, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        data = b""
                    if not data:
                        break
                    log.write(data)
                    recent.extend(data)
                if process.poll() is not None:
                    break
                clean = bytes(recent).replace(b"\x1b", b"").replace(b"\r", b"")
                if phase == "loader" and b"Autoboot" in clean:
                    os.write(master, b"3")
                    phase = "prompt"
                    recent.clear()
                elif phase == "prompt" and b"ok " in clean:
                    pending = b"boot -s\r"
                    next_send = time.monotonic() + 0.5
                    phase = "user"
                    recent.clear()
                elif phase == "user" and b"Enter user name for system maintenance" in clean:
                    pending = b"root\n"
                    phase = "password"
                    recent.clear()
                elif phase == "password" and b"Enter root password" in clean:
                    pending = b"\n"
                    phase = "shell"
                    recent.clear()
                elif phase == "shell" and not pending and PROMPT in clean:
                    if step >= 0:
                        marker = re.search(
                            rb"OVERALLS_STEP_" + str(step).encode() + rb"_STATUS=([0-9]+)\n",
                            clean,
                        )
                        if marker is None:
                            continue
                        if marker[1] != b"0":
                            raise RuntimeError(f"serial command step {step} failed")
                        print(f"serial step {step} passed", flush=True)
                    step += 1
                    command = commands[step]
                    if step == len(commands) - 1:
                        pending = (command + "\n").encode("ascii")
                        phase = "poweroff"
                    else:
                        pending = (command + f"; echo OVERALLS_STEP_{step}_STATUS=$?\n").encode(
                            "ascii"
                        )
                    next_send = time.monotonic() + 0.3
                    recent.clear()
                if len(recent) > MAX_RECENT:
                    del recent[: -MAX_RECENT // 2]
            if phase == "poweroff":
                remaining = max(1.0, deadline - time.monotonic())
                process.wait(timeout=min(remaining, 180.0))
                powered_off = process.returncode == 0
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=20)
        os.close(master)
    if not powered_off:
        raise RuntimeError(f"serial session incomplete at phase {phase}, step {step}")
    print("serial session powered off cleanly", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qemu", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--commands", type=Path, required=True)
    parser.add_argument("--timeout", type=int, required=True)
    parser.add_argument("--memory", type=int, default=2048)
    parser.add_argument("--drive", action="append", default=[])
    parser.add_argument("--extra", action="append", default=[])
    run(parser.parse_args(namespace=Options()))


if __name__ == "__main__":
    main()
