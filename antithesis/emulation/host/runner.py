"""Single-owner TCG supervisor for the measured Lilly/ZFS NixOS host."""

import argparse
import fcntl
import hashlib
import json
import os
import signal
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

DATA_BYTES = 8 * 1024**3


@dataclass(frozen=True)
class Config:
    image_dir: Path
    state_dir: Path
    runtime_dir: Path
    secret_dir: Path
    observation_dir: Path
    fault_dir: Path
    qemu: Path
    qemu_img: Path

    @classmethod
    def read(cls, path: Path) -> "Config":
        raw: object = json.loads(path.read_text(encoding="ascii"))
        names = {
            "image_dir",
            "state_dir",
            "runtime_dir",
            "secret_dir",
            "observation_dir",
            "fault_dir",
            "qemu",
            "qemu_img",
        }
        if not isinstance(raw, dict) or set(raw) != names:
            raise ValueError("invalid Lilly host runner config")
        values: dict[str, Path] = {}
        for name in names:
            value = raw[name]
            if not isinstance(value, str):
                raise ValueError("invalid runner path")
            target = Path(value)
            if not target.is_absolute() or ".." in target.parts:
                raise ValueError("invalid runner path")
            values[name] = target
        return cls(**values)


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            sha.update(chunk)
    return sha.hexdigest()


def write_json(path: Path, value: object) -> None:
    descriptor, name = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="ascii") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def command(argv: list[str], timeout: int = 60) -> str:
    result = subprocess.run(argv, check=True, capture_output=True, text=True, timeout=timeout)
    if len(result.stdout) > 65536:
        raise ValueError("oversized tool result")
    return result.stdout.strip()


def image(config: Config) -> dict[str, str]:
    raw: object = json.loads((config.image_dir / "manifest.json").read_text(encoding="ascii"))
    if not isinstance(raw, dict) or set(raw) != {"version", "root", "kernel", "initrd", "toplevel"}:
        raise ValueError("invalid host image manifest")
    if (
        raw["version"] != 1
        or not isinstance(raw["toplevel"], str)
        or not raw["toplevel"].startswith("/nix/store/")
    ):
        raise ValueError("invalid host image selection")
    for name, filename in (("root", "root.qcow2"), ("kernel", "kernel"), ("initrd", "initrd")):
        record = raw[name]
        artifact = config.image_dir / filename
        if not isinstance(record, dict) or set(record) != {"bytes", "sha256"}:
            raise ValueError("invalid host image record")
        if type(record["bytes"]) is not int or not isinstance(record["sha256"], str):
            raise ValueError("invalid host image record")
        if artifact.stat().st_size != record["bytes"] or digest(artifact) != record["sha256"]:
            raise ValueError("host image artifact changed")
    return {"root": raw["root"]["sha256"], "toplevel": raw["toplevel"]}


def ensure_disks(config: Config, identity: dict[str, str]) -> None:
    """@cc [owner:ghuntley,label:storage;recovery] host-outer-retained-disks
    First start MUST create one overlay and one fixed sparse member. A partial
    retained set or changed backing identity MUST fail before QEMU launch.
    """
    config.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    record = config.state_dir / "image.json"
    root = config.state_dir / "root.qcow2"
    data = config.state_dir / "data.raw"
    exists = [path.exists() for path in (record, root, data)]
    if any(exists) and not all(exists):
        raise ValueError("incomplete retained Lilly host disks")
    if all(exists):
        if json.loads(record.read_text(encoding="ascii")) != identity:
            raise ValueError("retained Lilly host image changed")
        if data.stat().st_size != DATA_BYTES:
            raise ValueError("retained data member size changed")
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
            str(root),
        ]
    )
    descriptor = os.open(data, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.ftruncate(descriptor, DATA_BYTES)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    write_json(record, identity)


def start_ticks(pid: int) -> int:
    fields = Path(f"/proc/{pid}/stat").read_text(encoding="ascii").rsplit(") ", 1)[1].split()
    if fields[0] in {"Z", "X"}:
        raise ProcessLookupError("host QEMU has exited")
    return int(fields[19])


def live(config: Config) -> tuple[int, int] | None:
    path = config.state_dir / "qemu.json"
    if not path.exists():
        return None
    raw: object = json.loads(path.read_text(encoding="ascii"))
    if not isinstance(raw, dict) or set(raw) != {"pid", "start_ticks"}:
        raise ValueError("invalid retained host process record")
    pid, ticks = raw["pid"], raw["start_ticks"]
    if type(pid) is not int or type(ticks) is not int:
        raise ValueError("invalid retained host process")
    try:
        if start_ticks(pid) == ticks:
            return pid, ticks
    except (FileNotFoundError, ProcessLookupError):
        pass
    return None


def start(config: Config) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] host-vmm-single-owner
    One locked runner MUST own QEMU for its lifetime. A retained live PID MUST
    prevent a second launch; a dead runner MUST kill its child with PDEATHSIG.
    """
    config.runtime_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    config.secret_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    config.observation_dir.mkdir(mode=0o755, parents=True, exist_ok=True)
    config.fault_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    config.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (config.state_dir / "owner.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        selected = image(config)
        ensure_disks(config, selected)
        if live(config) is not None:
            raise ValueError("Lilly host QEMU already owned")
        qmp = config.runtime_dir / "qmp.sock"
        if qmp.exists():
            qmp.unlink()
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
            "6144",
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
            "init=" + selected["toplevel"] + "/init root=LABEL=nixos rw console=ttyS0 panic=1",
            "-drive",
            f"if=none,id=root,file={config.state_dir / 'root.qcow2'},format=qcow2,cache=none",
            "-device",
            "virtio-blk-pci,drive=root,serial=KTLILLY-ROOT",
            "-drive",
            f"if=none,id=data,file={config.state_dir / 'data.raw'},format=raw,cache=none",
            "-device",
            "virtio-blk-pci,drive=data,serial=KTLILLY-DATA",
            "-netdev",
            "user,id=hostnet",
            "-device",
            "virtio-net-pci,netdev=hostnet",
            "-virtfs",
            f"local,path={config.secret_dir},mount_tag=overalls-secrets,security_model=none,id=secrets",
            "-virtfs",
            f"local,path={config.observation_dir},mount_tag=overalls-observation,security_model=none,id=observation",
            "-virtfs",
            f"local,path={config.fault_dir},mount_tag=overalls-faults,security_model=none,id=faults",
            "-qmp",
            f"unix:{qmp},server=on,wait=off",
        ]

        owner_pid = os.getpid()

        def parent_death() -> None:
            import ctypes

            libc = ctypes.CDLL(None)
            if libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0:
                os._exit(127)
            if os.getppid() != owner_pid:
                os._exit(127)

        with (config.state_dir / "serial.log").open("ab") as output:
            child = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=subprocess.STDOUT,
                preexec_fn=parent_death,
            )
            write_json(
                config.state_dir / "qemu.json",
                {"pid": child.pid, "start_ticks": start_ticks(child.pid)},
            )
            try:
                code = child.wait()
            except KeyboardInterrupt:
                child.terminate()
                code = child.wait(timeout=20)
            if code != 0:
                raise ValueError("Lilly host QEMU exited unsuccessfully")


def observe(config: Config) -> dict[str, object]:
    process = live(config)
    if process is None:
        return {"version": 1, "state": "unavailable", "reason": "host_qemu_unavailable"}
    result: dict[str, object] = {
        "version": 1,
        "state": "running",
        "qemu_pid": process[0],
        "qemu_start_ticks": process[1],
        "root_overlay": str(config.state_dir / "root.qcow2"),
        "data_member": str(config.state_dir / "data.raw"),
    }
    health = config.secret_dir / "lilly-host-health.json"
    if health.is_file() and time.time() - health.stat().st_mtime <= 10:
        raw: object = json.loads(health.read_text(encoding="ascii"))
        if isinstance(raw, dict) and raw.get("version") == 1:
            result["inner"] = raw
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("start", "status", "observe"))
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    config = Config.read(args.config)
    if args.command == "start":
        start(config)
    else:
        result = observe(config)
        print(json.dumps(result, separators=(",", ":"), sort_keys=True))
        inner = result.get("inner")
        if args.command == "status" and (
            result.get("state") != "running"
            or not isinstance(inner, dict)
            or inner.get("connected") is not True
        ):
            raise SystemExit(1)


if __name__ == "__main__":
    main()
