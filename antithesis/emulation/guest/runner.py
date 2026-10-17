"""Real QEMU TCG guest adapter for the Antithesis harness.

This process is a local, privileged harness helper. Its JSON configuration is
produced by the harness, never by guest or control-plane peer data.
"""

import argparse
import fcntl
import hashlib
import ipaddress
import json
import os
import re
import signal
import socket
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import TypedDict

MAX_EPOCH = 9_223_372_036_854_775_807
MIN_DISK = 2_147_483_648
UUID_PATTERN = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")


class ProcessRecord(TypedDict):
    pid: int
    start_ticks: int
    executable: str


class LaunchRecord(TypedDict):
    placement_id: str
    execution_epoch: int
    generation: int
    boot_challenge: str
    address: str
    tap: str
    mac: str
    qemu: ProcessRecord
    backend: ProcessRecord


class Observation(TypedDict):
    state: str
    placement_id: str
    execution_epoch: int
    generation: int
    boot_id: str | None
    qemu_pid: int | None
    backend_pid: int | None
    ready: bool
    qemu_rss_kib: int | None
    backend_rss_kib: int | None
    error: str | None


def network_identity(placement: str, address: str, tap: str, mac: str) -> tuple[str, str | None]:
    """@cc [owner:ghuntley,label:security;isolation] emulated-profile-network-identity
    Accepted address, TAP and MAC MUST exactly match Network.Guest.new/3 for
    this placement and an allocatable profile slot. An invalid combination
    MUST fail before privileged TAP or QEMU effects.
    """
    if not UUID_PATTERN.fullmatch(placement):
        raise ValueError("invalid guest network placement")
    try:
        parsed = ipaddress.IPv4Address(address)
    except ipaddress.AddressValueError as error:
        raise ValueError("invalid guest network address") from error
    first, profile, high, low = parsed.packed
    slot = high * 256 + low
    if first != 10 or profile not in (10, 20, 30, 40) or not 2 <= slot <= 65534:
        raise ValueError("invalid guest network address")
    expected_tap = "lv" + hashlib.sha256(placement.encode("ascii")).hexdigest()[:12]
    expected_mac = f"02:fc:0a:{profile:02x}:{high:02x}:{low:02x}"
    if address != str(parsed) or tap != expected_tap or mac != expected_mac:
        raise ValueError("guest network identity mismatch")
    gateway = f"10.{profile}.0.1"
    paired = f"10.41.{high}.{low}" if profile == 40 else None
    return gateway, paired


@dataclass(frozen=True)
class Config:
    image_dir: Path
    state_dir: Path
    socket_dir: Path
    placement_id: str
    execution_epoch: int
    generation: int
    boot_challenge: str
    address: str
    tap: str
    mac: str
    disk_bytes: int
    qemu: Path
    qemu_img: Path
    backend: Path
    ip: Path

    @classmethod
    def from_json(cls, source: Path) -> "Config":
        return cls.from_object(json.loads(source.read_text(encoding="utf-8")))

    @classmethod
    def from_object(cls, raw: object) -> "Config":
        """@cc [owner:ghuntley,label:security] closed-emulator-configuration
        The adapter MUST reject unknown fields and malformed boot, network,
        storage or executable inputs before any host side effect.
        """
        if not isinstance(raw, dict) or set(raw) != {
            "image_dir",
            "state_dir",
            "socket_dir",
            "placement_id",
            "execution_epoch",
            "generation",
            "boot_challenge",
            "address",
            "tap",
            "mac",
            "disk_bytes",
            "qemu",
            "qemu_img",
            "backend",
            "ip",
        }:
            raise ValueError("invalid guest configuration fields")

        def string(name: str) -> str:
            value = raw[name]
            if not isinstance(value, str):
                raise ValueError(f"invalid {name}")
            return value

        def path(name: str) -> Path:
            value = Path(string(name))
            if not value.is_absolute() or ".." in value.parts:
                raise ValueError(f"invalid {name}")
            return value

        def positive(name: str) -> int:
            value = raw[name]
            if type(value) is not int or not 1 <= value <= MAX_EPOCH:
                raise ValueError(f"invalid {name}")
            return value

        placement = string("placement_id")
        challenge = string("boot_challenge")
        address = string("address")
        tap = string("tap")
        mac = string("mac")
        if not UUID_PATTERN.fullmatch(placement) or not re.fullmatch(r"[0-9a-f]{64}", challenge):
            raise ValueError("invalid boot identity")
        network_identity(placement, address, tap, mac)
        disk_bytes = positive("disk_bytes")
        if disk_bytes < MIN_DISK:
            raise ValueError("disk is too small")
        sockets = path("socket_dir")
        if len(os.fsencode(sockets / "vhost.sock")) >= 108:
            raise ValueError("socket path is too long")

        image = path("image_dir")
        if not image.is_dir():
            raise ValueError("image directory is missing")

        def executable(name: str) -> Path:
            value = path(name)
            if not value.is_file() or not os.access(value, os.X_OK):
                raise ValueError(f"invalid {name} executable")
            return value

        return cls(
            image_dir=image,
            state_dir=path("state_dir"),
            socket_dir=sockets,
            placement_id=placement,
            execution_epoch=positive("execution_epoch"),
            generation=positive("generation"),
            boot_challenge=challenge,
            address=address,
            tap=tap,
            mac=mac,
            disk_bytes=disk_bytes,
            qemu=executable("qemu"),
            qemu_img=executable("qemu_img"),
            backend=executable("backend"),
            ip=executable("ip"),
        )


def write_json(path: Path, value: object) -> None:
    temporary = path.with_name(path.name + ".new")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(value, output, sort_keys=True, separators=(",", ":"))
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def event(config: Config, name: str) -> None:
    with (config.state_dir / "effects.jsonl").open("a", encoding="ascii") as output:
        output.write(
            json.dumps(
                {"effect": name, "epoch": config.execution_epoch, "generation": config.generation},
                separators=(",", ":"),
            )
            + "\n"
        )
        output.flush()
        os.fsync(output.fileno())


def load_object(path: Path) -> dict[str, object]:
    value: object = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("invalid state record")
    return value


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validated_image(config: Config) -> dict[str, object]:
    """@cc [owner:ghuntley,label:build;storage] exact-guest-image-before-overlay
    A new writable overlay MUST be based on the real immutable image whose
    kernel, initrd and raw rootfs match the version-4 manifest bytes and hashes.
    """
    manifest = load_object(config.image_dir / "manifest.json")
    if manifest.get("version") != 4 or manifest.get("architecture") != "x86_64":
        raise ValueError("unsupported guest image")
    boot_args = manifest.get("boot_args")
    if not isinstance(boot_args, str):
        raise ValueError("missing image boot arguments")
    if "pci=off" in boot_args.split():
        raise ValueError("image does not support q35 PCI")
    minimum = manifest.get("minimum_disk_bytes")
    if type(minimum) is not int or config.disk_bytes < minimum:
        raise ValueError("disk below image minimum")
    for name, filename in (("kernel", "kernel"), ("initrd", "initrd"), ("rootfs", "rootfs.ext4")):
        expected = manifest.get(name)
        target = config.image_dir / filename
        if (
            not isinstance(expected, dict)
            or type(expected.get("bytes")) is not int
            or not isinstance(expected.get("sha256"), str)
            or target.stat().st_size != expected["bytes"]
            or hash_file(target) != expected["sha256"]
        ):
            raise ValueError(f"invalid {name} artifact")
    return manifest


def command(arguments: list[str], timeout: float = 15) -> str:
    completed = subprocess.run(
        arguments,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=True,
    )
    if len(completed.stdout) > 65536:
        raise ValueError("oversized command result")
    return completed.stdout


def ensure_overlay(config: Config) -> dict[str, object]:
    overlay = config.state_dir / "rootfs.qcow2"
    image_record = config.state_dir / "image.json"
    backing = (config.image_dir / "rootfs.ext4").resolve(strict=True)
    expected_record = {
        "image_dir": str(config.image_dir.resolve()),
        "disk_bytes": config.disk_bytes,
        "manifest_sha256": hash_file(config.image_dir / "manifest.json"),
    }
    if overlay.exists() or image_record.exists():
        if not overlay.is_file() or not image_record.is_file():
            raise ValueError("retained overlay incomplete")
        record = load_object(image_record)
        if record != expected_record:
            raise ValueError("retained overlay image changed")
    else:
        manifest = validated_image(config)
        command(
            [
                str(config.qemu_img),
                "create",
                "-f",
                "qcow2",
                "-F",
                "raw",
                "-b",
                str(backing),
                str(overlay),
                str(config.disk_bytes),
            ],
            60,
        )
        info = load_image_info(config, overlay)
        if info.get("backing-filename") != str(backing):
            raise ValueError("overlay backing mismatch")
        write_json(image_record, expected_record)
        event(config, "overlay_created")
        return manifest
    info = load_image_info(config, overlay)
    if info.get("backing-filename") != str(backing):
        raise ValueError("retained overlay backing mismatch")
    return load_object(config.image_dir / "manifest.json")


def image_binding_matches(config: Config) -> bool:
    """@cc [owner:ghuntley,label:build;recovery] observed-guest-image-binding
    A live guest observation MUST NOT claim readiness when its retained overlay
    was created for a different immutable image manifest or disk shape.
    """
    if not (config.state_dir / "rootfs.qcow2").is_file():
        return False
    try:
        record = load_object(config.state_dir / "image.json")
        return record == {
            "image_dir": str(config.image_dir.resolve()),
            "disk_bytes": config.disk_bytes,
            "manifest_sha256": hash_file(config.image_dir / "manifest.json"),
        }
    except (OSError, ValueError):
        return False


def load_image_info(config: Config, overlay: Path) -> dict[str, object]:
    value: object = json.loads(
        command([str(config.qemu_img), "info", "--output=json", str(overlay)])
    )
    if (
        not isinstance(value, dict)
        or value.get("format") != "qcow2"
        or value.get("backing-filename-format") != "raw"
        or value.get("virtual-size") != config.disk_bytes
    ):
        raise ValueError("invalid overlay metadata")
    return value


def proc_stat(pid: int) -> tuple[str, int] | None:
    try:
        body = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
        fields = body[body.rfind(")") + 2 :].split()
        return fields[0], int(fields[19])
    except FileNotFoundError:
        return None
    except (ValueError, IndexError) as error:
        raise RuntimeError("malformed process observation") from error


def process_record(pid: int, executable: Path) -> ProcessRecord:
    stat = proc_stat(pid)
    if stat is None:
        raise RuntimeError("launched process exited")
    return {"pid": pid, "start_ticks": stat[1], "executable": str(executable.resolve())}


def process_live(value: object) -> bool:
    """@cc [owner:ghuntley,label:recovery] pinned-qemu-wrapper-identity
    A live process MUST match its recorded PID and start tick, and its executable
    MUST be the pinned path or QEMU's exact sibling Nix wrapped executable.
    Other executable changes MUST NOT establish continued guest ownership.
    """
    if not isinstance(value, dict):
        return False
    pid, ticks, executable = value.get("pid"), value.get("start_ticks"), value.get("executable")
    if type(pid) is not int or type(ticks) is not int or not isinstance(executable, str):
        return False
    stat = proc_stat(pid)
    if stat is None or stat[0] == "Z":
        return False
    try:
        observed_exe = os.readlink(f"/proc/{pid}/exe")
    except FileNotFoundError:
        return False
    wrapped_qemu = Path(executable).name == "qemu-system-x86_64" and observed_exe == str(
        Path(executable).with_name(".qemu-system-x86_64-wrapped")
    )
    return stat[1] == ticks and (observed_exe == executable or wrapped_qemu)


def record_matches(value: object, executable: Path) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == {"pid", "start_ticks", "executable"}
        and type(value["pid"]) is int
        and value["pid"] > 1
        and type(value["start_ticks"]) is int
        and value["start_ticks"] > 0
        and value["executable"] == str(executable.resolve())
    )


def rss_kib(value: object) -> int | None:
    if not process_live(value) or not isinstance(value, dict):
        return None
    pid = value["pid"]
    try:
        for line in Path(f"/proc/{pid}/status").read_text(encoding="ascii").splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return None


def ensure_network(config: Config) -> None:
    """@cc [owner:ghuntley,label:isolation] exact-profile-tap
    The emulator TAP MUST have only its validated profile gateway /32 and
    routes to this guest's profile /32 addresses. Network setup failures MUST
    prevent VM launch.
    """
    gateway, paired = network_identity(config.placement_id, config.address, config.tap, config.mac)
    if tap_exists(config):
        raise ValueError("TAP already exists; ownership is uncertain")
    command([str(config.ip), "tuntap", "add", "dev", config.tap, "mode", "tap"])
    try:
        command([str(config.ip), "addr", "add", gateway + "/32", "dev", config.tap])
        command([str(config.ip), "link", "set", "dev", config.tap, "up"])
        command(
            [
                str(config.ip),
                "route",
                "add",
                config.address + "/32",
                "dev",
                config.tap,
                "scope",
                "link",
            ]
        )
        if paired is not None:
            command(
                [str(config.ip), "route", "add", paired + "/32", "dev", config.tap, "scope", "link"]
            )
    except (OSError, ValueError, subprocess.SubprocessError):
        command([str(config.ip), "link", "del", "dev", config.tap])
        raise
    event(config, "tap_created")


def tap_exists(config: Config) -> bool:
    result = subprocess.run(
        [str(config.ip), "link", "show", "dev", config.tap],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=3,
        check=False,
    )
    return result.returncode == 0


def wait_socket(path: Path, process: subprocess.Popen[bytes], deadline: float) -> None:
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("vsock backend exited before socket was ready")
        if path.is_socket():
            return
        time.sleep(0.05)
    raise TimeoutError("vsock backend socket timeout")


def spawn(arguments: list[str], log: Path) -> subprocess.Popen[bytes]:
    with log.open("ab", buffering=0) as output:
        return subprocess.Popen(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=output,
            start_new_session=True,
        )


def start(config: Config, manifest: dict[str, object]) -> LaunchRecord:
    """@cc [owner:ghuntley,label:recovery] launch-attempt-before-process
    A fresh physical boot MUST durably record its exact tuple and launch
    attempt before either backend or QEMU is spawned. An uncertain attempt
    MUST refuse replay rather than create a second guest for one placement.
    """
    launch_path = config.state_dir / "launch.json"
    attempt_path = config.state_dir / "launch-attempt.json"
    if launch_path.exists() or attempt_path.exists():
        raise ValueError("launch already attempted; observe or stop first")
    if tap_exists(config):
        raise ValueError("TAP already exists; refusing uncertain launch")
    config.socket_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if any((config.socket_dir / name).exists() for name in ("vhost.sock", "v.sock")):
        raise ValueError("vsock socket already exists; refusing uncertain launch")
    boot_args = manifest.get("boot_args")
    if not isinstance(boot_args, str):
        raise ValueError("missing boot arguments")
    if any(field.startswith("lilly.") for field in boot_args.split()):
        raise ValueError("image boot arguments contain a placement override")
    full_args = (
        boot_args
        + " lilly.ipv4="
        + config.address
        + " lilly.placement="
        + config.placement_id
        + " lilly.execution_epoch="
        + str(config.execution_epoch)
        + " lilly.boot_challenge="
        + config.boot_challenge
    )
    if len(full_args) > 4096:
        raise ValueError("boot arguments exceed guest identity limit")
    write_json(
        attempt_path,
        {
            "placement_id": config.placement_id,
            "execution_epoch": config.execution_epoch,
            "generation": config.generation,
            "boot_challenge": config.boot_challenge,
        },
    )
    event(config, "launch_attempted")
    try:
        ensure_network(config)
    except (OSError, ValueError, subprocess.SubprocessError):
        if not tap_exists(config):
            attempt_path.unlink()
            event(config, "network_setup_refused")
        raise
    backend = spawn(
        [
            str(config.backend),
            "--guest-cid=3",
            f"--socket={config.socket_dir / 'vhost.sock'}",
            f"--uds-path={config.socket_dir / 'v.sock'}",
            f"--groups={config.placement_id}",
        ],
        config.state_dir / "backend.log",
    )
    partial_path = config.state_dir / "partial-launch.json"
    partial: dict[str, object] = {"backend": process_record(backend.pid, config.backend)}
    write_json(partial_path, partial)
    wait_socket(config.socket_dir / "vhost.sock", backend, time.monotonic() + 15)
    qemu = spawn(
        [
            str(config.qemu),
            "-machine",
            "q35,memory-backend=guestmem",
            "-accel",
            "tcg,thread=single",
            "-cpu",
            "max",
            "-smp",
            "1",
            "-m",
            "2048",
            "-object",
            "memory-backend-memfd,id=guestmem,size=2147483648,share=on",
            "-kernel",
            str(config.image_dir / "kernel"),
            "-initrd",
            str(config.image_dir / "initrd"),
            "-append",
            full_args,
            "-drive",
            f"if=none,id=root,file={config.state_dir / 'rootfs.qcow2'},format=qcow2,cache=writeback,aio=threads,discard=ignore",
            "-device",
            "virtio-blk-pci,drive=root",
            "-netdev",
            f"tap,id=net0,ifname={config.tap},script=no,downscript=no",
            "-device",
            f"virtio-net-pci,netdev=net0,mac={config.mac}",
            "-chardev",
            f"socket,id=vsock,path={config.socket_dir / 'vhost.sock'}",
            "-device",
            "vhost-user-vsock-pci,chardev=vsock",
            "-serial",
            f"file:{config.state_dir / 'serial.log'}",
            "-display",
            "none",
            "-monitor",
            "none",
            "-pidfile",
            str(config.state_dir / "qemu.pid"),
            "-no-reboot",
        ],
        config.state_dir / "qemu.log",
    )
    partial["qemu"] = process_record(qemu.pid, config.qemu)
    write_json(partial_path, partial)
    launch: LaunchRecord = {
        "placement_id": config.placement_id,
        "execution_epoch": config.execution_epoch,
        "generation": config.generation,
        "boot_challenge": config.boot_challenge,
        "address": config.address,
        "tap": config.tap,
        "mac": config.mac,
        "qemu": process_record(qemu.pid, config.qemu),
        "backend": process_record(backend.pid, config.backend),
    }
    write_json(launch_path, launch)
    partial_path.unlink()
    event(config, "processes_started")
    return launch


def read_line(connection: socket.socket, maximum: int) -> bytes:
    body = bytearray()
    while len(body) <= maximum:
        piece = connection.recv(1)
        if not piece:
            break
        body.extend(piece)
        if piece == b"\n":
            break
    if len(body) > maximum or not body.endswith(b"\n"):
        raise ValueError("invalid vsock response length")
    return bytes(body)


def probe_ready(config: Config) -> str | None:
    """@cc [owner:ghuntley,label:security;recovery] real-boot-readiness-only
    Ready MUST require live QEMU/backend identities and the real guest's closed
    port-1024 response matching this placement, epoch and challenge. A serial
    marker, socket connection or saved response MUST NOT imply readiness.
    """
    try:
        if not image_binding_matches(config):
            return None
        launch = load_object(config.state_dir / "launch.json")
        if (
            launch.get("placement_id") != config.placement_id
            or launch.get("execution_epoch") != config.execution_epoch
            or launch.get("generation") != config.generation
            or launch.get("boot_challenge") != config.boot_challenge
            or launch.get("address") != config.address
            or launch.get("tap") != config.tap
            or launch.get("mac") != config.mac
        ):
            return None
        if not process_live(launch.get("qemu")) or not process_live(launch.get("backend")):
            return None
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(3)
            connection.connect(str(config.socket_dir / "v.sock"))
            connection.sendall(b"CONNECT 1024\n")
            handshake = read_line(connection, 32)
            if not re.fullmatch(rb"OK [1-9][0-9]{0,9}\n", handshake):
                return None
            if int(handshake[3:-1]) > 4_294_967_295:
                return None
            raw = read_line(connection, 512)
        value: object = json.loads(raw)
        if not isinstance(value, dict) or set(value) != {
            "version",
            "state",
            "placement_id",
            "execution_epoch",
            "boot_challenge",
            "boot_id",
        }:
            return None
        if (
            type(value["version"]) is not int
            or value["version"] != 1
            or value["state"] != "ready"
            or value["placement_id"] != config.placement_id
            or type(value["execution_epoch"]) is not int
            or value["execution_epoch"] != config.execution_epoch
            or value["boot_challenge"] != config.boot_challenge
        ):
            return None
        boot_id = value["boot_id"]
        return boot_id if isinstance(boot_id, str) and UUID_PATTERN.fullmatch(boot_id) else None
    except (OSError, ValueError, TimeoutError):
        return None


def observe(config: Config) -> Observation:
    launch_path = config.state_dir / "launch.json"
    launch = load_object(launch_path) if launch_path.exists() else {}
    qemu = launch.get("qemu")
    backend = launch.get("backend")
    valid_records = not launch_path.exists() or (
        record_matches(qemu, config.qemu) and record_matches(backend, config.backend)
    )
    qemu_live, backend_live = process_live(qemu), process_live(backend)
    image_bound = image_binding_matches(config) if launch_path.exists() else True
    matching = (
        launch.get("placement_id") == config.placement_id
        and launch.get("execution_epoch") == config.execution_epoch
        and launch.get("generation") == config.generation
        and launch.get("boot_challenge") == config.boot_challenge
        and launch.get("address") == config.address
        and launch.get("tap") == config.tap
        and launch.get("mac") == config.mac
    )
    boot_id = (
        probe_ready(config) if qemu_live and backend_live and matching and image_bound else None
    )
    state = "running" if qemu_live and backend_live and matching and image_bound else "stopped"
    if not valid_records or (launch_path.exists() and (not matching or not image_bound)):
        state = "uncertain"
    elif qemu_live != backend_live:
        state = "degraded"
    elif (config.state_dir / "launch-attempt.json").exists() and not launch:
        state = "uncertain"
    return {
        "state": state,
        "placement_id": config.placement_id,
        "execution_epoch": config.execution_epoch,
        "generation": config.generation,
        "boot_id": boot_id,
        "qemu_pid": qemu["pid"] if qemu_live and isinstance(qemu, dict) else None,
        "backend_pid": backend["pid"] if backend_live and isinstance(backend, dict) else None,
        "ready": boot_id is not None,
        "qemu_rss_kib": rss_kib(qemu),
        "backend_rss_kib": rss_kib(backend),
        "error": None,
    }


def terminate(value: object) -> None:
    if not process_live(value) or not isinstance(value, dict):
        return
    pid = value["pid"]
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 10
    while process_live(value) and time.monotonic() < deadline:
        time.sleep(0.05)
    if process_live(value):
        os.kill(pid, signal.SIGKILL)
    deadline = time.monotonic() + 5
    while process_live(value) and time.monotonic() < deadline:
        time.sleep(0.05)
    if process_live(value):
        raise RuntimeError("guest process exit unconfirmed")


# @cc [owner:ghuntley,label:recovery;security] exact-boot-stop-fence
# Stop MUST refuse a launch whose placement, epoch, generation or challenge
# differs from the requested boot before terminating either process.
def stop(config: Config) -> Observation:
    """@cc [owner:ghuntley,label:storage;recovery] retained-disk-after-exit
    Stop MUST confirm both recorded processes have exited before removing TAP
    or launch markers. It MUST retain the placement's qcow2 overlay and fsync
    an exact private stopped-boot identity record before removing launch state.
    """
    launch_path = config.state_dir / "launch.json"
    stopped_path = config.state_dir / "stopped.json"
    partial_path = config.state_dir / "partial-launch.json"
    attempt_path = config.state_dir / "launch-attempt.json"
    if attempt_path.exists():
        attempt = load_object(attempt_path)
        if attempt != {
            "placement_id": config.placement_id,
            "execution_epoch": config.execution_epoch,
            "generation": config.generation,
            "boot_challenge": config.boot_challenge,
        }:
            raise ValueError("foreign launch attempt")
    if launch_path.exists():
        launch = load_object(launch_path)
        if (
            launch.get("placement_id") != config.placement_id
            or launch.get("execution_epoch") != config.execution_epoch
            or launch.get("generation") != config.generation
            or launch.get("boot_challenge") != config.boot_challenge
            or launch.get("address") != config.address
            or launch.get("tap") != config.tap
            or launch.get("mac") != config.mac
        ):
            raise ValueError("foreign launch record")
        if not record_matches(launch.get("qemu"), config.qemu) or not record_matches(
            launch.get("backend"), config.backend
        ):
            raise ValueError("invalid process identity record")
        terminate(launch.get("qemu"))
        terminate(launch.get("backend"))
        if process_live(launch.get("qemu")) or process_live(launch.get("backend")):
            raise RuntimeError("guest process exit unconfirmed")
        if not image_binding_matches(config):
            raise ValueError("retained overlay image mismatch")
        write_json(
            stopped_path,
            {
                "placement_id": config.placement_id,
                "execution_epoch": config.execution_epoch,
                "generation": config.generation,
                "boot_challenge": config.boot_challenge,
                "address": config.address,
                "tap": config.tap,
                "mac": config.mac,
                "qemu": launch["qemu"],
                "backend": launch["backend"],
                "manifest_sha256": hash_file(config.image_dir / "manifest.json"),
                "disk_bytes": config.disk_bytes,
            },
        )
        launch_path.unlink()
    elif partial_path.exists():
        partial = load_object(partial_path)
        if not record_matches(partial.get("backend"), config.backend) or (
            "qemu" in partial and not record_matches(partial.get("qemu"), config.qemu)
        ):
            raise ValueError("invalid partial process identity")
        if "qemu" not in partial and (config.state_dir / "qemu.pid").exists():
            raise RuntimeError("QEMU may have started without a recorded process identity")
        terminate(partial.get("qemu"))
        terminate(partial.get("backend"))
        partial_path.unlink()
    elif attempt_path.exists():
        raise RuntimeError("uncertain launch has no process identities")
    elif stopped_path.exists():
        retained = load_object(stopped_path)
        if (
            retained.get("placement_id") != config.placement_id
            or retained.get("execution_epoch") != config.execution_epoch
            or retained.get("generation") != config.generation
            or retained.get("boot_challenge") != config.boot_challenge
            or retained.get("address") != config.address
            or retained.get("tap") != config.tap
            or retained.get("mac") != config.mac
        ):
            raise ValueError("foreign stopped boot record")
    elif tap_exists(config):
        raise RuntimeError("untracked TAP requires owner investigation")
    if tap_exists(config):
        command([str(config.ip), "link", "del", "dev", config.tap])
    for name in ("vhost.sock", "v.sock"):
        (config.socket_dir / name).unlink(missing_ok=True)
    attempt_path.unlink(missing_ok=True)
    (config.state_dir / "qemu.pid").unlink(missing_ok=True)
    event(config, "processes_stopped")
    return observe(config)


def reconcile(config: Config) -> Observation:
    current = observe(config)
    if current["state"] == "running":
        return current
    if current["state"] != "stopped" or (config.state_dir / "launch-attempt.json").exists():
        raise RuntimeError("uncertain or degraded guest requires explicit stop")
    if (config.state_dir / "launch.json").exists():
        raise RuntimeError("previous launch requires explicit stop")
    manifest = ensure_overlay(config)
    start(config, manifest)
    return observe(config)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("reconcile", "observe", "stop", "readiness"))
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=0)
    arguments = parser.parse_args()
    try:
        config = Config.from_json(arguments.config)
        config.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        if arguments.operation in ("reconcile", "stop"):
            with (config.state_dir / ".lock").open("a+b") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                result = reconcile(config) if arguments.operation == "reconcile" else stop(config)
        elif arguments.operation == "readiness":
            if not 0 <= arguments.timeout <= 2400:
                raise ValueError("invalid readiness timeout")
            deadline = time.monotonic() + arguments.timeout
            result = observe(config)
            while not result["ready"] and time.monotonic() < deadline:
                time.sleep(0.1)
                result = observe(config)
        else:
            result = observe(config)
        print(json.dumps(result, separators=(",", ":")))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps({"state": "error", "error": str(error)}, separators=(",", ":")))
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
