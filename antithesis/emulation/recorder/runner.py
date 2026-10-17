"""Single-owner TCG supervisor for the real NixOS recorder fixture."""

import argparse
import errno
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ARCHIVE_BYTES = 64 * 1024 * 1024


@dataclass(frozen=True)
class Config:
    image_dir: Path
    state_dir: Path
    runtime_dir: Path
    request_dir: Path
    result_dir: Path
    observation_dir: Path
    qemu: Path
    qemu_img: Path
    mkfs_ext4: Path

    @classmethod
    def read(cls, path: Path) -> "Config":
        parsed: object = json.loads(path.read_text(encoding="ascii"))
        fields = {
            "image_dir",
            "state_dir",
            "runtime_dir",
            "request_dir",
            "result_dir",
            "observation_dir",
            "qemu",
            "qemu_img",
            "mkfs_ext4",
        }
        if not isinstance(parsed, dict) or set(parsed) != fields:
            raise ValueError("invalid recorder VM config")
        values: dict[str, Path] = {}
        for field in fields:
            value = parsed[field]
            if not isinstance(value, str) or not value.startswith("/"):
                raise ValueError("invalid recorder VM path")
            candidate = Path(value)
            if ".." in candidate.parts:
                raise ValueError("invalid recorder VM path")
            values[field] = candidate
        return cls(**values)


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        while part := stream.read(1024 * 1024):
            sha.update(part)
    return sha.hexdigest()


def manifest(config: Config) -> str:
    parsed: object = json.loads((config.image_dir / "manifest.json").read_text(encoding="ascii"))
    if not isinstance(parsed, dict) or set(parsed) != {
        "version",
        "root",
        "kernel",
        "initrd",
        "toplevel",
    }:
        raise ValueError("invalid recorder image manifest")
    top = parsed["toplevel"]
    if parsed["version"] != 1 or not isinstance(top, str) or not top.startswith("/nix/store/"):
        raise ValueError("invalid recorder image selection")
    for field, filename in (("root", "root.qcow2"), ("kernel", "kernel"), ("initrd", "initrd")):
        item = parsed[field]
        artifact = config.image_dir / filename
        if not isinstance(item, dict) or set(item) != {"bytes", "sha256"}:
            raise ValueError("invalid recorder artifact record")
        count, sha = item["bytes"], item["sha256"]
        if type(count) is not int or count < 1 or not isinstance(sha, str) or len(sha) != 64:
            raise ValueError("invalid recorder artifact record")
        if artifact.stat().st_size != count or digest(artifact) != sha:
            raise ValueError("recorder image artifact changed")
    return top


def prepare(config: Config, top: str) -> None:
    """@cc [owner:ghuntley,label:storage;recovery] recorder-vm-retained-archive
    The first boot MUST create one immutable-base overlay and one 64 MiB ext4
    archive member. Partial retained sets or changed image identity MUST fail
    before QEMU starts; the archive MUST never be recreated after a crash.
    """
    for path in (
        config.state_dir,
        config.runtime_dir,
        config.request_dir,
        config.result_dir,
        config.observation_dir,
    ):
        path.mkdir(parents=True, exist_ok=True)
    identity = config.state_dir / "image.json"
    root = config.state_dir / "root.qcow2"
    archive = config.state_dir / "archive.raw"
    present = [path.exists() for path in (identity, root, archive)]
    if any(present) and not all(present):
        raise ValueError("incomplete retained recorder disks")
    selected = {"toplevel": top, "root_sha256": digest(config.image_dir / "root.qcow2")}
    if all(present):
        if (
            json.loads(identity.read_text(encoding="ascii")) != selected
            or archive.stat().st_size != ARCHIVE_BYTES
        ):
            raise ValueError("retained recorder image changed")
        return
    subprocess.run(
        [
            str(config.qemu_img),
            "create",
            "-f",
            "qcow2",
            "-F",
            "qcow2",
            "-b",
            str((config.image_dir / "root.qcow2").resolve(strict=True)),
            str(root),
        ],
        check=True,
        capture_output=True,
        timeout=60,
    )
    descriptor = os.open(archive, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        os.ftruncate(descriptor, ARCHIVE_BYTES)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    subprocess.run(
        [str(config.mkfs_ext4), "-F", "-L", "KTRACE-ARCHIVE", str(archive)],
        check=True,
        capture_output=True,
        timeout=60,
    )
    identity.write_text(json.dumps(selected, sort_keys=True) + "\n", encoding="ascii")


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


def start(config: Config) -> None:
    """Exec the VM as container main process so container loss kills QEMU."""
    top = manifest(config)
    prepare(config, top)
    pidfile = config.state_dir / "qemu.pid"
    pidfile.write_text(str(os.getpid()) + "\n", encoding="ascii")
    cache = drive_cache(
        (
            config.state_dir / "root.qcow2",
            config.state_dir / "archive.raw",
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
        "2",
        "-m",
        "1536",
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
        # The systemd initrd mounts / read-write from the image's own
        # x-initrd.mount fstab entry. A root= argument would duplicate
        # sysroot.mount and, without rw, leave /sysroot read-only so the
        # /run bind into the real root fails and the guest enters emergency mode.
        f"init={top}/init console=ttyS0 panic=1",
        "-drive",
        f"if=none,id=root,file={config.state_dir / 'root.qcow2'},format=qcow2,cache={cache}",
        "-device",
        "virtio-blk-pci,drive=root,serial=KTR-ROOT",
        "-drive",
        f"if=none,id=archive,file={config.state_dir / 'archive.raw'},format=raw,cache={cache}",
        "-device",
        "virtio-blk-pci,drive=archive,serial=KTR-ARCHIVE",
    ]
    for tag, path, identifier in (
        ("overalls-requests", config.request_dir, "requests"),
        ("overalls-results", config.result_dir, "results"),
        ("overalls-observation", config.observation_dir, "observation"),
    ):
        argv += [
            "-fsdev",
            f"local,path={path},security_model=none,id={identifier}",
            "-device",
            f"virtio-9p-pci,fsdev={identifier},mount_tag={tag}",
        ]
    os.execv(config.qemu, argv)


def status(config: Config) -> bool:
    """@cc [owner:ghuntley,label:verification;storage] recorder-guest-readiness
    VM health MUST require a fresh active-unit sample, both kernel identities,
    a distinct bounded archive device, and readable recorder/SQLite state.
    Missing or malformed evidence MUST leave the guest unavailable.
    """
    try:
        pid = int((config.state_dir / "qemu.pid").read_text(encoding="ascii").strip())
        if pid < 1 or not Path(f"/proc/{pid}").exists():
            return False
        parsed: object = json.loads(
            (config.observation_dir / "status.json").read_text(encoding="ascii")
        )
        if not isinstance(parsed, dict) or set(parsed) != {
            "sample_ns",
            "producer",
            "recorder",
            "spool",
            "archive",
        }:
            return False
        sample = parsed["sample_ns"]
        status_ready = (
            type(sample) is int
            and 0 <= time.time_ns() - sample < 10_000_000_000
            and all(parsed[key] is True for key in ("producer", "recorder", "spool", "archive"))
        )
        if not status_ready:
            return False
        filesystem: object = json.loads(
            (config.observation_dir / "filesystem.json").read_text(encoding="ascii")
        )
        if not isinstance(filesystem, dict) or set(filesystem) != {
            "archive_device",
            "root_device",
            "free_bytes",
            "total_bytes",
        }:
            return False
        if any(type(filesystem[key]) is not int for key in filesystem):
            return False
        total = filesystem["total_bytes"]
        free = filesystem["free_bytes"]
        if (
            filesystem["archive_device"] == filesystem["root_device"]
            or not 32 * 1024 * 1024 <= total <= ARCHIVE_BYTES
            or not 0 <= free <= total
        ):
            return False
        for name, cgroup in (
            ("identity.json", "0::/fixture.slice/recorder-peer.service"),
            ("spool_identity.json", "0::/system.slice/overalls-trace-recorder.service"),
        ):
            identity: object = json.loads(
                (config.observation_dir / name).read_text(encoding="ascii")
            )
            if (
                not isinstance(identity, dict)
                or set(identity) != {"pid", "uid", "start_ticks", "cgroup"}
                or identity["cgroup"] != cgroup
                or any(
                    type(identity[key]) is not int or identity[key] < 1
                    for key in ("pid", "start_ticks")
                )
                or type(identity["uid"]) is not int
                or identity["uid"] < 1
            ):
                return False
        checkpoint: object = json.loads(
            (config.observation_dir / "state.json").read_text(encoding="ascii")
        )
        if (
            not isinstance(checkpoint, dict)
            or not isinstance(checkpoint.get("incarnation"), str)
            or not isinstance(checkpoint.get("pending"), dict)
        ):
            return False
        archive = config.observation_dir / "archive.sqlite"
        with sqlite3.connect(f"file:{archive}?mode=ro", uri=True, timeout=1) as database:
            database.execute("SELECT count(*) FROM batches").fetchone()
        return True
    except (OSError, ValueError, json.JSONDecodeError, sqlite3.Error):
        return False


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("start", "status"))
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    config = Config.read(args.config)
    if args.mode == "start":
        start(config)
    elif not status(config):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
