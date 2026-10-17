"""Host startup prerequisite; uses fresh trusted guests and no SMTP credentials."""

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

from transport import binding, launch, stop, wait


def cleanup() -> None:
    directory = Path("/var/lib/lilly-inception-check")
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
        raise RuntimeError("private probe state unavailable")
    # systemd invokes this only after terminating the service's whole cgroup.
    # This directory is reserved exclusively for fresh prerequisite fixtures.
    for path in directory.iterdir():
        info = path.lstat()
        if path.name.startswith("probe-") and stat.S_ISDIR(info.st_mode) and info.st_uid == 0:
            shutil.rmtree(path)


def main() -> None:
    """@cc [owner:ghuntley,label:verification;recovery] inception-native-prerequisite-receipt
    A receipt MUST follow a successful real Firecracker-in-Firecracker boot and
    bind this host boot, configured image, probe artifact and VMM executable.
    Failure MUST leave no receipt. Temporary guests MUST terminate before return;
    the probe MUST NOT inspect production disks, receive SMTP or use host networking.
    """
    config = json.loads(Path(sys.argv[1]).read_bytes())
    runtime = Path("/run/lilly-inception")
    info = runtime.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
        raise RuntimeError("private probe directory unavailable")
    receipt = runtime / "proof.json"
    receipt.unlink(missing_ok=True)
    tools = json.loads((Path(config["release"]) / "overalls-release.json").read_bytes())
    with tempfile.TemporaryDirectory(
        prefix="probe-", dir="/var/lib/lilly-inception-check"
    ) as directory:
        # Keep the Unix socket below Linux's 108-byte path limit.
        os.symlink(directory, runtime / "current")
        boot = binding()
        process: subprocess.Popen[bytes] | None = None
        try:
            process = launch(config["probe"], tools["firecracker"], runtime / "current", boot)
            wait(
                runtime / "current" / "v.sock",
                1027,
                {"version": 1, "state": "nested_ready", **boot},
                process,
                240,
            )
        finally:
            if process is not None:
                stop(process)
            (runtime / "current").unlink()
    value = {
        "version": 1,
        "image_id": config["image_id"],
        "probe_id": config["probe"],
        "firecracker": tools["firecracker"],
        "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
    }
    temporary = runtime / "proof.pending"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, separators=(",", ":"))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, receipt)


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--cleanup"]:
            cleanup()
        else:
            main()
    except Exception:
        raise SystemExit(
            "Inception native prerequisite failed; Inception remains unavailable"
        ) from None
