"""Boot a real inner Firecracker before reporting the nesting prerequisite."""

import json
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

from transport import binding, launch, stop, wait


def main() -> None:
    config = json.loads(Path(sys.argv[1]).read_bytes())
    # readiness is loaded from a runtime-provided source directory, not a package.
    sys.path.insert(0, config["readiness_source"])
    from readiness import identity

    outer = identity(Path("/proc/cmdline").read_text())
    flags = Path("/proc/cpuinfo").read_text().split()
    module = "kvm_amd" if "svm" in flags else "kvm_intel" if "vmx" in flags else None
    if not module:
        raise RuntimeError("nested virtualization unavailable")
    subprocess.run(
        [config["modprobe"], module],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        [config["ip"], "tuntap", "add", "probe0", "mode", "tap"],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        [config["ip"], "link", "set", "probe0", "up"],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    # There is no external interface or route in this trusted probe guest.
    # The tap supplies only the ordinary inner image's local readiness interface.
    with tempfile.TemporaryDirectory(prefix="nested-", dir="/var/lib") as directory:
        boot = binding()
        process = launch(
            config["image"],
            config["firecracker"],
            directory,
            boot,
            memory=512,
            tap="probe0",
            disk_bytes=3 * 1024**3,
        )
        try:
            wait(
                Path(directory) / "v.sock",
                1024,
                {"version": 1, "state": "ready", **boot},
                process,
                180,
                boot_id=True,
            )
        finally:
            stop(process)
    response = {key: outer[key] for key in ["placement_id", "execution_epoch", "boot_challenge"]}
    response.update(version=1, state="nested_ready")
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as listener:
        listener.bind((socket.VMADDR_CID_ANY, 1027))
        listener.listen(2)
        while True:
            connection, peer = listener.accept()
            with connection:
                connection.settimeout(2)
                if peer[0] == 2:
                    connection.sendall(json.dumps(response, separators=(",", ":")).encode() + b"\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        raise SystemExit("nested Firecracker probe failed; no readiness published") from None
