"""One-time owned ZFS import and fixture wiring inside the TCG router guest."""

import grp
import json
import os
import secrets
import subprocess
import sys
import time
from pathlib import Path
from typing import TypedDict

POOL = "tank"
PARENT = "tank/lilly"
CACHE = "tank/brady"
HOST_ID = "11111111-1111-4111-8111-111111111111"
DISK_A = Path("/dev/disk/by-id/virtio-KTROUTER-MIRROR-A")
DISK_B = Path("/dev/disk/by-id/virtio-KTROUTER-MIRROR-B")
STATE = Path("/var/lib/router-storage")
MANIFEST = STATE / "mirror.json"
RELEASE_ENV = Path("/run/router-release-cookie")
MIB = 1024 * 1024


class Mirror(TypedDict):
    version: int
    pool_guid: str
    parent_guid: str
    disk_serials: list[str]


def run(argv: list[str], timeout: int = 30) -> str:
    result = subprocess.run(argv, capture_output=True, text=True, check=True, timeout=timeout)
    if len(result.stdout) > 65536:
        raise ValueError("oversized native result")
    return result.stdout.strip()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_suffix(".new")
    with temporary.open("w", encoding="ascii") as stream:
        json.dump(value, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def prepare_release_cookie() -> None:
    """@cc [owner:ghuntley,label:security] antithesis-runtime-secret-custody
    Each boot creates one private release cookie in volatile runtime storage.
    Neither the value nor its environment-file contents enter the Nix closure.
    """
    cookie = secrets.token_hex(32)
    descriptor = os.open(RELEASE_ENV, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="ascii") as stream:
        stream.write("RELEASE_COOKIE=" + cookie + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(RELEASE_ENV, 0o600)
    os.environ["RELEASE_COOKIE"] = cookie


def guid(tool: str, name: str) -> str:
    return run([tool, "get", "-Hpo", "value", "guid", name])


def member_serial(path: Path, expected: str) -> None:
    # The by-id link can precede the serial field becoming visible to lsblk
    # during cold udev enumeration under TCG. Bound the wait, then refuse any
    # wrong member rather than treating temporary absence as a blank disk.
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if path.is_symlink():
            device = path.resolve()
            if device.name not in {"vdb", "vdc"}:
                raise ValueError("router disk missing or reordered")
            try:
                actual = run(["lsblk", "-dn", "-o", "SERIAL", str(device)])
                size = int(run(["blockdev", "--getsize64", str(device)]))
                if actual == expected and size == 1024**3:
                    return
            except (OSError, subprocess.SubprocessError, ValueError):
                pass
        time.sleep(0.5)
    raise ValueError("router disk identity or size changed")


def load_manifest() -> Mirror:
    raw: object = json.loads(MANIFEST.read_text(encoding="ascii"))
    if not isinstance(raw, dict) or set(raw) != {
        "version",
        "pool_guid",
        "parent_guid",
        "disk_serials",
    }:
        raise ValueError("invalid mirror record")
    if raw["version"] != 1 or raw["disk_serials"] != ["KTROUTER-MIRROR-A", "KTROUTER-MIRROR-B"]:
        raise ValueError("mirror record identity changed")
    if not isinstance(raw["pool_guid"], str) or not raw["pool_guid"].isdigit():
        raise ValueError("invalid pool GUID")
    if not isinstance(raw["parent_guid"], str) or not raw["parent_guid"].isdigit():
        raise ValueError("invalid parent GUID")
    return Mirror(
        version=1,
        pool_guid=raw["pool_guid"],
        parent_guid=raw["parent_guid"],
        disk_serials=["KTROUTER-MIRROR-A", "KTROUTER-MIRROR-B"],
    )


def setup_mirror() -> Mirror:
    """@cc [owner:ghuntley,label:storage;recovery] retained-router-mirror-custody
    First boot creates only blank, fixed-serial members. Every later boot must
    import the recorded GUID from the same members; it never forces creation.
    """
    member_serial(DISK_A, "KTROUTER-MIRROR-A")
    member_serial(DISK_B, "KTROUTER-MIRROR-B")
    if MANIFEST.exists():
        manifest = load_manifest()
        try:
            current = guid("zpool", POOL)
        except subprocess.CalledProcessError:
            run(["zpool", "import", "-d", "/dev/disk/by-id", manifest["pool_guid"]], 90)
            current = guid("zpool", POOL)
        if current != manifest["pool_guid"] or guid("zfs", PARENT) != manifest["parent_guid"]:
            raise ValueError("retained pool or parent GUID changed")
        if run(["zpool", "status", "-P", POOL]).count("/dev/disk/by-id/virtio-KTROUTER-") < 2:
            raise ValueError("recorded mirror members missing")
    else:
        if STATE.exists() and any(STATE.iterdir()):
            raise ValueError("unowned router storage state")
        for disk in (DISK_A, DISK_B):
            if run(["wipefs", "-n", str(disk.resolve())]):
                raise ValueError("nonempty unowned disk")
        run(
            [
                "zpool",
                "create",
                "-O",
                "compression=lz4",
                "-O",
                "mountpoint=none",
                POOL,
                "mirror",
                str(DISK_A),
                str(DISK_B),
            ],
            120,
        )
        run(
            [
                "zfs",
                "create",
                "-o",
                "mountpoint=/pool",
                "-o",
                "compression=lz4",
                "-o",
                "quota=268435456",
                "-o",
                "reservation=none",
                "-o",
                "refreservation=none",
                "-o",
                "sync=standard",
                PARENT,
            ]
        )
        manifest = Mirror(
            version=1,
            pool_guid=guid("zpool", POOL),
            parent_guid=guid("zfs", PARENT),
            disk_serials=["KTROUTER-MIRROR-A", "KTROUTER-MIRROR-B"],
        )
        write_json(MANIFEST, manifest)
    if run(["zfs", "get", "-Hpo", "value", "mountpoint", PARENT]) != "/pool":
        raise ValueError("guest parent mount changed")
    if not Path("/pool").is_mount():
        raise ValueError("guest parent is not mounted")
    return manifest


def setup_cache(manifest: Mirror) -> None:
    config = {
        "host_id": HOST_ID,
        "dataset": CACHE,
        "zfs": "/run/current-system/sw/bin/zfs",
        "zpool": "/run/current-system/sw/bin/zpool",
        "pool": {
            "storage": {
                "dataset": PARENT,
                "dataset_guid": manifest["parent_guid"],
                "zpool_guid": manifest["pool_guid"],
            }
        },
    }
    write_json(Path("/run/brady-storage.json"), config)
    run(["python3", "/etc/brady-storage.py", "/run/brady-storage.json"], 120)
    prepared = run(["zfs", "get", "-Hpo", "value", "quota", CACHE])
    run(["zfs", "set", "quota=67108864", "refquota=67108864", CACHE])
    values = run(["zfs", "get", "-Hpo", "value", "quota,refquota", CACHE]).splitlines()
    if values != ["67108864", "67108864"]:
        raise ValueError("fixture cache quota readback failed")
    write_json(
        Path("/run/router-cache-quota.json"),
        {"prepared_bytes": int(prepared), "fixture_bytes": 67108864},
    )


def netns(name: str) -> None:
    if not Path("/run/netns", name).exists():
        run(["ip", "netns", "add", name])


def setup_network(lilly: str) -> None:
    # The Elixir file uses Lilly.Network.Config/Guest/Policy, never authored nft
    # source from workload input. Interfaces are closed fixture identities.
    run([lilly, "eval", 'Code.eval_file("/etc/router-network.exs")'], 60)
    raw: object = json.loads(Path("/run/brady-network.json").read_text(encoding="ascii"))
    if not isinstance(raw, dict) or set(raw) != {"namespace", "guest", "guest2", "customer"}:
        raise ValueError("invalid Lilly router identities")
    namespace = raw["namespace"]
    if namespace != "lilly-bd7662a5eeb4":
        raise ValueError("unexpected Lilly namespace")
    netns(namespace)
    run(["ip", "-n", namespace, "link", "set", "lo", "up"])
    run(["ip", "netns", "exec", namespace, "sysctl", "-w", "net.ipv4.ip_forward=1"])
    # The bounded legacy topology needs loose reverse-path validation. It does
    # not claim the production owned-uplink source-validation boundary.
    run(["ip", "netns", "exec", namespace, "sysctl", "-w", "net.ipv4.conf.all.rp_filter=0"])
    for name in ("guest", "guest2", "customer"):
        entry = raw[name]
        if not isinstance(entry, dict) or set(entry) != {"tap", "address", "gateway", "mac"}:
            raise ValueError("invalid Lilly veth identity")
        tap, address, gateway, mac = (entry[key] for key in ("tap", "address", "gateway", "mac"))
        if not all(isinstance(value, str) for value in (tap, address, gateway, mac)):
            raise ValueError("invalid Lilly veth fields")
        netns(name)
        run(
            [
                "ip",
                "link",
                "add",
                tap,
                "netns",
                namespace,
                "type",
                "veth",
                "peer",
                "name",
                "eth0",
                "netns",
                name,
            ]
        )
        run(["ip", "-n", namespace, "addr", "add", gateway + "/32", "dev", tap])
        run(["ip", "-n", namespace, "link", "set", tap, "up"])
        run(["ip", "-n", namespace, "route", "add", address + "/32", "dev", tap])
        run(["ip", "-n", name, "link", "set", "eth0", "address", mac])
        run(["ip", "-n", name, "addr", "add", address + "/32", "dev", "eth0"])
        run(["ip", "-n", name, "link", "set", "eth0", "up"])
        run(["ip", "-n", name, "route", "add", gateway + "/32", "dev", "eth0"])
        run(["ip", "-n", name, "route", "add", "default", "via", gateway])
    netns("origin")
    run(
        [
            "ip",
            "link",
            "add",
            "uplink",
            "netns",
            namespace,
            "type",
            "veth",
            "peer",
            "name",
            "eth0",
            "netns",
            "origin",
        ]
    )
    for command in (
        ["ip", "-n", namespace, "addr", "add", "169.254.255.2/30", "dev", "uplink"],
        ["ip", "-n", namespace, "link", "set", "uplink", "up"],
        ["ip", "-n", namespace, "route", "add", "default", "via", "169.254.255.1"],
        ["ip", "-n", "origin", "addr", "add", "169.254.255.1/30", "dev", "eth0"],
        ["ip", "-n", "origin", "link", "set", "eth0", "up"],
        ["ip", "-n", "origin", "link", "set", "lo", "up"],
        ["ip", "-n", "origin", "addr", "add", "8.8.4.4/32", "dev", "lo"],
        ["ip", "-n", "origin", "addr", "add", "8.8.4.6/32", "dev", "lo"],
        ["ip", "netns", "exec", namespace, "nft", "-f", "/run/brady-network.nft"],
        ["ip", "-n", namespace, "route", "add", "local", "0.0.0.0/0", "dev", "lo", "table", "1111"],
        [
            "ip",
            "-n",
            namespace,
            "rule",
            "add",
            "priority",
            "1111",
            "fwmark",
            "0x42524144/0xffffffff",
            "lookup",
            "1111",
        ],
    ):
        run(command)


def setup_origin() -> None:
    run(["python3", "/etc/router-origin.py", "prepare"], 60)
    runtime = Path("/run/brady-fixture/config.json")
    raw: object = json.loads(runtime.read_text(encoding="ascii"))
    if not isinstance(raw, dict) or raw.get("cache_dataset") != CACHE:
        raise ValueError("invalid origin runtime fixture")
    raw["cache_quota_bytes"] = 67108864
    write_json(runtime, raw)
    os.chown(runtime, 0, grp.getgrnam("brady").gr_gid)
    runtime.chmod(0o640)


def main() -> None:
    if len(sys.argv) != 2 or not Path(sys.argv[1]).is_absolute():
        raise ValueError("expected exact Lilly release executable")
    prepare_release_cookie()
    mirror = setup_mirror()
    setup_cache(mirror)
    setup_network(sys.argv[1])
    setup_origin()
    print(
        json.dumps(
            {
                "event": "router_bootstrap_ready",
                "pool_guid": mirror["pool_guid"],
                "cache_quota_bytes": 67108864,
            }
        ),
        flush=True,
    )


if __name__ == "__main__":
    main()
