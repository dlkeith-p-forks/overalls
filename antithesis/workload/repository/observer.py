"""Narrow passive snapshot of native Enrico Git lock inode holders."""

import json
import time
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID

from core.outcome import Observation


@dataclass(frozen=True)
class SlotHolder:
    slot: int
    device: int
    inode: int
    holder_pids: tuple[int, ...]


@dataclass(frozen=True)
class RepositoryHolder:
    repository_id: UUID
    device: int
    inode: int
    holder_pids: tuple[int, ...]


@dataclass(frozen=True)
class NativeSnapshot:
    generation: int
    observed_at_unix_ms: int
    slots: tuple[SlotHolder, ...]
    repositories: tuple[RepositoryHolder, ...]


def read_snapshot(path: Path, generation: int) -> Observation[NativeSnapshot]:
    """@cc [owner:ghuntley,label:verification] enrico-observer-current-complete
    Only a complete passive snapshot for the exact restarted service generation
    and a recent observation time may ground a native admission assertion.
    Missing, stale, malformed or incomplete snapshots MUST remain unknown.
    """
    try:
        data = path.read_bytes()
        if len(data) > 16_384:
            return Observation.unavailable()
        parsed: object = json.loads(data)
    except (OSError, UnicodeError, json.JSONDecodeError):
        return Observation.unavailable()
    if not isinstance(parsed, dict) or set(parsed) != {
        "version",
        "generation",
        "observed_at_unix_ms",
        "complete",
        "slots",
        "repositories",
    }:
        return Observation.unavailable()
    stamp = parsed["observed_at_unix_ms"]
    now = time.time_ns() // 1_000_000
    if (
        type(parsed["version"]) is not int
        or parsed["version"] != 1
        or type(parsed["generation"]) is not int
        or parsed["generation"] != generation
        or parsed["complete"] is not True
        or type(stamp) is not int
        or not 0 <= now - stamp <= 5000
        or not isinstance(parsed["slots"], list)
        or not isinstance(parsed["repositories"], list)
        or len(parsed["repositories"]) > 128
    ):
        return Observation.unavailable()
    slots: list[SlotHolder] = []
    seen_slots: set[int] = set()
    seen_inodes: set[tuple[int, int]] = set()
    for item in parsed["slots"]:
        if not isinstance(item, dict) or set(item) != {"slot", "device", "inode", "holder_pids"}:
            return Observation.unavailable()
        slot, device, inode, raw_pids = (
            item["slot"],
            item["device"],
            item["inode"],
            item["holder_pids"],
        )
        if (
            type(slot) is not int
            or not 0 <= slot < 8
            or slot in seen_slots
            or type(device) is not int
            or device < 0
            or type(inode) is not int
            or inode < 1
            or (device, inode) in seen_inodes
            or not isinstance(raw_pids, list)
            or any(type(pid) is not int or pid < 1 for pid in raw_pids)
            or len(raw_pids) != len(set(raw_pids))
            or raw_pids != sorted(raw_pids)
        ):
            return Observation.unavailable()
        seen_slots.add(slot)
        seen_inodes.add((device, inode))
        slots.append(SlotHolder(slot, device, inode, tuple(raw_pids)))
    if len(slots) != 8:
        return Observation.unavailable()
    repositories: list[RepositoryHolder] = []
    seen_repositories: set[UUID] = set()
    for item in parsed["repositories"]:
        if not isinstance(item, dict) or set(item) != {
            "repository_id",
            "device",
            "inode",
            "holder_pids",
        }:
            return Observation.unavailable()
        name, device, inode, raw_pids = (
            item["repository_id"],
            item["device"],
            item["inode"],
            item["holder_pids"],
        )
        if not isinstance(name, str):
            return Observation.unavailable()
        try:
            repository_id = UUID(name)
        except ValueError:
            return Observation.unavailable()
        if (
            str(repository_id) != name
            or repository_id in seen_repositories
            or type(device) is not int
            or device < 0
            or type(inode) is not int
            or inode < 1
            or not isinstance(raw_pids, list)
            or any(type(pid) is not int or pid < 1 for pid in raw_pids)
            or len(raw_pids) != len(set(raw_pids))
            or raw_pids != sorted(raw_pids)
        ):
            return Observation.unavailable()
        seen_repositories.add(repository_id)
        repositories.append(RepositoryHolder(repository_id, device, inode, tuple(raw_pids)))
    return Observation.observed(
        NativeSnapshot(generation, stamp, tuple(slots), tuple(repositories))
    )
