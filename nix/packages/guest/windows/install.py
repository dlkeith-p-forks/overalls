"""Drive an unattended Windows installation under QEMU for the Overalls image build.

The build sandbox has no network and no display. QEMU boots the Windows
installation ISO with OVMF, the answer-file ISO supplies drivers and the
unattended configuration, and the guest powers itself off from
``SetupComplete.cmd`` after writing ``OVERALLS-SETUP-COMPLETE`` to COM1.

The Overalls boot media uses Microsoft's no-prompt EFI boot image, so no key
needs pressing. For media that do show "Press any key to boot from CD or DVD",
``--keypress-seconds`` above zero makes the driver press Enter through the QEMU
human monitor only while that prompt can be on screen: from the moment the
firmware reports on the serial console that it is starting the DVD boot entry
until a few seconds later. Pressing keys at any other time drives the Setup UI
off the unattended path (an earlier run ended on a "Support Link" dialog).

Evidence. Every run leaves a self-describing evidence directory so a failed or
suspicious installation can be debugged after the fact without rerunning it:

* ``timeline.jsonl``: one JSON object per line with a UTC timestamp, elapsed
  seconds and an event: driver start, every QEMU lifecycle event from the QMP
  socket (RESET marks each Windows Setup stage boundary, SHUTDOWN the end),
  every ``OVERALLS-`` marker the guest prints on the serial console, disk usage
  samples, kept screenshots and the final verdict.
* ``serial.log``: the raw COM1 output.
* ``screenshots/``: PNG screendumps taken through QMP every sampling interval
  and after each lifecycle event, kept only when the frame changed.
* ``summary.json``: counts, duration, exit code and the reason for it.

Forensics. If Setup has not rebooted, printed a checkpoint or written to the
disk after ``STALL_SECONDS``, the driver assumes Windows Setup is stuck on an
error screen in Windows PE. It opens the Windows PE command prompt (Shift+F10),
creates a small FAT32 partition on the still-unused installation disk, copies
``X:\\$WINDOWS.~BT\\Sources\\Panther`` and ``X:\\Windows\\Panther`` there and
powers the machine off. The Nix build then reads those logs out of ``disk.raw``
with mtools, so the Setup action and error logs of a failed run are available
without anyone touching the VM.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import re
import select
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import TextIO

MARKER = b"OVERALLS-SETUP-COMPLETE"
MARKER_PREFIX = b"OVERALLS-"
# OVMF's boot manager logs this when it hands control to the installation DVD;
# the "Press any key" prompt follows within a second or two.
DVD_BOOT_LINE = b"BdsDxe: starting Boot"
DVD_BOOT_DEVICE = b"DVD-ROM"
# How long after that line the prompt is answered, in seconds.
KEYPRESS_WINDOW_SECONDS = 12.0
# Fallback if the firmware never reported the DVD start on serial.
KEYPRESS_FALLBACK_AT_SECONDS = 45.0
# No reboot, no checkpoint and no disk growth for this long means Setup is stuck.
STALL_SECONDS = 420.0
# Disk growth below this is partition-table noise, not installation progress.
STALL_DISK_BYTES = 1 << 20
# How long the guest gets to copy its logs and power off during forensics.
FORENSICS_TIMEOUT_SECONDS = 240.0
EXIT_STALLED = 5
# Human-monitor key names for the characters the forensics commands use.
KEY_NAMES = {
    " ": "spc",
    ".": "dot",
    ",": "comma",
    "\\": "backslash",
    "/": "slash",
    "-": "minus",
    "=": "equal",
    ";": "semicolon",
    "'": "apostrophe",
    "[": "bracket_left",
    "]": "bracket_right",
    ":": "shift-semicolon",
    ">": "shift-dot",
    "<": "shift-comma",
    "_": "shift-minus",
    "*": "shift-8",
    "(": "shift-9",
    ")": "shift-0",
    "&": "shift-7",
    "%": "shift-5",
    "$": "shift-4",
    "!": "shift-1",
    "?": "shift-slash",
    '"': "shift-apostrophe",
    "|": "shift-backslash",
    "@": "shift-2",
    "+": "shift-equal",
    "~": "shift-grave_accent",
}
# Typed at the Windows PE prompt, one line each, followed by Enter. Setup may
# have stalled before loading any storage driver, so the virtio block driver
# is loaded from the boot media first; otherwise diskpart sees no disk.
FORENSICS_COMMANDS = (
    "for %d in (C D E F G H I J K L) do if exist %d:\\overalls\\drivers\\viostor\\viostor.inf"
    " drvload %d:\\overalls\\drivers\\viostor\\viostor.inf",
    "ping -n 6 127.0.0.1 > nul",
    "(echo select disk 0& echo online disk noerr& echo attributes disk clear readonly noerr"
    "& echo clean& echo convert gpt"
    "& echo create partition primary size=512"
    "& echo format fs=fat32 quick label=OVERALLSLOG& echo assign letter=L& echo exit)"
    " > X:\\dp.txt",
    "diskpart /s X:\\dp.txt",
    "mkdir L:\\overalls\\logs\\winpe-setup L:\\overalls\\logs\\winpe-panther",
    "copy X:\\$WINDOWS.~BT\\Sources\\Panther\\*.* L:\\overalls\\logs\\winpe-setup\\",
    "copy X:\\Windows\\Panther\\*.* L:\\overalls\\logs\\winpe-panther\\",
    "copy X:\\overalls-*.txt L:\\overalls\\logs\\",
    "dir L:\\overalls\\logs\\winpe-setup L:\\overalls\\logs\\winpe-panther",
    "wpeutil shutdown",
)
# Typed at a Shift+F10 prompt of the installed OS (specialize or OOBE stalled
# after the first reboot). The disk must not be touched beyond the EFI system
# partition, which SetupComplete.cmd also uses to publish logs.
OS_FORENSICS_COMMANDS = (
    "mountvol S: /S",
    "mkdir S:\\overalls\\logs\\os-panther S:\\overalls\\logs\\os-unattendgc",
    "mkdir S:\\overalls\\logs\\os-inf",
    "copy C:\\Windows\\Panther\\*.log S:\\overalls\\logs\\os-panther\\",
    "copy C:\\Windows\\Panther\\*.xml S:\\overalls\\logs\\os-panther\\",
    "copy C:\\Windows\\Panther\\UnattendGC\\*.* S:\\overalls\\logs\\os-unattendgc\\",
    "copy C:\\Windows\\INF\\setupapi*.log S:\\overalls\\logs\\os-inf\\",
    "copy C:\\overalls\\*.log S:\\overalls\\logs\\",
    "dir S:\\overalls\\logs\\os-panther",
    "mountvol S: /D",
    "shutdown /s /t 0 /f",
)
EXIT_TIMEOUT = 2
EXIT_NO_MARKER = 3
EXIT_QEMU_FAILED = 4
SCREENSHOT_INTERVAL_SECONDS = 30.0
DISK_SAMPLE_INTERVAL_SECONDS = 60.0
# A store path prefix; scrubbed so evidence never becomes a runtime reference.
STORE_HASH: re.Pattern[str] = re.compile(r"/nix/store/[0-9a-z]{32}-")

# Lifecycle events worth a line in the timeline (and a screenshot).
LIFECYCLE_EVENTS = frozenset(
    {"RESET", "SHUTDOWN", "POWERDOWN", "STOP", "RESUME", "GUEST_PANICKED", "WAKEUP"}
)


@dataclass(frozen=True)
class Install:
    """Everything the QEMU run needs; all paths are absolute."""

    qemu: Path
    ovmf_code: Path
    ovmf_vars: Path
    boot_iso: Path
    source_iso: Path
    disk: Path
    evidence: Path
    monitor: Path
    qmp: Path
    memory_mib: int
    cores: int
    timeout_seconds: int
    keypress_seconds: int
    # QEMU guestfwd option for the installation-only file server, or None.
    serve: str | None = None

    @property
    def serial_log(self) -> Path:
        return self.evidence / "serial.log"

    @property
    def timeline(self) -> Path:
        return self.evidence / "timeline.jsonl"

    @property
    def screenshots(self) -> Path:
        return self.evidence / "screenshots"

    @property
    def summary(self) -> Path:
        return self.evidence / "summary.json"


def parse_args(argv: list[str]) -> Install:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qemu", type=Path, required=True)
    parser.add_argument("--ovmf-code", type=Path, required=True)
    parser.add_argument("--ovmf-vars", type=Path, required=True)
    parser.add_argument("--boot-iso", type=Path, required=True)
    parser.add_argument("--source-iso", type=Path, required=True)
    parser.add_argument("--disk", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--monitor", type=Path, required=True)
    parser.add_argument("--qmp", type=Path, required=True)
    parser.add_argument("--memory-mib", type=int, default=4096)
    parser.add_argument("--cores", type=int, default=4)
    parser.add_argument("--timeout-seconds", type=int, default=10800)
    parser.add_argument("--keypress-seconds", type=int, default=90)
    parser.add_argument(
        "--serve", default=None, help="http://ADDRESS the guest may reach (guestfwd, port 80)"
    )
    parser.add_argument(
        "--serve-command", default=None, help="per-connection command serving --serve"
    )
    args = parser.parse_args(argv)
    return Install(
        qemu=args.qemu.resolve(),
        ovmf_code=args.ovmf_code.resolve(),
        ovmf_vars=args.ovmf_vars.resolve(),
        boot_iso=args.boot_iso.resolve(),
        source_iso=args.source_iso.resolve(),
        disk=args.disk.resolve(),
        evidence=args.evidence_dir.resolve(),
        monitor=args.monitor.resolve(),
        qmp=args.qmp.resolve(),
        memory_mib=args.memory_mib,
        cores=args.cores,
        timeout_seconds=args.timeout_seconds,
        keypress_seconds=args.keypress_seconds,
        serve=guestfwd(args.serve, args.serve_command),
    )


def guestfwd(serve: str | None, command: str | None) -> str | None:
    """The ``guestfwd`` netdev option for the installation-only file server.

    The guest stays behind ``restrict=on``; QEMU runs ``command`` once per
    connection to ``ADDRESS:80`` with the connection on its stdin and stdout.
    """
    if serve is None and command is None:
        return None
    if serve is None or command is None:
        raise SystemExit("--serve and --serve-command go together")
    address = serve.removeprefix("http://").rstrip("/")
    if not re.fullmatch(r"10\.0\.2\.[0-9]+", address) or "," in command:
        raise SystemExit(f"refusing guestfwd target {serve!r}")
    return f"guestfwd=tcp:{address}:80-cmd:{command}"


def qemu_command(install: Install) -> list[str]:
    """QEMU invocation matching the devices Firecracker later exposes.

    ``disable-legacy=on`` forces modern-only virtio-pci device identifiers
    (``1AF4:1041`` network, ``1AF4:1042`` block), the same identifiers the
    Firecracker PCI transport reports, so the drivers Windows binds during
    installation are the ones it needs at first boot under Firecracker.
    ``restrict=on`` keeps the guest offline for the whole installation; the
    only reachable endpoint is the optional guestfwd file server (``serve``).
    """
    return [
        str(install.qemu),
        "-machine",
        "q35,accel=kvm",
        "-cpu",
        "host",
        "-smp",
        str(install.cores),
        "-m",
        str(install.memory_mib),
        "-display",
        "none",
        "-nodefaults",
        "-device",
        "VGA",
        "-serial",
        f"file:{install.serial_log}",
        "-monitor",
        f"unix:{install.monitor},server,nowait",
        "-qmp",
        f"unix:{install.qmp},server,nowait",
        "-drive",
        f"if=pflash,format=raw,readonly=on,file={install.ovmf_code}",
        "-drive",
        f"if=pflash,format=raw,file={install.ovmf_vars}",
        "-drive",
        f"id=root,if=none,format=raw,file={install.disk},discard=unmap,detect-zeroes=unmap",
        "-device",
        "virtio-blk-pci,drive=root,disable-legacy=on,bootindex=1",
        "-netdev",
        ",".join(["user", "id=net0", "restrict=on", *([install.serve] if install.serve else [])]),
        "-device",
        "virtio-net-pci,netdev=net0,disable-legacy=on",
        # The Overalls boot media (modified boot.wim, answer file, drivers) is the
        # bootable CD; Microsoft's ISO is only the installation source. q35
        # exposes one AHCI unit per SATA port, so each CD gets its own port.
        "-drive",
        f"id=cd0,if=none,media=cdrom,file={install.boot_iso}",
        "-device",
        "ide-cd,drive=cd0,bus=ide.0,bootindex=2",
        "-drive",
        f"id=cd1,if=none,media=cdrom,file={install.source_iso}",
        "-device",
        "ide-cd,drive=cd1,bus=ide.1",
        "-rtc",
        "base=utc",
    ]


class Timeline:
    """Append-only JSON-lines event log with wall-clock and elapsed time.

    Store hashes are scrubbed from every line: the timeline ships in the image
    output, and a hash would make Nix keep the ISO, QEMU and OVMF in the
    image's runtime closure on every host.
    """

    def __init__(self, path: Path, started: float) -> None:
        self._started = started
        self._file: TextIO = path.open("a", encoding="utf-8")

    def record(self, kind: str, **detail: object) -> None:
        entry: dict[str, object] = {
            "time": datetime.now(UTC).isoformat(timespec="milliseconds"),
            "elapsed_s": round(time.monotonic() - self._started, 3),
            "event": kind,
        }
        entry.update(detail)
        line = STORE_HASH.sub("/nix/store/HASH-", json.dumps(entry, sort_keys=True))
        self._file.write(line + "\n")
        self._file.flush()
        # Mirror every event to stderr so the Nix build log shows live progress
        # while the sandbox output directory is still unreadable from outside.
        print(f"install: {line}", file=sys.stderr, flush=True)

    def close(self) -> None:
        self._file.close()


class Qmp:
    """Minimal QEMU Machine Protocol client: commands plus asynchronous events.

    The connection is opened lazily because QEMU creates the socket after the
    driver starts it. Failures never abort the installation; they are recorded
    and the driver keeps observing through the serial log alone.
    """

    def __init__(self, path: Path, timeline: Timeline) -> None:
        self._path = path
        self._timeline = timeline
        self._sock: socket.socket | None = None
        self._buffer = b""
        self._pending: list[dict[str, object]] = []

    @property
    def connected(self) -> bool:
        return self._sock is not None

    def connect(self) -> bool:
        if self._sock is not None:
            return True
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(2.0)
            sock.connect(str(self._path))
            self._sock = sock
            greeting = self._read_message(timeout=2.0)
            self._send({"execute": "qmp_capabilities"})
            self._read_response(timeout=2.0)
        except (OSError, ValueError) as error:
            self._sock = None
            self._timeline.record("qmp_unavailable", error=str(error))
            return False
        version = greeting.get("QMP", {}) if isinstance(greeting, dict) else {}
        self._timeline.record("qmp_connected", qmp=version)
        return True

    def _send(self, message: dict[str, object]) -> None:
        if self._sock is None:
            raise OSError("QMP not connected")
        self._sock.sendall(json.dumps(message).encode() + b"\n")

    def _read_message(self, timeout: float) -> dict[str, object]:
        if self._sock is None:
            raise OSError("QMP not connected")
        deadline = time.monotonic() + timeout
        while b"\n" not in self._buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("QMP read timed out")
            ready, _, _ = select.select([self._sock], [], [], remaining)
            if not ready:
                continue
            chunk = self._sock.recv(65536)
            if not chunk:
                raise OSError("QMP connection closed")
            self._buffer += chunk
        line, _, self._buffer = self._buffer.partition(b"\n")
        message = json.loads(line)
        if not isinstance(message, dict):
            raise ValueError("QMP message is not an object")
        return message

    def _read_response(self, timeout: float) -> dict[str, object]:
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("QMP response timed out")
            message = self._read_message(timeout=remaining)
            if "event" in message:
                self._pending.append(message)
                continue
            return message

    def poll_events(self) -> list[dict[str, object]]:
        """Return lifecycle events received since the last call."""
        events = list(self._pending)
        self._pending.clear()
        if self._sock is None:
            return events
        try:
            while True:
                ready, _, _ = select.select([self._sock], [], [], 0)
                if not ready and b"\n" not in self._buffer:
                    break
                message = self._read_message(timeout=0.5)
                if "event" in message:
                    events.append(message)
        except TimeoutError:
            pass
        except (OSError, ValueError) as error:
            self._timeline.record("qmp_lost", error=str(error))
            self._sock = None
        return events

    def screendump(self, target: Path) -> bool:
        """Ask QEMU for a PNG of the current framebuffer; PPM if PNG is missing."""
        if self._sock is None:
            return False
        for image_format in ("png", "ppm"):
            try:
                self._send(
                    {
                        "execute": "screendump",
                        "arguments": {"filename": str(target), "format": image_format},
                    }
                )
                response = self._read_response(timeout=10.0)
            except (OSError, ValueError) as error:
                self._timeline.record("screendump_failed", error=str(error))
                self._sock = None
                return False
            if "error" not in response:
                return True
        self._timeline.record("screendump_failed", error=str(response.get("error")))
        return False


def send_keys(monitor: Path, keys: list[str], delay: float = 0.08) -> bool:
    """Send key names through the QEMU human monitor, one sendkey each."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(2.0)
            sock.connect(str(monitor))
            sock.recv(4096)
            for key in keys:
                sock.sendall(f"sendkey {key}\n".encode())
                time.sleep(delay)
                # The monitor's acknowledgement is optional; a quiet socket is fine.
                with contextlib.suppress(TimeoutError):
                    sock.recv(4096)
    except OSError:
        return False
    return True


def press_enter(monitor: Path) -> bool:
    """Send one Enter keypress through the QEMU human monitor."""
    return send_keys(monitor, ["ret"])


def key_name(char: str) -> str:
    if char in KEY_NAMES:
        return KEY_NAMES[char]
    if char.isalpha():
        return f"shift-{char.lower()}" if char.isupper() else char
    if char.isdigit():
        return char
    raise ValueError(f"no monitor key for {char!r}")


def type_line(monitor: Path, line: str) -> bool:
    """Type a command line at the guest prompt and press Enter."""
    return send_keys(monitor, [key_name(char) for char in line] + ["ret"])


def run_forensics(
    install: Install,
    timeline: Timeline,
    screenshots: Screenshots,
    started: float,
    installed_phase: bool,
) -> None:
    """Dump the Setup logs onto the disk and power the guest off.

    Before the first reboot the logs live on the Windows PE RAM disk and the
    installation disk is free to take a scratch partition. After it, the
    installed system's logs are copied to its EFI system partition instead.
    """
    timeline.record("forensics", step="shift-f10", installed_phase=installed_phase)
    send_keys(install.monitor, ["shift-f10"])
    time.sleep(5.0)
    commands = OS_FORENSICS_COMMANDS if installed_phase else FORENSICS_COMMANDS
    for line in commands:
        timeline.record("forensics", step="type", command=line)
        type_line(install.monitor, line)
        # drvload, diskpart and the copies take a few seconds each.
        time.sleep(6.0)
        screenshots.capture(time.monotonic() - started, reason="forensics")


@dataclass
class SerialMarkers:
    """Incrementally scans the serial log for guest-side OVERALLS- markers.

    It also notices the firmware line announcing the DVD boot, which opens the
    only window in which the driver may press a key.
    """

    path: Path
    offset: int = 0
    seen: list[str] = field(default_factory=list)
    dvd_boot_seen: bool = False
    _partial: bytes = b""

    def poll(self) -> list[str]:
        try:
            with self.path.open("rb") as handle:
                handle.seek(self.offset)
                chunk = handle.read()
        except FileNotFoundError:
            return []
        if not chunk:
            return []
        self.offset += len(chunk)
        data = self._partial + chunk
        lines = data.split(b"\n")
        self._partial = lines.pop()
        found: list[str] = []
        for raw in lines:
            line = raw.strip(b"\r\x00 ")
            if DVD_BOOT_LINE in line and DVD_BOOT_DEVICE in line:
                self.dvd_boot_seen = True
            if line.startswith(MARKER_PREFIX):
                text = line.decode("ascii", errors="replace")
                found.append(text)
                self.seen.append(text)
        return found


class Screenshots:
    """Keeps screendumps only when the framebuffer changed."""

    def __init__(self, directory: Path, qmp: Qmp, timeline: Timeline) -> None:
        self._directory = directory
        self._qmp = qmp
        self._timeline = timeline
        self._last_digest = ""
        self.kept = 0
        directory.mkdir(parents=True, exist_ok=True)

    def capture(self, elapsed: float, reason: str) -> None:
        if not self._qmp.connected:
            return
        candidate = self._directory / "pending.img"
        if not self._qmp.screendump(candidate):
            return
        try:
            data = candidate.read_bytes()
        except FileNotFoundError:
            return
        digest = hashlib.sha256(data).hexdigest()
        if digest == self._last_digest:
            candidate.unlink()
            return
        self._last_digest = digest
        suffix = "png" if data.startswith(b"\x89PNG") else "ppm"
        name = f"{self.kept:04d}-{int(elapsed):06d}s-{reason}.{suffix}"
        candidate.rename(self._directory / name)
        self.kept += 1
        self._timeline.record(
            "screenshot", file=f"screenshots/{name}", reason=reason, sha256=digest
        )


def disk_usage_bytes(path: Path) -> int:
    return os.stat(path).st_blocks * 512


def run(install: Install) -> int:
    """Run the installation to completion; the exit code states what happened."""
    install.evidence.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    timeline = Timeline(install.timeline, started)
    qmp = Qmp(install.qmp, timeline)
    screenshots = Screenshots(install.screenshots, qmp, timeline)
    markers = SerialMarkers(install.serial_log)
    command = qemu_command(install)
    timeline.record(
        "start",
        qemu=command,
        memory_mib=install.memory_mib,
        cores=install.cores,
        timeout_seconds=install.timeout_seconds,
    )
    next_screenshot = 0.0
    next_disk_sample = 0.0
    keypresses = 0
    keypress_until: float | None = None
    lifecycle: list[str] = []
    reason = "unknown"
    code: int | None = None
    forensics_started: float | None = None
    # Progress means a reboot, a guest checkpoint or the disk growing.
    last_progress = 0.0
    last_disk_bytes = 0
    installed_phase = False
    with subprocess.Popen(command) as qemu:
        while True:
            elapsed = time.monotonic() - started
            code = qemu.poll()
            if code is not None:
                reason = "forensics_done" if forensics_started else "qemu_exited"
                break
            if elapsed > install.timeout_seconds or (
                forensics_started is not None
                and elapsed - forensics_started > FORENSICS_TIMEOUT_SECONDS
            ):
                qemu.kill()
                qemu.wait()
                reason = "forensics_timeout" if forensics_started else "timeout"
                timeline.record(reason, timeout_seconds=install.timeout_seconds)
                break
            current_disk_bytes = disk_usage_bytes(install.disk)
            if abs(current_disk_bytes - last_disk_bytes) >= STALL_DISK_BYTES:
                last_disk_bytes = current_disk_bytes
                last_progress = elapsed
            if current_disk_bytes >= STALL_DISK_BYTES:
                installed_phase = True
            if forensics_started is None and elapsed - last_progress > STALL_SECONDS:
                timeline.record(
                    "stalled",
                    elapsed_s=round(elapsed, 1),
                    disk_usage_bytes=current_disk_bytes,
                    installed_phase=installed_phase,
                )
                screenshots.capture(elapsed, reason="stalled")
                forensics_started = elapsed
                run_forensics(install, timeline, screenshots, started, installed_phase)
                continue
            if not qmp.connected:
                qmp.connect()
            for event in qmp.poll_events():
                name = str(event.get("event"))
                timeline.record("qemu_event", name=name, data=event.get("data"))
                if name in LIFECYCLE_EVENTS:
                    lifecycle.append(name)
                    screenshots.capture(elapsed, reason=name.lower())
                if name == "RESET":
                    last_progress = elapsed
                    installed_phase = True
            new_markers = markers.poll()
            if install.keypress_seconds > 0 and keypress_until is None and keypresses == 0:
                if markers.dvd_boot_seen:
                    keypress_until = elapsed + KEYPRESS_WINDOW_SECONDS
                    timeline.record("keypress_window", reason="firmware_dvd_boot")
                elif elapsed >= KEYPRESS_FALLBACK_AT_SECONDS:
                    keypress_until = elapsed + KEYPRESS_WINDOW_SECONDS
                    timeline.record("keypress_window", reason="fallback_timer")
            if (
                keypress_until is not None
                and elapsed < keypress_until
                and elapsed < install.keypress_seconds
                and press_enter(install.monitor)
            ):
                keypresses += 1
            for marker in new_markers:
                timeline.record("serial_marker", marker=marker)
                screenshots.capture(elapsed, reason="marker")
                last_progress = elapsed
            if elapsed >= next_screenshot:
                screenshots.capture(elapsed, reason="interval")
                next_screenshot = elapsed + SCREENSHOT_INTERVAL_SECONDS
            if elapsed >= next_disk_sample:
                timeline.record("disk_usage", bytes=disk_usage_bytes(install.disk))
                next_disk_sample = elapsed + DISK_SAMPLE_INTERVAL_SECONDS
            time.sleep(1.0)
    markers.poll()
    duration = round(time.monotonic() - started, 1)
    marker_seen = any(line.startswith(MARKER.decode()) for line in markers.seen)
    if reason == "timeout":
        result = EXIT_TIMEOUT
    elif forensics_started is not None:
        result = EXIT_STALLED
        reason = "stalled_" + reason
    elif code != 0:
        result = EXIT_QEMU_FAILED
        reason = f"qemu_exit_{code}"
    elif not marker_seen:
        result = EXIT_NO_MARKER
        reason = "no_completion_marker"
    else:
        result = 0
        reason = "complete"
    summary: dict[str, object] = {
        "result": result,
        "reason": reason,
        "duration_s": duration,
        "qemu_exit_code": code,
        "keypresses": keypresses,
        "lifecycle_events": lifecycle,
        "serial_markers": markers.seen,
        "screenshots_kept": screenshots.kept,
        "disk_usage_bytes": disk_usage_bytes(install.disk),
    }
    install.summary.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    timeline.record("finish", **summary)
    timeline.close()
    if result == EXIT_TIMEOUT:
        print(f"install: timed out after {install.timeout_seconds}s", file=sys.stderr)
    elif result == EXIT_STALLED:
        print(
            f"install: setup stalled; Windows PE logs dumped to the disk ({reason})",
            file=sys.stderr,
        )
    elif result == EXIT_QEMU_FAILED:
        print(f"install: qemu exited with {code}", file=sys.stderr)
    elif result == EXIT_NO_MARKER:
        print(
            "install: guest powered off without the completion marker",
            file=sys.stderr,
        )
    else:
        print(f"install: complete after {duration}s, {screenshots.kept} screenshots")
    return result


def main(argv: list[str]) -> int:
    return run(parse_args(argv))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
