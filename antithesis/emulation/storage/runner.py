"""Single-owner QEMU TCG supervisor for the retained Linux/ZFS router guest."""

import argparse
import errno
import fcntl
import hashlib
import json
import os
import socket
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import TypedDict

DISK_BYTES = 1024**3
MAX_MESSAGE = 256 * 1024


class Process(TypedDict):
    pid: int
    start_ticks: int


@dataclass(frozen=True)
class Config:
    image_dir: Path
    state_dir: Path
    runtime_dir: Path
    qemu: Path
    qemu_img: Path

    @classmethod
    def read(cls, path: Path) -> "Config":
        raw: object = json.loads(path.read_text(encoding="ascii"))
        if not isinstance(raw, dict) or set(raw) != {
            "image_dir",
            "state_dir",
            "runtime_dir",
            "qemu",
            "qemu_img",
        }:
            raise ValueError("invalid router config fields")
        values: dict[str, Path] = {}
        for key in ("image_dir", "state_dir", "runtime_dir", "qemu", "qemu_img"):
            value = raw[key]
            if not isinstance(value, str):
                raise ValueError("invalid router config path")
            target = Path(value)
            if not target.is_absolute() or ".." in target.parts:
                raise ValueError("invalid router config path")
            values[key] = target
        if len(os.fsencode(values["runtime_dir"] / "control.sock")) >= 108:
            raise ValueError("router socket path too long")
        return cls(**values)


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            sha.update(chunk)
    return sha.hexdigest()


def write_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(".new")
    with temporary.open("w", encoding="ascii") as stream:
        json.dump(value, stream, separators=(",", ":"), sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def image(config: Config) -> dict[str, str]:
    raw: object = json.loads((config.image_dir / "manifest.json").read_text(encoding="ascii"))
    if not isinstance(raw, dict) or set(raw) != {"version", "root", "kernel", "initrd", "toplevel"}:
        raise ValueError("invalid router image manifest")
    if (
        raw["version"] != 1
        or not isinstance(raw["toplevel"], str)
        or not raw["toplevel"].startswith("/nix/store/")
    ):
        raise ValueError("invalid router image version or system")
    for key, filename in (("root", "root.qcow2"), ("kernel", "kernel"), ("initrd", "initrd")):
        record = raw[key]
        path = config.image_dir / filename
        if not isinstance(record, dict) or set(record) != {"bytes", "sha256"}:
            raise ValueError("invalid router image record")
        if type(record["bytes"]) is not int or not isinstance(record["sha256"], str):
            raise ValueError("invalid router image hash")
        if path.stat().st_size != record["bytes"] or digest(path) != record["sha256"]:
            raise ValueError("router image bytes changed")
    return {"root": digest(config.image_dir / "root.qcow2"), "toplevel": raw["toplevel"]}


def command(argv: list[str], timeout: int = 30) -> str:
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=True)
    if len(result.stdout) > 65536:
        raise ValueError("oversized host result")
    return result.stdout.strip()


def ensure_disks(config: Config, identity: dict[str, str]) -> None:
    """@cc [owner:ghuntley,label:storage;recovery] retained-router-outer-files
    Ordinary start/restart reopens one root overlay and two fixed raw members.
    A partial retained set is an error; no path is silently recreated.
    """
    record = config.state_dir / "image.json"
    paths = [
        config.state_dir / "root.qcow2",
        config.state_dir / "mirror-a.raw",
        config.state_dir / "mirror-b.raw",
    ]
    exists = [path.exists() for path in [record, *paths]]
    if any(exists) and not all(exists):
        raise ValueError("incomplete retained router disks")
    if all(exists):
        raw: object = json.loads(record.read_text(encoding="ascii"))
        if raw != identity:
            raise ValueError("retained router base image changed")
        for path in paths[1:]:
            if path.stat().st_size != DISK_BYTES:
                raise ValueError("retained mirror size changed")
        return
    backing = (config.image_dir / "root.qcow2").resolve(strict=True)
    command(
        [
            str(config.qemu_img),
            "create",
            "-f",
            "qcow2",
            "-F",
            "qcow2",
            "-b",
            str(backing),
            str(paths[0]),
        ],
        60,
    )
    for path in paths[1:]:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.ftruncate(descriptor, DISK_BYTES)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    write_json(record, identity)


def start_ticks(pid: int) -> int:
    fields = Path(f"/proc/{pid}/stat").read_text(encoding="ascii").rsplit(") ", 1)[1].split()
    return int(fields[19])


def live(config: Config) -> Process | None:
    path = config.state_dir / "qemu.json"
    if not path.exists():
        return None
    raw: object = json.loads(path.read_text(encoding="ascii"))
    if not isinstance(raw, dict) or set(raw) != {"pid", "start_ticks"}:
        raise ValueError("invalid retained QEMU record")
    pid, ticks = raw["pid"], raw["start_ticks"]
    if type(pid) is not int or type(ticks) is not int:
        raise ValueError("invalid retained QEMU process")
    try:
        if start_ticks(pid) == ticks:
            return Process(pid=pid, start_ticks=ticks)
    except (FileNotFoundError, ProcessLookupError):
        pass
    return None


def drive_cache(paths: tuple[Path, ...]) -> str:
    """@cc [owner:ghuntley,label:verification;recovery] vmm-drive-cache-mode
    Disks MUST use QEMU cache=none when every image file, including the qcow2
    backing image, accepts O_DIRECT. A filesystem that refuses O_DIRECT (the
    Antithesis container filesystem) MUST fall back to cache=writeback, which
    still turns each guest flush into a host fsync; never cache=unsafe. The
    effective mode is printed so a run records which durability backend it had.
    """
    mode = "none"
    for path in paths:
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_DIRECT)
        except OSError as error:
            if error.errno != errno.EINVAL:
                raise
            mode = "writeback"
            break
        os.close(descriptor)
    print(f"overalls vmm drive cache={mode}", file=sys.stderr, flush=True)
    return mode


def start(config: Config) -> Process:
    identity = image(config)
    ensure_disks(config, identity)
    active = live(config)
    if active is not None:
        return active
    config.runtime_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    for name in ("qmp.sock", "control.sock"):
        path = config.runtime_dir / name
        if path.exists():
            path.unlink()
    qmp = config.runtime_dir / "qmp.sock"
    control = config.runtime_dir / "control.sock"
    state = config.state_dir
    cache = drive_cache(
        (
            state / "root.qcow2",
            state / "mirror-a.raw",
            state / "mirror-b.raw",
            (config.image_dir / "root.qcow2").resolve(strict=True),
        )
    )
    argv = [
        str(config.qemu),
        "-machine",
        "q35",
        "-accel",
        "tcg,thread=single",
        "-cpu",
        "max",
        "-smp",
        "1",
        "-m",
        "2048",
        "-nodefaults",
        "-display",
        "none",
        "-serial",
        "stdio",
        "-monitor",
        "none",
        "-kernel",
        str(config.image_dir / "kernel"),
        "-initrd",
        str(config.image_dir / "initrd"),
        "-append",
        "init=" + identity["toplevel"] + "/init root=LABEL=nixos rw console=ttyS0 panic=1",
        "-drive",
        f"if=none,id=root,file={state / 'root.qcow2'},format=qcow2,cache={cache}",
        "-device",
        "virtio-blk-pci,drive=root,serial=KTROUTER-ROOT",
        "-drive",
        f"if=none,id=mirror-a,file={state / 'mirror-a.raw'},format=raw,cache={cache}",
        "-device",
        "virtio-blk-pci,drive=mirror-a,serial=KTROUTER-MIRROR-A",
        "-drive",
        f"if=none,id=mirror-b,file={state / 'mirror-b.raw'},format=raw,cache={cache}",
        "-device",
        "virtio-blk-pci,drive=mirror-b,serial=KTROUTER-MIRROR-B",
        "-qmp",
        f"unix:{qmp},server=on,wait=off",
        "-chardev",
        f"socket,id=control,path={control},server=on,wait=off",
        "-device",
        "virtio-serial-pci",
        "-device",
        "virtserialport,chardev=control,name=org.overalls.storage.control",
    ]
    with (state / "serial.log").open("ab") as output:
        process = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    record = Process(pid=process.pid, start_ticks=start_ticks(process.pid))
    write_json(state / "qemu.json", record)
    return record


def receive(connection: socket.socket) -> dict[str, object]:
    data = bytearray()
    while not data.endswith(b"\n"):
        # QMP may send an event and a reply in one packet. Read exactly one
        # framed line so a later reply is never discarded with surplus bytes.
        chunk = connection.recv(1)
        if not chunk:
            raise ConnectionError("router socket closed")
        data.extend(chunk)
        if len(data) > MAX_MESSAGE:
            raise ValueError("router response too large")
    raw: object = json.loads(data)
    if not isinstance(raw, dict):
        raise ValueError("invalid router response")
    return raw


def qmp_reset(config: Config) -> dict[str, object]:
    if live(config) is None:
        raise ValueError("router QEMU unavailable")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(10)
        connection.connect(str(config.runtime_dir / "qmp.sock"))
        hello = receive(connection)
        if "QMP" not in hello:
            raise ValueError("invalid QMP greeting")
        connection.sendall(b'{"execute":"qmp_capabilities","id":"caps"}\n')
        if receive(connection).get("id") != "caps":
            raise ValueError("QMP capabilities not acknowledged")
        connection.sendall(b'{"execute":"system_reset","id":"reset"}\n')
        for _ in range(8):
            reply = receive(connection)
            if reply.get("id") == "reset":
                if "return" not in reply:
                    raise ValueError("QMP reset failed")
                return {"fault_class": "explicit-qmp", "acknowledged": True}
        raise ValueError("QMP reset acknowledgment unavailable")


def guest_request(config: Config, request: dict[str, object]) -> dict[str, object]:
    if live(config) is None:
        raise ValueError("router QEMU unavailable")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(180)
        connection.connect(str(config.runtime_dir / "control.sock"))
        connection.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode("ascii"))
        result = receive(connection)
        if result.get("id") != request.get("id") or result.get("version") != 1:
            raise ValueError("uncorrelated router reply")
        return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("action", choices=("start", "observe", "request", "qmp-reboot"))
    options = parser.parse_args()
    config = Config.read(options.config)
    config.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (config.state_dir / "owner.lock").open("a+b") as owner:
        fcntl.flock(owner, fcntl.LOCK_EX)
        if options.action == "start":
            result: object = start(config)
        elif options.action == "qmp-reboot":
            result = qmp_reset(config)
        else:
            request: object = (
                {
                    "version": 1,
                    "id": "0000000000000000",
                    "action": "observe",
                    "target": None,
                    "value": None,
                }
                if options.action == "observe"
                else json.loads(input())
            )
            if not isinstance(request, dict) or len(json.dumps(request)) > 4096:
                raise ValueError("invalid router request")
            result = guest_request(config, request)
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
