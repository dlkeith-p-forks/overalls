"""Read-only observation of Ziggy's fixed-size durable metadata slots."""

import json
import os
import stat
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID

from core.outcome import Observation

SLOT_BYTES = 16_384


@dataclass(frozen=True)
class Slot:
    request_id: UUID
    vm_id: UUID
    owner_id: UUID
    provider: str
    model: str
    completed: bool
    completeness: str | None


def read_slots(directory: Path, maximum: int) -> Observation[tuple[Slot, ...]]:
    """@cc [owner:ghuntley,label:verification;security] spool-observation-uncertain
    A slot MUST be accepted only from a regular 16,384-byte on-disk file whose
    filename matches its admission ID. A changing or unreadable directory MUST
    return unavailable, never a claimed empty or bounded spool. No payload is
    copied into assertion details or diagnostics.
    """
    if not directory.is_absolute() or not 1 <= maximum <= 100_000:
        raise ValueError("invalid spool observation configuration")
    try:
        names = tuple(
            sorted(entry.name for entry in directory.iterdir() if entry.name.endswith(".json"))
        )
        if len(names) > maximum:
            return Observation.unavailable()
        slots: list[Slot] = []
        for name in names:
            request_id = UUID(name.removesuffix(".json"))
            if name != f"{request_id}.json":
                return Observation.unavailable()
            descriptor = os.open(directory / name, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                before = os.fstat(descriptor)
                if not stat.S_ISREG(before.st_mode) or before.st_size != SLOT_BYTES:
                    return Observation.unavailable()
                data = os.read(descriptor, SLOT_BYTES + 1)
                after = os.fstat(descriptor)
                if (
                    len(data) != SLOT_BYTES
                    or before.st_ino != after.st_ino
                    or before.st_mtime_ns != after.st_mtime_ns
                ):
                    return Observation.unavailable()
            finally:
                os.close(descriptor)
            current = (directory / name).stat(follow_symlinks=False)
            if (
                not stat.S_ISREG(current.st_mode)
                or current.st_ino != after.st_ino
                or current.st_mtime_ns != after.st_mtime_ns
                or current.st_size != SLOT_BYTES
            ):
                return Observation.unavailable()
            length = int.from_bytes(data[:4], "big")
            if length < 2 or length > SLOT_BYTES - 4:
                return Observation.unavailable()
            decoded: object = json.loads(data[4 : 4 + length])
            if not isinstance(decoded, dict):
                return Observation.unavailable()
            admission, completion = decoded.get("admission"), decoded.get("completion")
            if not isinstance(admission, dict) or (
                completion is not None and not isinstance(completion, dict)
            ):
                return Observation.unavailable()
            raw_vm, raw_owner = admission.get("vm_id"), admission.get("owner_id")
            provider, model = admission.get("provider"), admission.get("model")
            if (
                admission.get("request_id") != str(request_id)
                or not isinstance(raw_vm, str)
                or not isinstance(raw_owner, str)
                or provider not in ("openai", "anthropic")
                or not isinstance(model, str)
            ):
                return Observation.unavailable()
            completeness: str | None = None
            if isinstance(completion, dict):
                value = completion.get("completeness")
                if value not in ("complete", "partial", "unknown"):
                    return Observation.unavailable()
                completeness = value
            slots.append(
                Slot(
                    request_id,
                    UUID(raw_vm),
                    UUID(raw_owner),
                    provider,
                    model,
                    completion is not None,
                    completeness,
                )
            )
        if (
            tuple(
                sorted(entry.name for entry in directory.iterdir() if entry.name.endswith(".json"))
            )
            != names
        ):
            return Observation.unavailable()
        return Observation.observed(tuple(slots))
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return Observation.unavailable()
