"""Drive one real VMM transport reset against a disposable native probe image."""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import re
import socket
import subprocess
import time
from pathlib import Path
from typing import Literal

Os = Literal["freebsd", "illumos"]


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def document(data: bytes) -> dict[str, object]:
    value: object = json.loads(data, object_pairs_hook=unique_object)
    return mapping(value)


def mapping(value: object) -> dict[str, object]:
    """Narrow an external object to string-keyed evidence without unchecked casts."""
    if not isinstance(value, dict) or any(not isinstance(key, str) for key in value):
        raise RuntimeError("invalid native reset evidence object")
    return {key: item for key, item in value.items() if isinstance(key, str)}


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    """Refuse ambiguous duplicate fields in external serial and image evidence."""
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise RuntimeError("duplicate native reset evidence field")
        result[key] = value
    return result


def api(path: Path, method: str, endpoint: str, body: dict[str, str]) -> int:
    connection = http.client.HTTPConnection("localhost", timeout=60)
    stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stream.connect(str(path))
    connection.sock = stream
    try:
        connection.request(
            method, endpoint, body=json.dumps(body), headers={"Content-Type": "application/json"}
        )
        response = connection.getresponse()
        response.read(4096)
        if response.status != 204:
            raise RuntimeError(f"private test VMM API refused {endpoint}: HTTP {response.status}")
        return response.status
    finally:
        connection.close()


def wait_event(work: Path, process: subprocess.Popen[bytes], name: str) -> dict[str, object]:
    deadline = time.monotonic() + 180
    while True:
        serial = work / "serial.log"
        if serial.stat().st_size > 8 * 1024 * 1024:
            raise RuntimeError("native reset serial evidence exceeded its bound")
        for line in serial.read_bytes().splitlines():
            offset = line.find(b'{"event":"native-reset-')
            if offset < 0:
                continue
            event = document(line[offset:])
            if event.get("event") == "native-reset-failed":
                raise RuntimeError(f"native reset probe failed: {event.get('boundary')}")
            if event.get("event") == name:
                return event
        if process.poll() is not None:
            raise RuntimeError("native reset guest exited before its required serial evidence")
        if time.monotonic() >= deadline:
            raise RuntimeError(f"native reset serial deadline exceeded: {name}")
        time.sleep(0.1)


def raw_connection(path: Path, port: int) -> socket.socket:
    stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stream.settimeout(5)
    try:
        stream.connect(str(path))
        stream.sendall(f"CONNECT {port}\n".encode("ascii"))
        response = bytearray()
        while not response.endswith(b"\n") and len(response) <= 64:
            value = stream.recv(1)
            if not value:
                raise RuntimeError("native reset host connection closed before acknowledgement")
            response.extend(value)
        prefix, _, number = bytes(response).rstrip(b"\n").partition(b" ")
        if prefix != b"OK" or not number.isdigit():
            raise RuntimeError("native reset host connection refused")
        return stream
    except BaseException:
        stream.close()
        raise


def run(image: Path, vmm: Path, probe: Path, work: Path, os_name: Os) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-reset-private-machine
    The fixture MUST use a fresh private disposable disk and VMM API socket,
    match its pre-event compiled identity to exact image assembly, and hold both
    host connections open through the reset event. Peerless identity refusal
    MUST be observed over serial before recording success. FreeBSD MUST refuse
    new sockets until a replacement VM; illumos MUST revalidate the current CID
    before allowing a fresh socket. Cleanup MUST stop the owned VM; neither
    saved memory nor disk may become a production image.
    """
    if os_name not in ("freebsd", "illumos"):
        raise ValueError("invalid native reset operating system")
    work.mkdir(mode=0o700, exist_ok=False, parents=True)
    assembly = document((image / "evidence/assembly-receipt.json").read_bytes())
    build_id = assembly.get("build_id")
    if not isinstance(build_id, str) or re.fullmatch(r"[0-9a-f]{64}", build_id) is None:
        raise RuntimeError("native reset image lacks its compiled kernel identity")
    manifest = document((image / "manifest.json").read_bytes())
    kernel = mapping(manifest.get("kernel"))
    kernel_sha256: object = kernel.get("sha256")
    if not isinstance(kernel_sha256, str) or re.fullmatch(r"[0-9a-f]{64}", kernel_sha256) is None:
        raise RuntimeError("native reset image lacks its kernel digest")
    subprocess.run(
        [
            "cp",
            "--reflink=auto",
            "--sparse=always",
            str(image / "disk.raw"),
            str(work / "disk.raw"),
        ],
        check=True,
    )
    (work / "disk.raw").chmod(0o600)
    config = {
        "boot-source": {"kernel_image_path": str((image / "firmware").resolve())},
        "drives": [
            {
                "drive_id": "rootfs",
                "path_on_host": str(work / "disk.raw"),
                "is_root_device": True,
                "is_read_only": False,
            }
        ],
        "machine-config": {"vcpu_count": 2, "mem_size_mib": 2048},
        "vsock": {"guest_cid": 3, "uds_path": str(work / "v.sock")},
    }
    (work / "config.json").write_text(json.dumps(config), encoding="utf-8")
    with (work / "serial.log").open("wb") as serial:
        process = subprocess.Popen(
            [
                str(vmm),
                "--enable-pci",
                "--api-sock",
                str(work / "api.sock"),
                "--config-file",
                str(work / "config.json"),
            ],
            stdin=subprocess.DEVNULL,
            stdout=serial,
            stderr=subprocess.STDOUT,
        )
        try:
            ready = wait_event(work, process, "native-reset-listeners-ready")
            if ready.get("build_id") != build_id:
                raise RuntimeError("native reset kernel identity differs from exact image assembly")
            with raw_connection(work / "v.sock", 1102), raw_connection(work / "v.sock", 1103):
                armed = wait_event(work, process, "native-reset-armed")
                if any(
                    armed.get(field) is not True
                    for field in ("accept_pending", "read_pending", "write_pending")
                ):
                    raise RuntimeError("native reset operations were not all pending")
                statuses = [
                    api(work / "api.sock", "PATCH", "/vm", {"state": "Paused"}),
                    api(
                        work / "api.sock",
                        "PUT",
                        "/snapshot/create",
                        {
                            "snapshot_type": "Full",
                            "snapshot_path": str(work / "state.snap"),
                            "mem_file_path": str(work / "memory.snap"),
                        },
                    ),
                    api(work / "api.sock", "PATCH", "/vm", {"state": "Resumed"}),
                ]
                verified = wait_event(work, process, "native-reset-verified")
            expected_fresh_socket = (
                "refused-until-new-vm" if os_name == "freebsd" else "current-cid-revalidated"
            )
            expected_idle_error = 54 if os_name == "freebsd" else 131
            if (
                verified.get("idle_error") != expected_idle_error
                or verified.get("fresh_socket") != expected_fresh_socket
            ):
                raise RuntimeError(f"{os_name} reset did not retain its fail-closed socket fence")
            for field in ("accept_error", "read_error", "write_error"):
                error = verified.get(field)
                if type(error) is not int or error <= 0:
                    raise RuntimeError("a blocked native operation did not wake with an error")
            written = verified.get("written_before_refusal")
            if type(written) is not int or not 0 <= written < 16777216:
                raise RuntimeError("native reset writer completed instead of remaining blocked")
            receipt = {
                "version": 1,
                "os": os_name,
                "transport_build_id": build_id,
                "kernel_sha256": kernel_sha256,
                "test_probe_sha256": digest(probe),
                "image_sha256": digest(image / "disk.raw"),
                "firmware_sha256": digest(image / "firmware"),
                "vmm_sha256": digest(vmm),
                "api_statuses": statuses,
                "oracle": verified,
                "native_admission": False,
                "scope": "real transport event fences idle identity and wakes pending accept/read/write; no service or recovery acceptance",
            }
            (work / "reset-receipt.json").write_text(
                json.dumps(receipt, sort_keys=True, indent=2) + "\n", encoding="utf-8"
            )
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)


class Options(argparse.Namespace):
    """CLI fields narrowed through explicit path conversions."""

    image: Path
    vmm: Path
    probe: Path
    work: Path
    os: Os


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--vmm", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--os", choices=("freebsd", "illumos"), default="freebsd")
    arguments = parser.parse_args(namespace=Options())
    run(arguments.image, arguments.vmm, arguments.probe, arguments.work, arguments.os)


if __name__ == "__main__":
    main()
