"""Boot a disposable native image and retain exact transport evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import time
from dataclasses import asdict
from pathlib import Path

from native_transport import connect, exercise, reset_race


def digest(path: Path) -> str:
    """Hash the actual artifact bytes used by this machine run."""
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def run(
    image: Path, vmm: Path, build_id: str, os_name: str, work: Path, fault_injection: bool
) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] disposable-native-machine-probe
    Acceptance MUST require an actual nested-KVM Firecracker boot and exchanges
    with the guest's compiled transport identity. The writable disk MUST be a
    fresh disposable copy, never published or reused after forced VM disposal.
    This transport check MUST NOT claim production service or image admission.
    With fault injection, the receipt MAY record wrong-CID refusal only because
    the fault probe exposes its build token after those kernel checks pass.
    """
    work.mkdir(parents=True, exist_ok=False)
    disk = work / "disk.raw"
    shutil.copyfile(image / "disk.raw", disk)
    uds = work / "v.sock"
    firmware = image / "firmware"
    config = {
        "boot-source": {"kernel_image_path": str(firmware.resolve())},
        "drives": [
            {
                "drive_id": "rootfs",
                "path_on_host": str(disk),
                "is_root_device": True,
                "is_read_only": False,
            }
        ],
        "machine-config": {"vcpu_count": 2, "mem_size_mib": 2048},
        "vsock": {"guest_cid": 3, "uds_path": str(uds)},
    }
    config_path = work / "firecracker.json"
    config_path.write_text(json.dumps(config), encoding="utf-8")
    with (work / "serial.log").open("wb") as serial:
        process = subprocess.Popen(
            [str(vmm), "--enable-pci", "--no-api", "--config-file", str(config_path)],
            stdin=subprocess.DEVNULL,
            stdout=serial,
            stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 180
            while True:
                if process.poll() is not None:
                    raise RuntimeError("native VM exited before its verified listener")
                try:
                    with connect(uds, build_id):
                        break
                except (OSError, RuntimeError):
                    if time.monotonic() >= deadline:
                        raise RuntimeError(
                            "native verified-listener boot deadline exceeded"
                        ) from None
                    time.sleep(0.5)
            exchanges = exercise(uds, build_id)
            if fault_injection:
                reset_race(uds, work / "serial.log")
            receipt = {
                "version": 1,
                "os": os_name,
                "transport_build_id": build_id,
                "guest_cid": 3,
                "peer_cid": 2,
                "image_sha256": digest(image / "disk.raw"),
                "firmware_sha256": digest(firmware),
                "vmm_sha256": digest(vmm),
                "malformed_length_refused": True,
                "fault_injection": fault_injection,
                "wrong_cid_injection_refused": fault_injection,
                "reset_race_fenced": fault_injection,
                "disconnected_history_recovered": True,
                "exchanges": [asdict(result) for result in exchanges],
                "native_admission": False,
                "scope": "compiled transport identity, host CID, bounded echo, credit, reconnect",
            }
            (work / "transport-receipt.json").write_text(
                json.dumps(receipt, sort_keys=True, indent=2) + "\n", encoding="utf-8"
            )
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--vmm", type=Path, required=True)
    parser.add_argument("--build-id", required=True)
    parser.add_argument("--os", choices=("freebsd", "illumos"), required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--fault-injection", action="store_true")
    arguments = parser.parse_args()
    run(
        arguments.image,
        arguments.vmm,
        arguments.build_id,
        arguments.os,
        arguments.work,
        arguments.fault_injection,
    )


if __name__ == "__main__":
    main()
