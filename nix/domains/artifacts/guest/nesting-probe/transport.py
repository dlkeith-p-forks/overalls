"""Private, deadline-bound Firecracker boot probes with no terminal output."""

import json
import os
import shutil
import socket
import subprocess
import time
import uuid
from collections.abc import Mapping
from pathlib import Path


def binding() -> dict[str, str | int]:
    return {
        "placement_id": str(uuid.uuid4()),
        "execution_epoch": 1,
        "boot_challenge": os.urandom(32).hex(),
    }


def launch(
    image: str | Path,
    firecracker: str,
    directory: str | Path,
    identity: Mapping[str, str | int],
    memory: int = 2048,
    tap: str | None = None,
    disk_bytes: int = 8 * 1024**3,
) -> subprocess.Popen[bytes]:
    image, directory = Path(image), Path(directory)
    manifest = json.loads((image / "manifest.json").read_bytes())
    disk = directory / "rootfs.ext4"
    shutil.copyfile(image / "rootfs.ext4", disk)
    with disk.open("r+b") as stream:
        stream.truncate(max(disk.stat().st_size, disk_bytes))
        stream.flush()
        os.fsync(stream.fileno())
    config: dict[str, object] = {
        "boot-source": {
            "kernel_image_path": str(image / "kernel"),
            "initrd_path": str(image / "initrd"),
            "boot_args": manifest["boot_args"]
            + " lilly.ipv4=10.10.0.2"
            + " lilly.placement="
            + identity["placement_id"]
            + " lilly.execution_epoch=1 lilly.boot_challenge="
            + identity["boot_challenge"],
        },
        "machine-config": {"vcpu_count": 2, "mem_size_mib": memory, "smt": False},
        "drives": [
            {
                "drive_id": "root",
                "path_on_host": str(disk),
                "is_root_device": True,
                "is_read_only": False,
                "cache_type": "Writeback",
                "io_engine": "Sync",
            }
        ],
        "vsock": {"guest_cid": 3, "uds_path": str(directory / "v.sock")},
    }
    if tap:
        config["network-interfaces"] = [
            {"iface_id": "eth0", "host_dev_name": tap, "guest_mac": "02:00:00:00:00:02"}
        ]
    path = directory / "firecracker.json"
    path.write_text(json.dumps(config))
    return subprocess.Popen(
        [firecracker, "--no-api", "--config-file", str(path), "--level", "Off"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def stop(process: subprocess.Popen[bytes]) -> None:
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def wait(
    path: Path,
    port: int,
    expected: Mapping[str, object],
    process: subprocess.Popen[bytes],
    timeout: int,
    boot_id: bool = False,
) -> None:
    """@cc [owner:ghuntley,label:verification;security] nested-probe-live-boot-binding
    A probe MUST require the current random boot identity over its private vsock
    endpoint, reject extra fields and bound the entire exchange by one deadline.
    Process launch or CPU feature flags alone MUST NOT establish nested execution.
    """
    deadline = time.monotonic() + timeout
    while process.poll() is None and time.monotonic() < deadline:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(max(0.001, deadline - time.monotonic()))
                connection.connect(str(path))
                connection.sendall(f"CONNECT {port}\n".encode())
                with connection.makefile("rb") as stream:
                    handshake = stream.readline(32)
                    if not handshake.startswith(b"OK ") or not handshake.endswith(b"\n"):
                        raise ValueError()
                    assigned = int(handshake[3:-1])
                    if not 1 <= assigned <= 4294967295 or handshake != f"OK {assigned}\n".encode():
                        raise ValueError()
                    connection.settimeout(max(0.001, deadline - time.monotonic()))
                    frame = stream.readline(513)
                    if len(frame) > 512 or not frame.endswith(b"\n"):
                        raise ValueError()
                    reply = json.loads(frame)
                    if boot_id:
                        kernel = reply.pop("boot_id")
                        if str(uuid.UUID(kernel)) != kernel:
                            raise ValueError()
                    if (
                        reply == expected
                        and type(reply["version"]) is int
                        and type(reply["execution_epoch"]) is int
                        and time.monotonic() < deadline
                    ):
                        return
        except (OSError, ValueError, TypeError, KeyError, AttributeError):
            pass
        time.sleep(min(0.1, max(0, deadline - time.monotonic())))
    raise RuntimeError("nested Firecracker boot not established")
