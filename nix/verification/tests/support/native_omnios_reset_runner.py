"""Drive a real OmniOS reset after a complete ordinary service baseline."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Never

import native_ordinary_transport as ordinary
import native_reset as reset
import native_service_runner as runner


class ResetVerified(Exception):
    """Leave the ordinary lifecycle through its unconditional owned cleanup."""


def verify(
    context: runner.BootContext,
    image: Path,
    vmm: Path,
    probe: Path,
    build_id: str,
    kernel_sha256: str,
) -> Never:
    """@cc [owner:ghuntley,label:verification;security] omnios-reset-event-oracle
    An actual private VMM snapshot event MUST invalidate a peerless live socket
    and wake already-pending accept/read/write. A new socket MUST revalidate the
    same compiled identity and current CID. The fixture MUST retain both host
    streams until serial verification and dispose the owned VM afterward; its
    earlier service baseline MUST NOT imply restored service or clean shutdown.
    """
    if context.platform.name != "illumos" or context.api is None:
        raise ValueError("OmniOS reset requires the private test API")
    fixture = ordinary.launch(context, probe, mode="reset")
    ready = reset.wait_event(context.work, context.process, "native-reset-listeners-ready")
    if ready.get("build_id") != build_id:
        raise RuntimeError("native reset kernel identity differs from exact image assembly")
    with reset.raw_connection(context.uds, 1102), reset.raw_connection(context.uds, 1103):
        armed = reset.wait_event(context.work, context.process, "native-reset-armed")
        if any(
            armed.get(field) is not True
            for field in ("accept_pending", "read_pending", "write_pending")
        ):
            raise RuntimeError("native reset operations were not all pending")
        statuses = [
            reset.api(context.api, "PATCH", "/vm", {"state": "Paused"}),
            reset.api(
                context.api,
                "PUT",
                "/snapshot/create",
                {
                    "snapshot_type": "Full",
                    "snapshot_path": str(context.work / "state.snap"),
                    "mem_file_path": str(context.work / "memory.snap"),
                },
            ),
            reset.api(context.api, "PATCH", "/vm", {"state": "Resumed"}),
        ]
        verified = reset.wait_event(context.work, context.process, "native-reset-verified")
    if (
        verified.get("idle_error") != 131
        or verified.get("fresh_socket") != "current-cid-revalidated"
    ):
        raise RuntimeError(
            "OmniOS reset did not invalidate live sockets and revalidate current CID"
        )
    for field in ("accept_error", "read_error", "write_error"):
        error = verified.get(field)
        if type(error) is not int or error <= 0:
            raise RuntimeError("a blocked native operation did not wake with an error")
    written = verified.get("written_before_refusal")
    if type(written) is not int or not 0 <= written < 16777216:
        raise RuntimeError("native reset writer completed instead of remaining blocked")
    receipt: dict[str, object] = {
        "version": 1,
        "os": "illumos",
        "boot_id": context.boot.boot_id,
        "transport_build_id": build_id,
        "kernel_sha256": kernel_sha256,
        "test_probe_sha256": fixture.probe_sha256,
        "image_sha256": reset.digest(image / "disk.raw"),
        "firmware_sha256": reset.digest(image / "firmware"),
        "vmm_sha256": reset.digest(vmm),
        "api_statuses": statuses,
        "oracle": verified,
        "native_admission": False,
        "scope": "real transport event after complete-service baseline; idle identity invalidation and pending accept/read/write refusal; no restored service, clean shutdown, recovery or DMA acceptance",
    }
    (context.work / "reset-receipt.json").write_text(
        json.dumps(receipt, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )
    raise ResetVerified


def run(
    image: Path,
    vmm: Path,
    fixture: Path,
    tap: str,
    work: Path,
    probe: Path,
    build_id: str,
) -> None:
    kernel_sha256 = ordinary.validate_image(image, build_id)
    try:
        runner.run(
            image,
            vmm,
            fixture,
            tap,
            work,
            os_name="illumos",
            enable_api=True,
            verify_boot=lambda context: verify(context, image, vmm, probe, build_id, kernel_sha256),
        )
    except ResetVerified:
        if not (work / "reset-receipt.json").is_file() or (work / "service-receipt.json").exists():
            raise RuntimeError(
                "native reset lifecycle produced an invalid receipt boundary"
            ) from None
        return
    raise RuntimeError("native reset lifecycle completed without observing its event")


class Options(argparse.Namespace):
    image: Path
    vmm: Path
    fixture: Path
    tap: str
    work: Path
    probe: Path
    build_id: str


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("image", "vmm", "fixture", "work", "probe"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--tap", required=True)
    parser.add_argument("--build-id", required=True)
    arguments = parser.parse_args(namespace=Options())
    run(
        arguments.image,
        arguments.vmm,
        arguments.fixture,
        arguments.tap,
        arguments.work,
        arguments.probe,
        arguments.build_id,
    )


if __name__ == "__main__":
    main()
