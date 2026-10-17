"""Independent inner-Linux ZFS and cgroup observation, shared read-only."""

import json
import re
import stat
import time
from dataclasses import dataclass
from pathlib import Path
from typing import TypeGuard
from uuid import UUID

from admission.capacity import CapacityFrame
from core.outcome import Observation

_DECIMAL = re.compile(r"[1-9][0-9]*\Z")


@dataclass(frozen=True)
class PhysicalSample:
    sampled_at_ns: int
    boot_id: UUID
    zpool_guid: str
    dataset_guid: str
    dataset: str
    available_bytes: int
    used_bytes: int
    referenced_bytes: int
    zpool_total_bytes: int
    zpool_free_bytes: int
    memory_limit_bytes: int | None
    memory_current_bytes: int
    cpu_quota_us: int | None
    cpu_period_us: int

    def identifies(self, frame: CapacityFrame) -> bool:
        return (
            self.zpool_guid == frame.zpool_guid
            and self.dataset_guid == frame.dataset_guid
            and self.dataset == frame.dataset
        )

    def matches(self, frame: CapacityFrame) -> bool:
        """@cc [owner:ghuntley,label:capacity;verification] physical-zfs-independent-witness
        A capacity frame MUST name the independently observed live ZFS dataset
        and pool GUIDs. SQL free credit MUST not exceed this sample's actual
        available bytes. A missing, stale or identity-mismatched sample is
        unknown, never a passing physical-capacity assertion.
        """
        return (
            self.identifies(frame)
            and frame.free_bytes <= self.available_bytes
            and self.available_bytes <= self.zpool_free_bytes
            and self.zpool_free_bytes <= self.zpool_total_bytes
        )


def read_sample(path: Path, *, max_age_ns: int = 10_000_000_000) -> Observation[PhysicalSample]:
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > 4096:
            return Observation.unavailable()
        parsed: object = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return Observation.unavailable()
    if not isinstance(parsed, dict) or parsed.get("version") != 1:
        return Observation.unavailable()
    if parsed.get("connected") is not True or parsed.get("execution_ready") is not True:
        return Observation.unavailable()
    sampled_at = parsed.get("sampled_at_ns")
    boot = parsed.get("boot_id")
    zpool_guid = parsed.get("zpool_guid")
    dataset_guid = parsed.get("dataset_guid")
    dataset = parsed.get("dataset")
    available = parsed.get("available_bytes")
    used = parsed.get("used_bytes")
    referenced = parsed.get("referenced_bytes")
    total = parsed.get("zpool_total_bytes")
    free = parsed.get("zpool_free_bytes")
    memory_limit = parsed.get("memory_limit_bytes")
    memory_current = parsed.get("memory_current_bytes")
    cpu_quota = parsed.get("cpu_quota_us")
    cpu_period = parsed.get("cpu_period_us")
    if (
        not _nonnegative_int(sampled_at)
        or sampled_at == 0
        or not isinstance(boot, str)
        or not isinstance(zpool_guid, str)
        or _DECIMAL.fullmatch(zpool_guid) is None
        or not isinstance(dataset_guid, str)
        or _DECIMAL.fullmatch(dataset_guid) is None
        or not isinstance(dataset, str)
        or not dataset
        or not _nonnegative_int(available)
        or not _nonnegative_int(used)
        or not _nonnegative_int(referenced)
        or not _nonnegative_int(total)
        or not _nonnegative_int(free)
        or (memory_limit is not None and not _nonnegative_int(memory_limit))
        or not _nonnegative_int(memory_current)
        or (cpu_quota is not None and not _nonnegative_int(cpu_quota))
        or not _nonnegative_int(cpu_period)
        or cpu_period == 0
    ):
        return Observation.unavailable()
    age = time.time_ns() - sampled_at
    if not 0 <= age <= max_age_ns:
        return Observation.unavailable()
    try:
        boot_id = UUID(boot)
    except ValueError:
        return Observation.unavailable()
    return Observation.observed(
        PhysicalSample(
            sampled_at,
            boot_id,
            zpool_guid,
            dataset_guid,
            dataset,
            available,
            used,
            referenced,
            total,
            free,
            memory_limit,
            memory_current,
            cpu_quota,
            cpu_period,
        )
    )


def _nonnegative_int(value: object) -> TypeGuard[int]:
    return type(value) is int and value >= 0
