"""Closed Unix-socket control plane for the real QEMU TCG guest runner."""

import argparse
import contextlib
import fcntl
import hashlib
import hmac
import json
import os
import re
import select
import socket
import stat
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, TypedDict

from runner import (
    MAX_EPOCH,
    UUID_PATTERN,
    Config,
    Observation,
    command,
    hash_file,
    image_binding_matches,
    load_object,
    network_identity,
    observe,
    proc_stat,
    process_live,
    read_line,
    reconcile,
    record_matches,
    stop,
)

MAX_REQUEST_BYTES = 4096
MAX_RESPONSE_BYTES = 16384
MAX_PLACEMENTS = 64
MEMORY_BYTES = 2147483648
MAX_OVERLAY_HASH_BYTES = 8589934592
MAX_OVERLAY_HASH_SECONDS = 30.0
TERMINAL_OBSERVER_PORT = 1076
MAX_TERMINAL_PAYLOAD = 8192


class InventoryEntry(TypedDict):
    placement_id: str
    execution_epoch: int | None
    generation: int | None
    state: str
    live: bool
    overlay_present: bool
    qemu_pid: int | None
    backend_pid: int | None


class ProcessWitness(TypedDict):
    pid: int
    start_ticks: int


class ProcessProof(TypedDict):
    state: Literal["running", "qemu_exited"]
    placement_id: str
    execution_epoch: int
    generation: int
    qemu_pid: int
    qemu_start_ticks: int
    backend_pid: int | None
    backend_start_ticks: int | None


class Witness(TypedDict):
    state: str
    guest_state: str
    placement_id: str
    execution_epoch: int | None
    generation: int | None
    boot_id: str | None
    ready: bool
    qemu: ProcessWitness | None
    backend: ProcessWitness | None
    boot_challenge_sha256: str | None
    image_manifest_sha256: str
    overlay_present: bool
    overlay_bytes: int | None
    overlay_sha256: str | None


class TerminalViewer(TypedDict):
    queue_bytes: int
    blocked_write: bool


class TerminalSession(TypedDict):
    session_id: int
    pid: int
    proc_start_ticks: int
    alive: bool
    ring_base: int
    ring_tail: int
    ring_limit: int
    deque_allocated: int
    viewers: list[TerminalViewer]


class TerminalSnapshot(TypedDict):
    state: str
    version: int
    births: int
    deaths: int
    ring_total: int
    viewer_total: int
    daemon_pid: int
    daemon_start_ticks: int
    sessions: list[TerminalSession]
    ledger_digests: list[str]


class TerminalInputStall(TypedDict):
    state: str
    version: int
    session_id: int
    pid: int
    in_progress: bool
    elapsed_ms: int


@dataclass(frozen=True)
class ToolConfig:
    image_dir: Path
    qemu: Path
    qemu_img: Path
    backend: Path
    ip: Path

    @classmethod
    def load(cls, path: Path) -> "ToolConfig":
        """@cc [owner:ghuntley,label:security;build] fixed-guest-tools
        The server MUST load the image and executable paths from its pinned
        image configuration, never from an RPC request.
        """
        raw: object = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(raw, dict) or set(raw) != {
            "image_dir",
            "qemu",
            "qemu_img",
            "backend",
            "ip",
        }:
            raise ValueError("invalid tool configuration")

        def store_path(name: str) -> Path:
            value = raw[name]
            if not isinstance(value, str):
                raise ValueError("invalid tool configuration")
            candidate = Path(value)
            if not candidate.is_absolute() or ".." in candidate.parts:
                raise ValueError("invalid tool configuration")
            if not candidate.is_relative_to("/nix/store"):
                raise ValueError("tool path is outside the immutable store")
            return candidate

        result = cls(
            image_dir=store_path("image_dir"),
            qemu=store_path("qemu"),
            qemu_img=store_path("qemu_img"),
            backend=store_path("backend"),
            ip=store_path("ip"),
        )
        if not result.image_dir.is_dir() or any(
            not tool.is_file() or not os.access(tool, os.X_OK)
            for tool in (result.qemu, result.qemu_img, result.backend, result.ip)
        ):
            raise ValueError("missing pinned guest tools")
        return result


@dataclass(frozen=True)
class GuestRequest:
    operation: str
    placement_id: str
    execution_epoch: int
    generation: int
    boot_challenge: str
    address: str
    tap: str
    mac: str
    disk_bytes: int

    @classmethod
    def parse(cls, raw: object) -> "GuestRequest":
        """@cc [owner:ghuntley,label:security] closed-guest-rpc
        A guest RPC MUST contain only the fixed operation and boot fields.
        It MUST NOT select paths, tools, shell commands, QMP or a ready result.
        """
        expected = {
            "operation",
            "placement_id",
            "execution_epoch",
            "generation",
            "boot_challenge",
            "address",
            "tap",
            "mac",
            "disk_bytes",
        }
        if not isinstance(raw, dict) or set(raw) != expected:
            raise ValueError("invalid guest request")

        def string(name: str) -> str:
            value = raw[name]
            if not isinstance(value, str):
                raise ValueError("invalid guest request")
            return value

        def positive(name: str) -> int:
            value = raw[name]
            if type(value) is not int or not 1 <= value <= MAX_EPOCH:
                raise ValueError("invalid guest request")
            return value

        operation = string("operation")
        if operation not in {"reconcile", "observe", "readiness", "stop", "process_proof"}:
            raise ValueError("invalid guest operation")
        return cls(
            operation=operation,
            placement_id=string("placement_id"),
            execution_epoch=positive("execution_epoch"),
            generation=positive("generation"),
            boot_challenge=string("boot_challenge"),
            address=string("address"),
            tap=string("tap"),
            mac=string("mac"),
            disk_bytes=positive("disk_bytes"),
        )


def image_identity(image_dir: Path) -> dict[str, object]:
    """@cc [owner:ghuntley,label:protocol;build] protocol-image-identity
    Identity MUST use the ordered v4 fields from ImageManifest.validate/1.
    A malformed manifest MUST NOT be advertised as a runnable image.
    """
    manifest = load_object(image_dir / "manifest.json")
    keys = {
        "version",
        "architecture",
        "boot_args",
        "minimum_memory_bytes",
        "minimum_disk_bytes",
        "workspace_source_version",
        "kernel",
        "initrd",
        "rootfs",
    }
    editor: list[object] | None = None
    if "editor" in manifest:
        keys.add("editor")
        descriptor = manifest["editor"]
        if not isinstance(descriptor, dict) or set(descriptor) != {"protocol", "commit", "release"}:
            raise ValueError("invalid image manifest")
        commit, release = descriptor["commit"], descriptor["release"]
        if (
            type(descriptor["protocol"]) is not int
            or descriptor["protocol"] != 1
            or not isinstance(commit, str)
            or not re.fullmatch(r"[0-9a-f]{40}", commit)
            or not isinstance(release, str)
            or not re.fullmatch(r"[0-9a-f]{64}", release)
        ):
            raise ValueError("invalid image manifest")
        editor = [1, commit, release]
    if (
        set(manifest) != keys
        or manifest.get("version") != 4
        or manifest.get("architecture") != "x86_64"
    ):
        raise ValueError("invalid image manifest")
    boot = manifest["boot_args"]
    memory = manifest["minimum_memory_bytes"]
    disk = manifest["minimum_disk_bytes"]
    source = manifest["workspace_source_version"]
    if (
        not isinstance(boot, str)
        or not 1 <= len(boot.encode("utf-8")) <= 2048
        or any(character in boot for character in "\x00\n\r")
        or type(memory) is not int
        or not 536870912 <= memory <= 274877906944
        or type(disk) is not int
        or not 1 <= disk <= 17592186044416
        or source not in (None, 2)
        or memory > MEMORY_BYTES
    ):
        raise ValueError("invalid image manifest")

    artifacts: list[list[object]] = []
    for name, maximum in (("kernel", 8589934592), ("initrd", 8589934592), ("rootfs", 137438953472)):
        descriptor = manifest[name]
        if not isinstance(descriptor, dict) or set(descriptor) != {"bytes", "sha256"}:
            raise ValueError("invalid image manifest")
        size, digest = descriptor["bytes"], descriptor["sha256"]
        if (
            type(size) is not int
            or not 1 <= size <= maximum
            or not isinstance(digest, str)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
        ):
            raise ValueError("invalid image manifest")
        if name == "rootfs" and disk < size:
            raise ValueError("invalid image manifest")
        artifacts.append([size, digest])
    identity = ["lilly-image-v4", "x86_64", boot, memory, disk, source, editor, *artifacts]
    encoded = json.dumps(identity, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return {
        "state": "ok",
        "image_id": "sha256:" + hashlib.sha256(encoded).hexdigest(),
        "minimum_disk_bytes": disk,
        "memory_bytes": MEMORY_BYTES,
        "vcpu": 1,
        "workspace_source_version": source,
    }


def guest_config(
    request: GuestRequest, tools: ToolConfig, state_root: Path, socket_root: Path
) -> Config:
    data: dict[str, object] = {
        "image_dir": str(tools.image_dir),
        "state_dir": str(state_root / request.placement_id),
        "socket_dir": str(socket_root / request.placement_id[:8]),
        "placement_id": request.placement_id,
        "execution_epoch": request.execution_epoch,
        "generation": request.generation,
        "boot_challenge": request.boot_challenge,
        "address": request.address,
        "tap": request.tap,
        "mac": request.mac,
        "disk_bytes": request.disk_bytes,
        "qemu": str(tools.qemu),
        "qemu_img": str(tools.qemu_img),
        "backend": str(tools.backend),
        "ip": str(tools.ip),
    }
    return Config.from_object(data)


def inventory(state_root: Path, tools: ToolConfig) -> dict[str, object]:
    """@cc [owner:ghuntley,label:verification;recovery] observed-guest-inventory
    Inventory MUST derive liveness from pinned process identities and retained
    state. Malformed or unrecognized state MUST fail the whole observation.
    """
    directories = sorted(state_root.iterdir())
    identity = image_identity(tools.image_dir)
    minimum_disk = identity["minimum_disk_bytes"]
    if type(minimum_disk) is not int:
        raise ValueError("invalid image identity")
    manifest_sha256 = hash_file(tools.image_dir / "manifest.json")
    if len(directories) > MAX_PLACEMENTS:
        raise ValueError("guest inventory exceeds bound")
    entries: list[InventoryEntry] = []
    for directory in directories:
        if (
            directory.is_symlink()
            or not directory.is_dir()
            or not UUID_PATTERN.fullmatch(directory.name)
        ):
            raise ValueError("invalid guest state directory")
        launch_path = directory / "launch.json"
        attempt_path = directory / "launch-attempt.json"
        partial_path = directory / "partial-launch.json"
        overlay_path = directory / "rootfs.qcow2"
        if overlay_path.is_symlink() or (overlay_path.exists() and not overlay_path.is_file()):
            raise ValueError("invalid guest overlay")
        image_record_path = directory / "image.json"
        if image_record_path.is_symlink():
            raise ValueError("invalid guest image record")
        image_record = load_object(image_record_path) if image_record_path.exists() else {}
        disk_size = image_record.get("disk_bytes")
        bound = (
            type(disk_size) is int
            and disk_size >= minimum_disk
            and image_record
            == {
                "image_dir": str(tools.image_dir.resolve()),
                "disk_bytes": disk_size,
                "manifest_sha256": manifest_sha256,
            }
            and overlay_path.is_file()
        )
        epoch: int | None = None
        generation: int | None = None
        qemu_pid: int | None = None
        backend_pid: int | None = None
        state = "stopped"
        if launch_path.exists():
            launch = load_object(launch_path)
            if (
                set(launch)
                != {
                    "placement_id",
                    "execution_epoch",
                    "generation",
                    "boot_challenge",
                    "address",
                    "tap",
                    "mac",
                    "qemu",
                    "backend",
                }
                or launch["placement_id"] != directory.name
                or type(launch["execution_epoch"]) is not int
                or not 1 <= launch["execution_epoch"] <= MAX_EPOCH
                or type(launch["generation"]) is not int
                or not 1 <= launch["generation"] <= MAX_EPOCH
                or not isinstance(launch["boot_challenge"], str)
                or not re.fullmatch(r"[0-9a-f]{64}", launch["boot_challenge"])
                or not isinstance(launch["address"], str)
                or not isinstance(launch["tap"], str)
                or not isinstance(launch["mac"], str)
                or not record_matches(launch["qemu"], tools.qemu)
                or not record_matches(launch["backend"], tools.backend)
            ):
                raise ValueError("invalid guest launch record")
            network_identity(directory.name, launch["address"], launch["tap"], launch["mac"])
            epoch = launch["execution_epoch"]
            generation = launch["generation"]
            qemu_live = process_live(launch["qemu"])
            backend_live = process_live(launch["backend"])
            if qemu_live and backend_live:
                state = "running"
            elif qemu_live or backend_live:
                state = "degraded"
            else:
                state = "uncertain"
            qemu_record = launch["qemu"]
            backend_record = launch["backend"]
            if qemu_live and isinstance(qemu_record, dict):
                candidate = qemu_record.get("pid")
                qemu_pid = candidate if type(candidate) is int else None
            if backend_live and isinstance(backend_record, dict):
                candidate = backend_record.get("pid")
                backend_pid = candidate if type(candidate) is int else None
            if not bound or partial_path.exists():
                state = "uncertain"
        elif partial_path.exists() or attempt_path.exists():
            state = "uncertain"
        elif (directory / "stopped.json").exists():
            # A stopped placement keeps the boot tuple it last ran, so the
            # executor can bind an accepted stop to that exact boot.
            stopped = load_object(directory / "stopped.json")
            stopped_epoch = stopped.get("execution_epoch")
            stopped_generation = stopped.get("generation")
            if (
                stopped.get("placement_id") == directory.name
                and type(stopped_epoch) is int
                and 1 <= stopped_epoch <= MAX_EPOCH
                and type(stopped_generation) is int
                and 1 <= stopped_generation <= MAX_EPOCH
            ):
                epoch = stopped_epoch
                generation = stopped_generation
            else:
                state = "uncertain"
        if state == "stopped" and overlay_path.is_file():
            if not bound or type(disk_size) is not int:
                raise ValueError("retained overlay image mismatch")
            info: object = json.loads(
                command([str(tools.qemu_img), "info", "--output=json", str(overlay_path)])
            )
            if (
                not isinstance(info, dict)
                or info.get("format") != "qcow2"
                or info.get("backing-filename-format") != "raw"
                or info.get("backing-filename")
                != str((tools.image_dir / "rootfs.ext4").resolve(strict=True))
                or info.get("virtual-size") != disk_size
            ):
                raise ValueError("retained overlay metadata mismatch")
        entries.append(
            {
                "placement_id": directory.name,
                "execution_epoch": epoch,
                "generation": generation,
                "state": state,
                "live": state == "running",
                "overlay_present": overlay_path.is_file(),
                "qemu_pid": qemu_pid,
                "backend_pid": backend_pid,
            }
        )
    return {"state": "ok", "placements": entries}


def health(state_root: Path, tools: ToolConfig) -> dict[str, object]:
    """@cc [owner:ghuntley,label:verification] measured-guest-health
    Health MUST validate the immutable image and full owned inventory and
    fsync a private state-root write before advertising execution readiness.
    Uncertain or degraded guest state MUST fail the health request.
    """
    identity = image_identity(tools.image_dir)
    observed = inventory(state_root, tools)
    placements = observed["placements"]
    if not isinstance(placements, list) or any(
        not isinstance(entry, dict) or entry.get("state") not in ("running", "stopped")
        for entry in placements
    ):
        raise ValueError("unhealthy guest inventory")
    with tempfile.TemporaryFile(dir=state_root) as probe:
        probe.write(b"1")
        probe.flush()
        os.fsync(probe.fileno())
    directory_fd = os.open(state_root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    return {
        "state": "ok",
        "image_id": identity["image_id"],
        "inventory_valid": True,
        "state_writable": True,
        "state_root": str(state_root.resolve(strict=True)),
    }


def bounded_overlay_hash(path: Path) -> str | None:
    before = path.stat()
    if before.st_size > MAX_OVERLAY_HASH_BYTES:
        return None
    digest = hashlib.sha256()
    deadline = time.monotonic() + MAX_OVERLAY_HASH_SECONDS
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            if time.monotonic() >= deadline:
                return None
            digest.update(chunk)
    after = path.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        return None
    return digest.hexdigest()


def process_witness(record: object) -> ProcessWitness | None:
    if not process_live(record) or not isinstance(record, dict):
        return None
    pid, ticks = record.get("pid"), record.get("start_ticks")
    if type(pid) is not int or type(ticks) is not int:
        return None
    return {"pid": pid, "start_ticks": ticks}


def process_status(record: object, executable: Path) -> Literal["live", "exited"]:
    """@cc [owner:ghuntley,label:recovery;verification] positive-process-exit
    An exited process MUST be established by absent /proc stat, a zombie, or
    different PID start ticks. A live PID with an unexpected executable or an
    unreadable/malformed observation MUST remain unavailable.
    """
    if not record_matches(record, executable) or not isinstance(record, dict):
        raise ValueError("invalid guest process record")
    pid, ticks = record.get("pid"), record.get("start_ticks")
    if type(pid) is not int or type(ticks) is not int:
        raise ValueError("invalid guest process record")

    def observed_exit() -> bool:
        state = proc_stat(pid)
        return state is None or state[0] == "Z" or state[1] != ticks

    if observed_exit():
        return "exited"
    try:
        observed_executable = os.readlink(f"/proc/{pid}/exe")
    except FileNotFoundError:
        if observed_exit():
            return "exited"
        raise RuntimeError("guest executable observation unavailable") from None
    pinned = str(executable.resolve())
    wrapped_qemu = executable.name == "qemu-system-x86_64" and observed_executable == str(
        executable.with_name(".qemu-system-x86_64-wrapped")
    )
    if observed_executable != pinned and not wrapped_qemu:
        raise ValueError("guest executable identity mismatch")
    if observed_exit():
        return "exited"
    return "live"


def process_proof(config: Config) -> ProcessProof:
    """@cc [owner:ghuntley,label:recovery;verification] exact-boot-process-proof
    A process proof MUST bind the request to the retained live launch tuple,
    challenge, executable identities and image/disk record. QEMU exit MUST
    require positive /proc evidence; uncertain state MUST fail the RPC.
    """
    launch_path = config.state_dir / "launch.json"
    launch = load_object(launch_path)
    if (
        set(launch)
        != {
            "placement_id",
            "execution_epoch",
            "generation",
            "boot_challenge",
            "address",
            "tap",
            "mac",
            "qemu",
            "backend",
        }
        or launch["placement_id"] != config.placement_id
        or launch["execution_epoch"] != config.execution_epoch
        or launch["generation"] != config.generation
        or launch["boot_challenge"] != config.boot_challenge
        or launch["address"] != config.address
        or launch["tap"] != config.tap
        or launch["mac"] != config.mac
        or not image_binding_matches(config)
        or (config.state_dir / "partial-launch.json").exists()
    ):
        raise ValueError("guest process proof boot mismatch")
    qemu, backend = launch["qemu"], launch["backend"]
    qemu_state = process_status(qemu, config.qemu)
    backend_state = process_status(backend, config.backend)
    if qemu_state == "live" and backend_state != "live":
        raise RuntimeError("guest process proof unavailable")
    if load_object(launch_path) != launch or not image_binding_matches(config):
        raise RuntimeError("guest process proof changed")
    if not isinstance(qemu, dict) or not isinstance(backend, dict):
        raise ValueError("invalid guest process proof")
    qemu_pid, qemu_ticks = qemu.get("pid"), qemu.get("start_ticks")
    backend_pid, backend_ticks = backend.get("pid"), backend.get("start_ticks")
    if (
        type(qemu_pid) is not int
        or type(qemu_ticks) is not int
        or type(backend_pid) is not int
        or type(backend_ticks) is not int
    ):
        raise ValueError("invalid guest process proof")
    state: Literal["running", "qemu_exited"] = "running" if qemu_state == "live" else "qemu_exited"
    return {
        "state": state,
        "placement_id": config.placement_id,
        "execution_epoch": config.execution_epoch,
        "generation": config.generation,
        "qemu_pid": qemu_pid,
        "qemu_start_ticks": qemu_ticks,
        "backend_pid": backend_pid if backend_state == "live" else None,
        "backend_start_ticks": backend_ticks if backend_state == "live" else None,
    }


def stopped_record(
    state_dir: Path,
    placement_id: str,
    execution_epoch: int,
    generation: int,
    tools: ToolConfig,
) -> dict[str, object]:
    """@cc [owner:ghuntley,label:recovery;verification] exact-stopped-boot-witness
    A stopped boot MUST bind its private tuple, terminated process identities,
    image manifest, disk shape and retained overlay before yielding evidence.
    An incomplete or stale record MUST be unavailable, not an empty witness.
    """
    if (state_dir / "launch-attempt.json").exists() or (state_dir / "partial-launch.json").exists():
        raise ValueError("uncertain stopped guest")
    record = load_object(state_dir / "stopped.json")
    image_record = load_object(state_dir / "image.json")
    disk_size = record.get("disk_bytes")
    manifest_sha256 = hash_file(tools.image_dir / "manifest.json")
    if (
        set(record)
        != {
            "placement_id",
            "execution_epoch",
            "generation",
            "boot_challenge",
            "address",
            "tap",
            "mac",
            "qemu",
            "backend",
            "manifest_sha256",
            "disk_bytes",
        }
        or record["placement_id"] != placement_id
        or record["execution_epoch"] != execution_epoch
        or record["generation"] != generation
        or not isinstance(record["boot_challenge"], str)
        or not re.fullmatch(r"[0-9a-f]{64}", record["boot_challenge"])
        or not isinstance(record["address"], str)
        or not isinstance(record["tap"], str)
        or not isinstance(record["mac"], str)
        or not record_matches(record["qemu"], tools.qemu)
        or not record_matches(record["backend"], tools.backend)
        or process_live(record["qemu"])
        or process_live(record["backend"])
        or record["manifest_sha256"] != manifest_sha256
        or type(disk_size) is not int
        or image_record
        != {
            "image_dir": str(tools.image_dir.resolve()),
            "disk_bytes": disk_size,
            "manifest_sha256": manifest_sha256,
        }
        or not (state_dir / "rootfs.qcow2").is_file()
        or (state_dir / "rootfs.qcow2").is_symlink()
    ):
        raise ValueError("invalid stopped guest record")
    network_identity(placement_id, record["address"], record["tap"], record["mac"])
    return record


def witness_config(
    placement_id: str,
    execution_epoch: int,
    generation: int,
    tools: ToolConfig,
    state_root: Path,
    socket_root: Path,
) -> Config:
    """@cc [owner:ghuntley,label:verification;security] placement-only-witness
    A read-only witness MUST derive boot and disk inputs from owned state.
    Callers may select a canonical placement, epoch and generation, but no
    challenge or path. A live launch MUST match that requested tuple.
    """
    if (
        not UUID_PATTERN.fullmatch(placement_id)
        or not 1 <= execution_epoch <= MAX_EPOCH
        or not 1 <= generation <= MAX_EPOCH
    ):
        raise ValueError("invalid witness placement")
    state_dir = state_root / placement_id
    if state_dir.is_symlink() or not state_dir.is_dir():
        raise ValueError("unknown witness placement")
    launch_path = state_dir / "launch.json"
    attempt_path = state_dir / "launch-attempt.json"
    overlay_path = state_dir / "rootfs.qcow2"
    if not (launch_path.exists() or attempt_path.exists() or overlay_path.exists()):
        raise ValueError("unknown witness placement")
    boot = (
        load_object(launch_path)
        if launch_path.exists()
        else stopped_record(state_dir, placement_id, execution_epoch, generation, tools)
    )
    if (
        boot.get("placement_id") != placement_id
        or boot.get("execution_epoch") != execution_epoch
        or boot.get("generation") != generation
    ):
        raise ValueError("witness boot tuple mismatch")
    image_record_path = state_dir / "image.json"
    image_record = load_object(image_record_path) if image_record_path.exists() else {}
    disk_size = image_record.get("disk_bytes")
    if type(disk_size) is not int:
        minimum = image_identity(tools.image_dir)["minimum_disk_bytes"]
        if type(minimum) is not int:
            raise ValueError("invalid image identity")
        disk_size = minimum
    data: dict[str, object] = {
        "image_dir": str(tools.image_dir),
        "state_dir": str(state_dir),
        "socket_dir": str(socket_root / placement_id[:8]),
        "placement_id": placement_id,
        "execution_epoch": execution_epoch,
        "generation": generation,
        "boot_challenge": boot["boot_challenge"],
        "address": boot["address"],
        "tap": boot["tap"],
        "mac": boot["mac"],
        "disk_bytes": disk_size,
        "qemu": str(tools.qemu),
        "qemu_img": str(tools.qemu_img),
        "backend": str(tools.backend),
        "ip": str(tools.ip),
    }
    return Config.from_object(data)


def witness(config: Config) -> Witness:
    """@cc [owner:ghuntley,label:verification;security] physical-guest-witness
    A witness MUST derive process ticks and boot challenge digest from the
    retained launch record. Disk bytes may be hashed only after tracked guest
    processes are confirmed absent; uncertain state MUST NOT yield a disk hash.
    """
    current = observe(config)
    launch_path = config.state_dir / "launch.json"
    stopped = not launch_path.exists()
    boot = (
        stopped_record(
            config.state_dir,
            config.placement_id,
            config.execution_epoch,
            config.generation,
            ToolConfig(config.image_dir, config.qemu, config.qemu_img, config.backend, config.ip),
        )
        if stopped
        else load_object(launch_path)
    )
    if (
        boot.get("placement_id") != config.placement_id
        or boot.get("execution_epoch") != config.execution_epoch
        or boot.get("generation") != config.generation
        or boot.get("boot_challenge") != config.boot_challenge
        or boot.get("address") != config.address
        or boot.get("tap") != config.tap
        or boot.get("mac") != config.mac
        or not record_matches(boot.get("qemu"), config.qemu)
        or not record_matches(boot.get("backend"), config.backend)
    ):
        raise ValueError("guest witness tuple mismatch")
    if stopped:
        observed = inventory(
            config.state_dir.parent,
            ToolConfig(config.image_dir, config.qemu, config.qemu_img, config.backend, config.ip),
        )
        entries = observed["placements"]
        if (
            not isinstance(entries, list)
            or not any(
                isinstance(entry, dict)
                and entry.get("placement_id") == config.placement_id
                and entry.get("state") == "stopped"
                and entry.get("overlay_present") is True
                for entry in entries
            )
            or current["state"] != "stopped"
        ):
            raise ValueError("stopped guest overlay unavailable")
    challenge = boot.get("boot_challenge")
    challenge_hash = (
        hashlib.sha256(challenge.encode("ascii")).hexdigest()
        if isinstance(challenge, str)
        else None
    )
    qemu = process_witness(boot.get("qemu"))
    backend = process_witness(boot.get("backend"))
    overlay = config.state_dir / "rootfs.qcow2"
    if overlay.is_symlink():
        raise ValueError("invalid guest overlay")
    present = overlay.is_file()
    overlay_bytes = overlay.stat().st_size if present else None
    safe_to_hash = (
        present
        and current["state"] == "stopped"
        and qemu is None
        and backend is None
        and not (config.state_dir / "launch-attempt.json").exists()
        and not (config.state_dir / "partial-launch.json").exists()
    )
    return {
        "state": "ok",
        "guest_state": current["state"],
        "placement_id": config.placement_id,
        "execution_epoch": config.execution_epoch,
        "generation": config.generation,
        "boot_id": current["boot_id"],
        "ready": current["ready"],
        "qemu": qemu,
        "backend": backend,
        "boot_challenge_sha256": challenge_hash,
        "image_manifest_sha256": hash_file(config.image_dir / "manifest.json"),
        "overlay_present": present,
        "overlay_bytes": overlay_bytes,
        "overlay_sha256": bounded_overlay_hash(overlay) if safe_to_hash else None,
    }


def terminal_frame(operation: int, payload: bytes) -> bytes:
    if not 0 <= operation <= 255 or len(payload) > MAX_TERMINAL_PAYLOAD:
        raise ValueError("invalid terminal observer frame")
    return bytes((0x4C, operation)) + len(payload).to_bytes(2, "big") + payload


def receive_exact(connection: socket.socket, length: int) -> bytes:
    if not 0 <= length <= MAX_TERMINAL_PAYLOAD:
        raise ValueError("invalid terminal observer length")
    body = bytearray()
    while len(body) < length:
        chunk = connection.recv(length - len(body))
        if not chunk:
            raise RuntimeError("terminal observer response unavailable")
        body.extend(chunk)
    return bytes(body)


def terminal_reply(connection: socket.socket) -> bytes:
    header = receive_exact(connection, 4)
    if header[:2] != b"\x4c\x80":
        raise ValueError("invalid terminal observer response")
    length = int.from_bytes(header[2:4], "big")
    return receive_exact(connection, length)


def terminal_probe(config: Config, operation: int, payload: bytes) -> bytes:
    """@cc [owner:ghuntley,label:security;verification] fixed-terminal-observer-route
    Terminal observations MUST use only pinned guest vsock port 1076 after
    exact live boot readiness and current challenge HMAC proof. Unknown or
    malformed replies MUST fail, never become an empty snapshot.
    """
    current = observe(config)
    if current["state"] != "running" or not current["ready"]:
        raise RuntimeError("guest not ready for terminal observation")
    launch = load_object(config.state_dir / "launch.json")
    challenge = launch.get("boot_challenge")
    if (
        launch.get("placement_id") != config.placement_id
        or launch.get("execution_epoch") != config.execution_epoch
        or launch.get("generation") != config.generation
        or launch.get("address") != config.address
        or launch.get("tap") != config.tap
        or launch.get("mac") != config.mac
        or not isinstance(challenge, str)
        or not re.fullmatch(r"[0-9a-f]{64}", challenge)
        or not record_matches(launch.get("qemu"), config.qemu)
        or not record_matches(launch.get("backend"), config.backend)
        or not process_live(launch.get("qemu"))
        or not process_live(launch.get("backend"))
    ):
        raise ValueError("terminal observer boot mismatch")
    key = hashlib.sha256(challenge.encode("ascii") + b"overalls-terminald-v1").digest()
    nonce = os.urandom(16)
    message = (
        b"terminald-hello-v1"
        + nonce
        + config.placement_id.encode("ascii")
        + str(config.execution_epoch).encode("ascii")
    )
    tag = hmac.new(key, message, hashlib.sha256).digest()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(3)
        connection.connect(str(config.socket_dir / "v.sock"))
        connection.sendall(f"CONNECT {TERMINAL_OBSERVER_PORT}\n".encode("ascii"))
        handshake = read_line(connection, 32)
        if not re.fullmatch(rb"OK [1-9][0-9]{0,9}\n", handshake):
            raise ValueError("terminal observer vsock refused")
        connection.sendall(terminal_frame(1, nonce + tag))
        if terminal_reply(connection) != b"":
            raise ValueError("terminal observer hello refused")
        connection.sendall(terminal_frame(operation, payload))
        result = terminal_reply(connection)
    if (
        load_object(config.state_dir / "launch.json") != launch
        or not process_live(launch.get("qemu"))
        or not process_live(launch.get("backend"))
    ):
        raise RuntimeError("guest process changed during terminal observation")
    return result


def parse_terminal_snapshot(payload: bytes) -> TerminalSnapshot:
    if len(payload) < 37 or len(payload) > MAX_TERMINAL_PAYLOAD or payload[0] != 1:
        raise ValueError("invalid terminal snapshot")
    count = payload[1]
    daemon_pid = int.from_bytes(payload[24:28], "big")
    ledger_count = payload[36]
    if count > 64 or ledger_count > 128 or daemon_pid == 0:
        raise ValueError("terminal snapshot exceeds bound")
    offset = 37
    ledger_end = offset + ledger_count * 16
    if ledger_end > len(payload):
        raise ValueError("truncated terminal ledger")
    ledger = [payload[index : index + 16].hex() for index in range(offset, ledger_end, 16)]
    offset = ledger_end
    sessions: list[TerminalSession] = []
    previous_id = 0
    for _ in range(count):
        if offset + 46 > len(payload):
            raise ValueError("truncated terminal session")
        session_id = int.from_bytes(payload[offset : offset + 8], "big")
        pid = int.from_bytes(payload[offset + 8 : offset + 12], "big")
        ticks = int.from_bytes(payload[offset + 12 : offset + 20], "big")
        alive = payload[offset + 20]
        ring_base = int.from_bytes(payload[offset + 21 : offset + 29], "big")
        ring_tail = int.from_bytes(payload[offset + 29 : offset + 37], "big")
        ring_limit = int.from_bytes(payload[offset + 37 : offset + 41], "big")
        allocated = int.from_bytes(payload[offset + 41 : offset + 45], "big")
        viewer_count = payload[offset + 45]
        offset += 46
        if (
            session_id <= previous_id
            or session_id > MAX_EPOCH
            or pid == 0
            or alive not in (0, 1)
            or ring_base > ring_tail
            or allocated > 64 * 1024 * 1024
            or viewer_count > 8
        ):
            raise ValueError("invalid terminal session")
        viewers: list[TerminalViewer] = []
        for _ in range(viewer_count):
            if offset + 5 > len(payload) or payload[offset + 4] not in (0, 1):
                raise ValueError("invalid terminal viewer")
            viewers.append(
                {
                    "queue_bytes": int.from_bytes(payload[offset : offset + 4], "big"),
                    "blocked_write": payload[offset + 4] == 1,
                }
            )
            offset += 5
        sessions.append(
            {
                "session_id": session_id,
                "pid": pid,
                "proc_start_ticks": ticks,
                "alive": alive == 1,
                "ring_base": ring_base,
                "ring_tail": ring_tail,
                "ring_limit": ring_limit,
                "deque_allocated": allocated,
                "viewers": viewers,
            }
        )
        previous_id = session_id
    if offset != len(payload):
        raise ValueError("terminal snapshot trailing bytes")
    return {
        "state": "ok",
        "version": 1,
        "births": int.from_bytes(payload[2:10], "big"),
        "deaths": int.from_bytes(payload[10:18], "big"),
        "ring_total": int.from_bytes(payload[18:22], "big"),
        "viewer_total": int.from_bytes(payload[22:24], "big"),
        "daemon_pid": daemon_pid,
        "daemon_start_ticks": int.from_bytes(payload[28:36], "big"),
        "sessions": sessions,
        "ledger_digests": ledger,
    }


def terminal_input_stall(config: Config, session_id: int) -> TerminalInputStall:
    if not 1 <= session_id <= MAX_EPOCH:
        raise ValueError("invalid terminal session ID")
    payload = terminal_probe(config, 0x21, session_id.to_bytes(8, "big"))
    if len(payload) != 13 or payload[0] not in (0, 1):
        raise ValueError("invalid terminal input witness")
    pid = int.from_bytes(payload[9:13], "big")
    if pid == 0:
        raise ValueError("invalid terminal input process")
    return {
        "state": "ok",
        "version": 1,
        "session_id": session_id,
        "pid": pid,
        "in_progress": payload[0] == 1,
        "elapsed_ms": int.from_bytes(payload[1:9], "big"),
    }


def dispatch(
    raw: object, tools: ToolConfig, state_root: Path, socket_root: Path, channel: str
) -> (
    dict[str, object] | Observation | Witness | TerminalSnapshot | TerminalInputStall | ProcessProof
):
    """@cc [owner:ghuntley,label:security;verification] terminal-witness-channel
    Terminal observations MUST accept only tuple-only requests on the witness
    socket, derive the current challenge from retained state, and return only
    decoded numeric and digest evidence. Control MUST refuse these operations.
    """
    if channel not in ("control", "witness"):
        raise ValueError("invalid guest control channel")
    if isinstance(raw, dict) and set(raw) == {"operation"}:
        operation = raw["operation"]
        if operation == "identity":
            return image_identity(tools.image_dir)
        if operation == "inventory" and channel == "control":
            return inventory(state_root, tools)
        if operation == "health" and channel == "control":
            return health(state_root, tools)
        raise ValueError("invalid guest operation")
    if channel == "witness":
        if not isinstance(raw, dict) or raw.get("operation") not in {
            "witness",
            "terminal_witness",
            "terminal_input_stall",
        }:
            raise ValueError("invalid guest witness request")
        operation = raw["operation"]
        expected = {"operation", "placement_id", "execution_epoch", "generation"}
        if operation == "terminal_input_stall":
            expected.add("session_id")
        if set(raw) != expected:
            raise ValueError("invalid guest witness request")
        placement, epoch, generation = (
            raw["placement_id"],
            raw["execution_epoch"],
            raw["generation"],
        )
        if not isinstance(placement, str) or type(epoch) is not int or type(generation) is not int:
            raise ValueError("invalid guest witness request")
        if operation == "terminal_input_stall":
            session_id = raw["session_id"]
            if type(session_id) is not int or not 1 <= session_id <= MAX_EPOCH:
                raise ValueError("invalid terminal session ID")
        config = witness_config(placement, epoch, generation, tools, state_root, socket_root)
        if operation == "witness":
            return witness(config)
        if operation == "terminal_witness":
            return parse_terminal_snapshot(terminal_probe(config, 0x20, b""))
        return terminal_input_stall(config, session_id)
    request = GuestRequest.parse(raw)
    config = guest_config(request, tools, state_root, socket_root)
    if request.operation == "process_proof":
        return process_proof(config)
    config.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if request.operation in ("reconcile", "stop"):
        with (config.state_dir / ".lock").open("a+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            return reconcile(config) if request.operation == "reconcile" else stop(config)
    return observe(config)


def read_frame(connection: socket.socket, maximum: int) -> bytes:
    body = bytearray()
    while len(body) <= maximum:
        piece = connection.recv(1)
        if not piece:
            break
        body.extend(piece)
        if piece == b"\n":
            break
    if not body.endswith(b"\n") or len(body) > maximum:
        raise ValueError("invalid guest RPC frame")
    return bytes(body[:-1])


def encode_reply(value: object) -> bytes:
    encoded = (json.dumps(value, separators=(",", ":")) + "\n").encode("utf-8")
    if len(encoded) > MAX_RESPONSE_BYTES:
        raise ValueError("guest RPC response exceeds bound")
    return encoded


def handle(
    connection: socket.socket, tools: ToolConfig, state_root: Path, socket_root: Path, channel: str
) -> None:
    connection.settimeout(5)
    try:
        request: object = json.loads(read_frame(connection, MAX_REQUEST_BYTES))
        response = dispatch(request, tools, state_root, socket_root, channel)
    except (OSError, ValueError, RuntimeError, TimeoutError) as error:
        reason = "invalid_request" if isinstance(error, ValueError) else "operation_failed"
        response = {"state": "error", "error": reason}
    connection.sendall(encode_reply(response))


def bind_listener(path: Path) -> socket.socket:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    if path.exists():
        if not stat.S_ISSOCK(path.lstat().st_mode):
            raise RuntimeError("guest control path is not a socket")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
            try:
                probe.connect(str(path))
            except ConnectionRefusedError:
                path.unlink()
            else:
                raise RuntimeError("guest control listener already active")
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(str(path))
        path.chmod(0o600)
        listener.listen(8)
    except OSError:
        listener.close()
        raise
    return listener


def serve(
    control_path: Path,
    witness_path: Path,
    tools: ToolConfig,
    state_root: Path,
    socket_root: Path,
) -> None:
    """@cc [owner:ghuntley,label:security;recovery] local-guest-control-only
    Control and witness MUST use separate local sockets and closed allowlists.
    Each accepts one bounded request per connection. A stale socket may be
    replaced only after a connection attempt proves no listener.
    """
    if control_path == witness_path or control_path.parent == witness_path.parent:
        raise ValueError("control and witness sockets must be separate")
    state_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    socket_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    with bind_listener(control_path) as control, bind_listener(witness_path) as observer:
        while True:
            readable, _, _ = select.select([control, observer], [], [])
            listener = readable[0]
            channel = "control" if listener is control else "witness"
            connection, _ = listener.accept()
            with (
                connection,
                contextlib.suppress(BrokenPipeError, ConnectionResetError, TimeoutError),
            ):
                handle(connection, tools, state_root, socket_root, channel)


def healthcheck(path: Path) -> None:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(3)
        connection.connect(str(path))
        connection.sendall(b'{"operation":"health"}\n')
        reply: object = json.loads(read_frame(connection, MAX_RESPONSE_BYTES))
    if (
        not isinstance(reply, dict)
        or set(reply) != {"state", "image_id", "inventory_valid", "state_writable", "state_root"}
        or reply["state"] != "ok"
        or reply["inventory_valid"] is not True
        or reply["state_writable"] is not True
        or not isinstance(reply["image_id"], str)
        or not re.fullmatch(r"sha256:[0-9a-f]{64}", reply["image_id"])
        or not isinstance(reply["state_root"], str)
        or not Path(reply["state_root"]).is_absolute()
    ):
        raise RuntimeError("guest control is unhealthy")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True, type=Path)
    parser.add_argument("--witness-socket", type=Path)
    parser.add_argument("--tools", type=Path)
    parser.add_argument("--state-root", type=Path)
    parser.add_argument("--socket-root", type=Path)
    parser.add_argument("--healthcheck", action="store_true")
    args = parser.parse_args()
    try:
        if not args.socket.is_absolute() or ".." in args.socket.parts:
            raise ValueError("invalid control socket")
        if args.healthcheck:
            healthcheck(args.socket)
            return
        if (
            args.tools is None
            or args.state_root is None
            or args.socket_root is None
            or args.witness_socket is None
        ):
            raise ValueError("missing server paths")
        if any(
            not path.is_absolute() or ".." in path.parts
            for path in (args.tools, args.state_root, args.socket_root, args.witness_socket)
        ):
            raise ValueError("invalid server paths")
        serve(
            args.socket,
            args.witness_socket,
            ToolConfig.load(args.tools),
            args.state_root,
            args.socket_root,
        )
    except (OSError, ValueError, RuntimeError) as error:
        raise SystemExit(str(error)) from None


if __name__ == "__main__":
    main()
