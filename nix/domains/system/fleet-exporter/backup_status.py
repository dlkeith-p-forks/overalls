"""Closed, typed projection of private backup status into fleet observations."""

from __future__ import annotations

import json
from typing import Protocol, TypedDict

MAX_INTEGER = 2**63 - 1
GAUGES = (
    "started_at",
    "completed_at",
    "last_success_at",
    "duration_seconds",
    "guests_total",
    "guests_completed",
    "guests_failed",
    "flush_unconfirmed",
    "cleanup_pending",
    "updated_at",
)
STATES = {"never-run", "running", "healthy", "degraded", "failed"}
FAILURES = {
    "none",
    "capture",
    "database",
    "upload",
    "cleanup",
    "retention",
    "credentials",
    "repository",
    "interrupted",
    "configuration",
}


class Reader(Protocol):
    def exists(self, path: str) -> bool: ...
    def read(self, path: str) -> str: ...


class Record(TypedDict):
    kind: str
    id: str
    context: dict[str, str]
    gauges: dict[str, int]
    counters: dict[str, int]


def backup_status(reader: Reader, enabled: bool, now: float) -> Record:
    """@cc [owner:ghuntley,label:security;recovery] backup-status-safe-projection
    Only fixed backup labels and bounded nonnegative integers may leave the host.
    Missing/corrupt observations MUST NOT imply success. Old success and stalled
    running reports MUST become stale, without discarding the last-success time.
    """
    context = {"backup_state": "disabled", "backup_failure": "none"}
    gauges: dict[str, int] = {}
    if enabled:
        context["backup_state"] = "unknown"
        path = "/var/lib/overalls-backups/status.json"
        try:
            present = reader.exists(path)
        except OSError:
            return Record(kind="backup", id="backup", context=context, gauges={}, counters={})
        if not present:
            context["backup_state"] = "never-run"
        else:
            try:
                value: object = json.loads(reader.read(path))
                if not isinstance(value, dict):
                    raise ValueError("invalid_backup_status")
                version, state, failure = (
                    value.get("version"),
                    value.get("state"),
                    value.get("failure"),
                )
                if (
                    type(version) is not int
                    or version != 1
                    or not isinstance(state, str)
                    or state not in STATES
                    or not isinstance(failure, str)
                    or failure not in FAILURES
                ):
                    raise ValueError("invalid_backup_status")
                for key in GAUGES:
                    number: object = value.get(key)
                    if number is not None:
                        if type(number) is not int or not 0 <= number <= MAX_INTEGER:
                            raise ValueError("invalid_backup_status")
                        gauges[key] = number
                if any(
                    gauges.get(key, 0) > now + 30
                    for key in ("started_at", "completed_at", "last_success_at", "updated_at")
                ):
                    raise ValueError("invalid_backup_status")
                context.update(backup_state=state, backup_failure=failure)
                if (
                    state in {"healthy", "degraded"}
                    and (
                        not gauges.get("last_success_at") or now - gauges["last_success_at"] > 3600
                    )
                ) or (state == "running" and now - gauges.get("updated_at", 0) > 120):
                    context["backup_state"] = "stale"
            except (OSError, ValueError, TypeError, KeyError):
                context, gauges = {"backup_state": "unknown", "backup_failure": "none"}, {}
    return Record(kind="backup", id="backup", context=context, gauges=gauges, counters={})
