"""Independent post-effect Linux/ZFS/Brady observations for the router fixture."""

import hashlib
import json
import os
import subprocess
from pathlib import Path
from typing import TypedDict

MIRROR = Path("/var/lib/router-storage/mirror.json")
MARKERS = Path("/pool/markers")
ORIGIN = Path("/var/lib/router-storage/origin-effects.jsonl")
CACHE = Path("/var/cache/brady/objects")


class Marker(TypedDict):
    id: str
    bytes: int
    sha256: str


def command(argv: list[str]) -> str:
    result = subprocess.run(argv, capture_output=True, text=True, timeout=15, check=True)
    if len(result.stdout) > 65536:
        raise ValueError("oversized oracle command")
    return result.stdout.strip()


def read_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="ascii"))


def marker(id_value: str) -> Marker:
    path = MARKERS / id_value
    data = path.read_bytes()
    return Marker(id=id_value, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())


def write_marker(id_value: str) -> Marker:
    """@cc [owner:ghuntley,label:storage;verification] fsynced-router-marker
    Acknowledgment follows fsync of fixed, deterministic bytes and the parent
    directory. Reboot evidence comes from a new guest observation.
    """
    MARKERS.mkdir(mode=0o700, exist_ok=True)
    data = b"overalls-router-marker-v1:" + id_value.encode("ascii")
    path = MARKERS / id_value
    if path.exists() and path.read_bytes() != data:
        raise ValueError("marker identity collision")
    with path.open("wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    directory = os.open(MARKERS, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    command(["zpool", "sync", "tank"])
    return marker(id_value)


def cache_objects() -> list[dict[str, object]]:
    objects: list[dict[str, object]] = []
    if not CACHE.exists():
        return objects
    for body in sorted(CACHE.rglob("body")):
        if body.is_symlink() or not body.is_file():
            raise ValueError("nonregular cache body")
        digest = hashlib.sha256()
        length = 0
        with body.open("rb") as stream:
            while chunk := stream.read(65536):
                length += len(chunk)
                if length > 256 * 1024 * 1024:
                    raise ValueError("oversized cache body")
                digest.update(chunk)
        objects.append({"bytes": length, "sha256": digest.hexdigest()})
        if len(objects) > 256:
            raise ValueError("too many fixture cache objects")
    return objects


def origin_effects() -> dict[str, int]:
    counts: dict[str, int] = {}
    if not ORIGIN.exists():
        raise FileNotFoundError("origin effect journal unavailable")
    with ORIGIN.open(encoding="ascii") as stream:
        for index, line in enumerate(stream):
            if index >= 4096:
                raise ValueError("origin journal bound exceeded")
            entry: object = json.loads(line)
            if not isinstance(entry, dict) or set(entry) != {"kind", "scheme"}:
                raise ValueError("invalid origin record")
            kind, scheme = entry["kind"], entry["scheme"]
            if kind not in ("public", "large", "private") or scheme not in ("http", "https"):
                raise ValueError("invalid origin effect")
            key = f"{scheme}:{kind}"
            counts[key] = counts.get(key, 0) + 1
    return counts


def nft_counters(namespace: str) -> dict[str, int]:
    parsed: object = json.loads(
        command(["ip", "netns", "exec", namespace, "nft", "-j", "list", "ruleset"])
    )
    if not isinstance(parsed, dict) or not isinstance(parsed.get("nftables"), list):
        raise ValueError("invalid nft ruleset")
    counts = {"rules": 0, "packets": 0}
    for item in parsed["nftables"]:
        if not isinstance(item, dict) or "rule" not in item or not isinstance(item["rule"], dict):
            continue
        rule = item["rule"]
        if not isinstance(rule.get("expr"), list):
            continue
        counts["rules"] += 1
        for expression in rule["expr"]:
            if isinstance(expression, dict) and isinstance(expression.get("counter"), dict):
                packets = expression["counter"].get("packets")
                if type(packets) is int and packets >= 0:
                    counts["packets"] += packets
    return counts


def observe() -> dict[str, object]:
    """@cc [owner:ghuntley,label:verification] unavailable-is-not-absence
    A failed source read raises. The controller reports unavailable rather
    than treating missing ZFS, metrics, nft or origin state as a zero result.
    """
    manifest = read_json(MIRROR)
    if not isinstance(manifest, dict):
        raise ValueError("invalid mirror manifest")
    pool_guid = command(["zpool", "get", "-Hpo", "value", "guid", "tank"])
    parent_guid = command(["zfs", "get", "-Hpo", "value", "guid", "tank/lilly"])
    cache_guid = command(["zfs", "get", "-Hpo", "value", "guid", "tank/brady"])
    if pool_guid != manifest.get("pool_guid") or parent_guid != manifest.get("parent_guid"):
        raise ValueError("retained GUID mismatch")
    if not Path("/var/cache/brady").is_mount() or not Path("/pool").is_mount():
        raise ValueError("native ZFS mount unavailable")
    pressure = read_json(Path("/run/brady-pressure/pressure.json"))
    metrics = read_json(Path("/run/brady/metrics.json"))
    if not isinstance(pressure, dict) or not isinstance(metrics, dict):
        raise ValueError("invalid Brady observation")
    boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
    return {
        "boot_id": boot_id,
        "pool_guid": pool_guid,
        "parent_guid": parent_guid,
        "cache_guid": cache_guid,
        "pool_status": command(["zpool", "list", "-H", "-o", "health", "tank"]),
        "parent_quota": int(command(["zfs", "get", "-Hpo", "value", "quota", "tank/lilly"])),
        "cache_quota": int(command(["zfs", "get", "-Hpo", "value", "quota", "tank/brady"])),
        "cache_refquota": int(command(["zfs", "get", "-Hpo", "value", "refquota", "tank/brady"])),
        "pressure": pressure,
        "metrics": metrics,
        "cache_objects": cache_objects(),
        "origin_effects": origin_effects(),
        "nft": nft_counters("lilly-bd7662a5eeb4"),
        "markers": [marker(path.name) for path in sorted(MARKERS.iterdir())]
        if MARKERS.exists()
        else [],
    }
