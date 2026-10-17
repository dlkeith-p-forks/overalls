"""Measured ZFS enrollment and private Lilly config in the TCG inner host."""

import argparse
import contextlib
import hashlib
import hmac
import json
import os
import re
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from typing import TypedDict

POOL = "tank"
DATASET = "tank/lilly"
DISK = Path("/dev/disk/by-id/virtio-KTLILLY-DATA")
DISK_BYTES = 8 * 1024**3
STATE = Path("/var/lib/lilly-host")
MANIFEST = STATE / "pool.json"
SECRETS = Path("/run/overalls-secrets")
ENROLLMENT = SECRETS / "lilly-host-enrollment.json"
CREDENTIAL = SECRETS / "lilly-host-credential.json"
POOL_ID = SECRETS / "lilly-host-pool-id"
CA = SECRETS / "ca.crt"
CONFIG = Path("/run/lilly-host/config.json")
HEALTH = SECRETS / "lilly-host-health.json"
OBSERVATION = Path("/run/overalls-observation/physical.json")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
GUID = re.compile(r"[1-9][0-9]{0,19}\Z")


class PoolRecord(TypedDict):
    version: int
    serial: str
    zpool_guid: str
    dataset_guid: str


def run(argv: list[str], timeout: int = 30) -> str:
    result = subprocess.run(argv, capture_output=True, text=True, check=True, timeout=timeout)
    if len(result.stdout) > 65536:
        raise ValueError("oversized native observation")
    return result.stdout.strip()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, name = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="ascii") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream, separators=(",", ":"), sort_keys=True)
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


def read_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="ascii"))


def guid(tool: str, name: str) -> str:
    value = run([tool, "get", "-Hpo", "value", "guid", name])
    if GUID.fullmatch(value) is None or int(value) >= 2**64:
        raise ValueError("invalid measured GUID")
    return value


def disk_identity() -> None:
    if not DISK.is_symlink() or DISK.resolve().name != "vdb":
        raise ValueError("fixed data member missing or reordered")
    if run(["lsblk", "-dn", "-o", "SERIAL", str(DISK.resolve())]) != "KTLILLY-DATA":
        raise ValueError("data member serial changed")
    if int(run(["blockdev", "--getsize64", str(DISK.resolve())])) != DISK_BYTES:
        raise ValueError("data member size changed")


def load_record() -> PoolRecord:
    raw = read_json(MANIFEST)
    if not isinstance(raw, dict) or set(raw) != {"version", "serial", "zpool_guid", "dataset_guid"}:
        raise ValueError("invalid retained pool record")
    if raw["version"] != 1 or raw["serial"] != "KTLILLY-DATA":
        raise ValueError("retained pool member changed")
    for key in ("zpool_guid", "dataset_guid"):
        value = raw[key]
        if not isinstance(value, str) or GUID.fullmatch(value) is None or int(value) >= 2**64:
            raise ValueError("invalid retained GUID")
    return PoolRecord(
        version=1,
        serial="KTLILLY-DATA",
        zpool_guid=raw["zpool_guid"],
        dataset_guid=raw["dataset_guid"],
    )


def measured_pool(*, repair_root_policy: bool = False) -> PoolRecord:
    """@cc [owner:ghuntley,label:storage;recovery] integrated-host-no-recreate
    A retained record MUST bind the exact member and both observed GUIDs.
    First creation MUST require a blank fixed member; missing or changed state
    MUST fail before enrollment or Lilly startup.
    """
    disk_identity()
    if MANIFEST.exists():
        record = load_record()
        try:
            current = guid("zpool", POOL)
        except subprocess.CalledProcessError:
            run(["zpool", "import", "-d", "/dev/disk/by-id", record["zpool_guid"]], 90)
            current = guid("zpool", POOL)
        if current != record["zpool_guid"] or guid("zfs", DATASET) != record["dataset_guid"]:
            raise ValueError("retained pool identity changed")
    else:
        if run(["wipefs", "-n", str(DISK.resolve())]):
            raise ValueError("unowned nonempty ZFS member")
        run(
            [
                "zpool",
                "create",
                "-o",
                "ashift=12",
                "-O",
                "mountpoint=none",
                "-O",
                "compression=lz4",
                POOL,
                str(DISK),
            ],
            120,
        )
        run(["zfs", "create", "-o", "mountpoint=/pool", "-o", "compression=lz4", DATASET])
        record = PoolRecord(
            version=1,
            serial="KTLILLY-DATA",
            zpool_guid=guid("zpool", POOL),
            dataset_guid=guid("zfs", DATASET),
        )
        write_json(MANIFEST, record)
    if run(["zfs", "get", "-Hpo", "value", "mountpoint", DATASET]) != "/pool":
        raise ValueError("pool mountpoint changed")
    if not Path("/pool").is_mount():
        raise ValueError("pool is not mounted")
    if str(DISK.resolve()) not in run(["zpool", "status", "-LP", POOL]):
        raise ValueError("pool member changed")
    # The production pool validator requires compression on the owned root as
    # well as its child dataset. Repair only after retained GUID/member checks.
    if repair_root_policy and run(["zfs", "get", "-Hpo", "value", "compression", POOL]) != "lz4":
        run(["zfs", "set", "compression=lz4", POOL])
    if run(["zfs", "get", "-Hpo", "value", "compression", POOL]) != "lz4":
        raise ValueError("owned root compression unavailable")
    return record


def machine_identity() -> str:
    raw = Path("/etc/machine-id").read_text(encoding="ascii").strip()
    if re.fullmatch(r"[0-9a-f]{32}", raw) is None or raw == "0" * 32:
        raise ValueError("invalid host machine identity")
    # Frozen host identity label from before the product rename.
    digest = hmac.new(b"kittens.lilly.host.v1", bytes.fromhex(raw), hashlib.sha256).hexdigest()
    return "sha256:" + digest


def enrollment(record: PoolRecord) -> dict[str, object]:
    return {
        "version": 3,
        "name": "lilly-host",
        "architecture": "x86_64",
        "machine_id": machine_identity(),
        "overhead_cores": 0,
        "overhead_memory_bytes": 0,
        "credential_ttl_seconds": 86400,
        "pools": [
            {
                "name": "antithesis-host",
                "storage": {
                    "backend": "zfs",
                    "zpool_guid": record["zpool_guid"],
                    "dataset_guid": record["dataset_guid"],
                    "dataset": DATASET,
                },
                "overhead_bytes": 0,
            }
        ],
    }


def prepare() -> None:
    record = measured_pool(repair_root_policy=True)
    expected = enrollment(record)
    if ENROLLMENT.exists():
        if read_json(ENROLLMENT) != expected:
            raise ValueError("retained enrollment request changed")
    else:
        write_json(ENROLLMENT, expected)


def activate(private_services: bool = False) -> None:
    """@cc [owner:ghuntley,label:security;capacity] integrated-host-private-binding
    Runtime config MUST be written only after live GUID observation equals the
    published enrollment and a private credential and pool ID are present.
    Unknown or stale inputs MUST leave Lilly stopped.
    """
    record = measured_pool()
    if read_json(ENROLLMENT) != enrollment(record):
        raise ValueError("enrollment no longer matches measured pool")
    deadline = time.monotonic() + 180
    while not all(path.is_file() and path.stat().st_size > 0 for path in (CREDENTIAL, POOL_ID, CA)):
        if time.monotonic() >= deadline:
            raise ValueError("issued host credential unavailable")
        time.sleep(1)
    credential = read_json(CREDENTIAL)
    if not isinstance(credential, dict):
        raise ValueError("invalid issued credential")
    host_id = credential.get("host_id")
    pool_id = POOL_ID.read_text(encoding="ascii").strip()
    if (
        not isinstance(host_id, str)
        or UUID.fullmatch(host_id) is None
        or UUID.fullmatch(pool_id) is None
    ):
        raise ValueError("invalid enrolled host or pool identity")
    metadata = read_json(Path("/etc/overalls-lilly-release.json"))
    if not isinstance(metadata, dict):
        raise ValueError("invalid Lilly release metadata")
    tools: dict[str, str] = {}
    for name in ("firecracker", "jailer", "unshare"):
        value = metadata.get(name)
        if (
            not isinstance(value, str)
            or not value.startswith("/nix/store/")
            or not os.access(value, os.X_OK)
        ):
            raise ValueError("missing canonical Lilly tool")
        tools[name] = value
    for path in (
        Path("/var/lib/lilly/control"),
        Path("/var/lib/lilly/vm"),
        Path("/var/lib/lilly/network"),
    ):
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    config: dict[str, object] = {
        "version": 4,
        "control_plane": "https://marshall-a:5443",
        "host_id": host_id,
        "credential_file": str(CREDENTIAL),
        "cacertfile": str(CA),
        "state_dir": "/var/lib/lilly/control",
        "cgroup_path": "/sys/fs/cgroup/lilly.slice",
        "images": [Path("/etc/overalls-host-guest-image-path").read_text(encoding="ascii").strip()],
        "pools": [
            {
                "id": pool_id,
                "path": "/pool",
                "filesystem_id": "zfs:" + record["zpool_guid"] + ":" + record["dataset_guid"],
                "storage": {
                    "backend": "zfs",
                    "zpool_guid": record["zpool_guid"],
                    "dataset_guid": record["dataset_guid"],
                    "dataset": DATASET,
                },
            }
        ],
        "execution": {
            "state_dir": "/var/lib/lilly/vm",
            "network_state_dir": "/var/lib/lilly/network",
            "egress_interface": "eth0",
            "protected_cidrs": [],
            "firecracker": tools["firecracker"],
            "jailer": tools["jailer"],
            "unshare": tools["unshare"],
            "audi_ingress": False,
            "private_services": False,
            "guest_trust_roots": [],
            "brady": None,
            "firecracker_logging": False,
            "provisioning_readiness": False,
            "inception_smtp_file": None,
            "inception_image_id": None,
            "inception_proof_file": None,
            "inception_probe_id": None,
        },
    }
    if private_services:
        root = STATE / "private-ca.crt"
        if not root.is_file() or not 1 <= root.stat().st_size <= 16384:
            raise ValueError("private guest root unavailable")
        execution = config["execution"]
        if not isinstance(execution, dict):
            raise ValueError("invalid execution configuration")
        execution["private_services"] = True
        execution["guest_trust_roots"] = [str(root)]
        config["ingress"] = {"path": "/run/lilly-ingress/audi.sock", "audi_uid": 991}
    write_json(CONFIG, config)


def control_status() -> dict[str, object]:
    """A missing or malformed status can never establish connection readiness."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(3)
            connection.connect("/run/lilly-host/status.sock")
            chunks = bytearray()
            while not chunks.endswith(b"\n"):
                received = connection.recv(4096)
                if not received:
                    raise ValueError("incomplete Lilly status")
                chunks.extend(received)
                if len(chunks) > 131072:
                    raise ValueError("oversized Lilly status")
        status: object = json.loads(chunks)
        return status if isinstance(status, dict) else {}
    except (OSError, ValueError):
        return {}


def observe() -> dict[str, object]:
    """@cc [owner:ghuntley,label:capacity;verification] inner-physical-observation
    A successful sample MUST contain current native ZFS GUID, capacity and
    cgroup values from this kernel. Failed physical reads MUST publish explicit
    unavailable state; a lost Control socket may only clear readiness.
    """
    record = measured_pool()
    available = int(run(["zfs", "get", "-Hpo", "value", "available", DATASET]))
    used = int(run(["zfs", "get", "-Hpo", "value", "used", DATASET]))
    referenced = int(run(["zfs", "get", "-Hpo", "value", "referenced", DATASET]))
    pool_values = run(["zpool", "list", "-Hp", "-o", "size,free", POOL]).split()
    if len(pool_values) != 2:
        raise ValueError("invalid native pool sample")
    pool_size, pool_free = (int(value) for value in pool_values)
    if min(available, used, referenced, pool_size, pool_free) < 0:
        raise ValueError("invalid native capacity sample")
    memory_limit_raw = (
        Path("/sys/fs/cgroup/lilly.slice/memory.max").read_text(encoding="ascii").strip()
    )
    memory_limit = None if memory_limit_raw == "max" else int(memory_limit_raw)
    memory_current = int(
        Path("/sys/fs/cgroup/lilly.slice/memory.current").read_text(encoding="ascii")
    )
    cpu_limit_raw = Path("/sys/fs/cgroup/lilly.slice/cpu.max").read_text(encoding="ascii").split()
    if len(cpu_limit_raw) != 2:
        raise ValueError("invalid native CPU limit")
    cpu_quota = None if cpu_limit_raw[0] == "max" else int(cpu_limit_raw[0])
    cpu_period = int(cpu_limit_raw[1])
    if (
        (memory_limit is not None and memory_limit <= 0)
        or memory_current < 0
        or (cpu_quota is not None and cpu_quota <= 0)
        or cpu_period <= 0
    ):
        raise ValueError("invalid native cgroup limit")
    status = control_status()
    boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
    if UUID.fullmatch(boot_id) is None:
        raise ValueError("invalid inner host boot identity")
    return {
        "version": 1,
        "sampled_at_ns": time.time_ns(),
        "boot_id": boot_id,
        "zpool_guid": record["zpool_guid"],
        "dataset_guid": record["dataset_guid"],
        "dataset": DATASET,
        "available_bytes": available,
        "used_bytes": used,
        "referenced_bytes": referenced,
        "zpool_total_bytes": pool_size,
        "zpool_free_bytes": pool_free,
        "memory_limit_bytes": memory_limit,
        "memory_current_bytes": memory_current,
        "cpu_quota_us": cpu_quota,
        "cpu_period_us": cpu_period,
        "connected": status.get("version") == 1
        and status.get("phase") == "connected"
        and status.get("protocol_version") == 4
        and status.get("terminal_ready") is True,
        "execution_ready": status.get("ready") is True,
    }


def observation_failure(error: OSError | ValueError | subprocess.SubprocessError) -> str:
    """Return only closed diagnostic codes, never native command output or paths."""
    paths = {
        "/sys/fs/cgroup/lilly.slice/memory.max": "memory_limit_unavailable",
        "/sys/fs/cgroup/lilly.slice/memory.current": "memory_usage_unavailable",
        "/sys/fs/cgroup/lilly.slice/cpu.max": "cpu_limit_unavailable",
    }
    if isinstance(error, OSError):
        return paths.get(error.filename, "native_io_unavailable")
    if isinstance(error, subprocess.SubprocessError):
        return "native_tool_unavailable"
    return "native_identity_or_value_invalid"


def diagnostic_sample() -> dict[str, object]:
    """@cc [owner:ghuntley,label:security;verification] host-closed-startup-diagnostics
    Startup observations MUST contain only fixed unit names and closed state
    values. They MUST NOT include journal messages, config, keys or payloads,
    and MUST NOT substitute for authenticated Control or execution readiness.
    """
    units: dict[str, str] = {}
    for unit in ("lilly", "lilly-private-config", "ziggy", "galileo", "audi-private"):
        state = "unavailable"
        with contextlib.suppress(OSError, ValueError, subprocess.SubprocessError):
            observed = run(
                ["systemctl", "show", unit + ".service", "-p", "ActiveState", "--value"], 3
            )
            if observed in {
                "active",
                "inactive",
                "failed",
                "activating",
                "deactivating",
                "reloading",
                "maintenance",
                "refreshing",
            }:
                state = observed
        units[unit] = state
    root_compression = "unavailable"
    with contextlib.suppress(OSError, ValueError, subprocess.SubprocessError):
        compression = run(["zfs", "get", "-Hpo", "value", "compression", POOL], 3)
        if compression in {"lz4", "off", "on"}:
            root_compression = compression
    forwarding = "unavailable"
    with contextlib.suppress(OSError, ValueError):
        value = Path("/proc/sys/net/ipv4/ip_forward").read_text(encoding="ascii").strip()
        if value in {"0", "1"}:
            forwarding = value
    return {
        "version": 1,
        "sampled_at_ns": time.time_ns(),
        "units": units,
        "root_compression": root_compression,
        "ipv4_forwarding": forwarding,
    }


def monitor() -> None:
    while True:
        try:
            sample = observe()
            write_json(HEALTH, sample)
            write_json(OBSERVATION, sample)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            unavailable: dict[str, object] = {
                "version": 1,
                "connected": False,
                "state": "unavailable",
                "reason": observation_failure(error),
            }
            write_json(HEALTH, unavailable)
            write_json(OBSERVATION, unavailable)
        write_json(OBSERVATION.with_name("diagnostics.json"), diagnostic_sample())
        time.sleep(3)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("prepare", "activate", "monitor"))
    parser.add_argument("--private-services", action="store_true")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare()
    elif args.command == "activate":
        activate(args.private_services)
    else:
        monitor()


if __name__ == "__main__":
    main()
