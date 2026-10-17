"""Own one explicitly designated blank data disk; never repair foreign storage."""

import fcntl
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import TypedDict

from runtime import (
    Identity,
    SetupError,
    encode,
    identities,
    private_directory,
    publish,
    read_private,
)

STATE = Path("/var/lib/inception")
DEVICE = "/dev/vdb"
POOL = "inception"
DATASET = "inception/lilly"
DATA_BYTES = 274877906944
GUEST_BUDGET = 257698037760  # 240 GiB; retain room for pool metadata.


class Binding(TypedDict):
    version: int
    pool_guid: str
    instance_id: str
    device: str


def run(argv: list[str], required: bool = True) -> str | None:
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=120)
    if result.returncode and required:
        raise SetupError("Inception storage command failed")
    return result.stdout.decode().strip() if result.returncode == 0 else None


def owned(identity: Identity, binding: dict[str, object] | None) -> Binding:
    owner = run(["zfs", "get", "-Hpo", "value", "inception:instance", POOL])
    guid = run(["zpool", "get", "-Hpo", "value", "guid", POOL])
    status = run(["zpool", "status", "-P", POOL])
    if owner is None or guid is None or status is None:
        raise SetupError("Inception storage ownership mismatch")
    devices = re.findall(r"^\s+(/\S+)\s+ONLINE\s", status, re.MULTILINE)
    if (
        owner != identity["instance_id"]
        or not guid.isdecimal()
        or devices not in [[DEVICE], [DEVICE + "1"]]
        or (
            binding is not None
            and binding != {"version": 1, "pool_guid": guid, "instance_id": owner, "device": DEVICE}
        )
    ):
        raise SetupError("Inception storage ownership mismatch")
    return Binding(version=1, pool_guid=guid, instance_id=owner, device=DEVICE)


def prepare() -> None:
    """@cc [owner:ghuntley,label:storage;recovery] inception-data-disk-ownership
    Pool creation MUST target only the fixed 256 GiB data device, require no prior
    binding or recognized signature, and use non-forcing creation. Existing pools
    MUST match the per-instance property, recorded GUID and sole device. Missing
    bound storage MUST fail rather than create a replacement. Import validation
    MUST use read-only, unmounted import before accepting previously inactive pools.
    """
    identity = identities(STATE)
    if not stat.S_ISBLK(os.stat(DEVICE).st_mode) or run(["blockdev", "--getsize64", DEVICE]) != str(
        DATA_BYTES
    ):
        raise SetupError("Inception data device invalid")
    try:
        binding: object = json.loads(read_private(STATE / "storage.json"))
    except FileNotFoundError:
        binding = None
    if binding is not None and (
        not isinstance(binding, dict)
        or set(binding) != {"version", "pool_guid", "instance_id", "device"}
    ):
        raise SetupError("Inception storage binding invalid")

    active = run(["zpool", "list", "-H", "-o", "name", POOL], required=False)
    if active is None:
        imported = run(
            [
                "zpool",
                "import",
                "-N",
                "-d",
                "/dev",
                "-o",
                "readonly=on",
                "-o",
                "cachefile=none",
                POOL,
            ],
            required=False,
        )
        if imported is not None:
            try:
                discovered = owned(identity, binding)
            finally:
                run(["zpool", "export", POOL])
            run(
                [
                    "zpool",
                    "import",
                    "-N",
                    "-d",
                    "/dev",
                    "-o",
                    "cachefile=none",
                    discovered["pool_guid"],
                ]
            )
        else:
            if binding is not None:
                raise SetupError("Inception bound storage missing")
            probe = subprocess.run(
                ["blkid", "-p", DEVICE],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
            )
            if probe.returncode != 2:
                raise SetupError("Inception data device is not blank")
            # Check metadata regions as well as known signatures; never use -f.
            with open(DEVICE, "rb", buffering=0) as disk:
                for offset in [0, DATA_BYTES - 4 * 1024**2]:
                    disk.seek(offset)
                    data = disk.read(4 * 1024**2)
                    if len(data) != 4 * 1024**2 or any(data):
                        raise SetupError("Inception data device has existing metadata")
            run(
                [
                    "zpool",
                    "create",
                    "-o",
                    "cachefile=none",
                    "-o",
                    "ashift=12",
                    "-O",
                    "mountpoint=none",
                    "-O",
                    "compression=lz4",
                    "-O",
                    "reservation=none",
                    "-O",
                    "refreservation=none",
                    "-O",
                    "inception:instance=" + identity["instance_id"],
                    POOL,
                    DEVICE,
                ]
            )

    discovered = owned(identity, binding)
    publish(STATE / "storage.json", encode(discovered))
    child = run(["zfs", "list", "-H", "-o", "name", DATASET], required=False)
    if child is None:
        # The child is created only before its first successful publication.
        if os.path.lexists(STATE / "storage-ready"):
            raise SetupError("Inception guest dataset missing")
        run(
            [
                "zfs",
                "create",
                "-o",
                "mountpoint=/pool",
                "-o",
                "canmount=on",
                "-o",
                "quota=" + str(GUEST_BUDGET),
                DATASET,
            ]
        )
    expected = {
        "mountpoint": "/pool",
        "canmount": "on",
        "quota": str(GUEST_BUDGET),
        "inception:instance": identity["instance_id"],
    }
    for key, value in expected.items():
        if run(["zfs", "get", "-Hpo", "value", key, DATASET]) != value:
            raise SetupError("Inception guest dataset policy changed")
    if run(["zfs", "get", "-Hpo", "value", "mounted", DATASET]) != "yes":
        run(["zfs", "mount", DATASET])
    Path("/pool").chmod(0o700)
    publish(STATE / "storage-ready", b"1\n")


if __name__ == "__main__":
    try:
        if os.getuid() != 0:
            raise SetupError("root preparation required")
        private_directory(STATE)
        fd = os.open(STATE / "bootstrap.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            prepare()
    except SetupError as error:
        print(str(error) + "; preserve the existing disk and private binding", file=sys.stderr)
        sys.exit(1)
    except Exception:
        print(
            "Inception storage setup failed; preserve the existing disk and private binding",
            file=sys.stderr,
        )
        sys.exit(1)
