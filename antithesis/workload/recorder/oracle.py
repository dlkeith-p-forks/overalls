"""Independent read-only checkpoint, effect, and SQLite custody witnesses."""

import hashlib
import json
import sqlite3
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ProducerIdentity:
    pid: int
    start_ticks: int
    boot_id: str


@dataclass(frozen=True)
class RecorderState:
    incarnation: str
    next_id: int
    pending: frozenset[int]
    deadline_ns: dict[int, int]
    producers: dict[int, ProducerIdentity]
    requests: int
    successes: int
    failures: int
    excluded: int
    duration_count: int
    bucket_counts: tuple[int, ...]
    coverage_started_at_ns: int


@dataclass(frozen=True)
class Batch:
    digest: str
    body_sha256: str
    accepted_ns: int
    expires_ns: int
    pending: bool


def _record(value: object, fields: set[str]) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ValueError("invalid witness record")
    result: dict[str, object] = value
    if not fields.issubset(result):
        raise ValueError("incomplete witness record")
    return result


def _number(value: object) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ValueError("invalid witness number")
    return value


def read_recorder(path: Path) -> RecorderState:
    """Validate the recorder's actual fsynced JSON checkpoint."""
    parsed: object = json.loads(path.read_text(encoding="utf-8"))
    root = _record(
        parsed,
        {"incarnation", "next_id", "pending", "totals", "excluded", "coverage_started_at_ns"},
    )
    pending = _record(root["pending"], set())
    totals = _record(
        root["totals"],
        {"requests", "successes", "failures", "duration_count", "bucket_counts"},
    )
    identity = root["incarnation"]
    if not isinstance(identity, str) or len(identity) != 32:
        raise ValueError("invalid recorder identity")
    deadlines: dict[int, int] = {}
    producers: dict[int, ProducerIdentity] = {}
    for key, value in pending.items():
        if not key.isdecimal():
            raise ValueError("invalid admission identifier")
        admission = _record(value, {"deadline_ns", "producer"})
        producer = _record(admission["producer"], {"pid", "start_ticks", "boot_id"})
        boot = producer["boot_id"]
        if not isinstance(boot, str) or len(boot) != 36:
            raise ValueError("invalid producer boot identity")
        numeric_id = int(key)
        deadlines[numeric_id] = _number(admission["deadline_ns"])
        producers[numeric_id] = ProducerIdentity(
            _number(producer["pid"]), _number(producer["start_ticks"]), boot
        )
    buckets = totals["bucket_counts"]
    if not isinstance(buckets, list) or len(buckets) != 8:
        raise ValueError("invalid duration buckets")
    return RecorderState(
        identity,
        _number(root["next_id"]),
        frozenset(deadlines),
        deadlines,
        producers,
        _number(totals["requests"]),
        _number(totals["successes"]),
        _number(totals["failures"]),
        _number(root["excluded"]),
        _number(totals["duration_count"]),
        tuple(_number(item) for item in buckets),
        _number(root["coverage_started_at_ns"]),
    )


def read_effects(path: Path) -> tuple[int, ...]:
    """Only complete fsynced numeric lines count as witnessed fixture effects."""
    raw = path.read_bytes()
    if raw and not raw.endswith(b"\n"):
        raise ValueError("incomplete effect ledger")
    result = tuple(int(line) for line in raw.splitlines())
    if any(value < 1 for value in result) or len(result) != len(set(result)):
        raise ValueError("invalid effect ledger")
    return result


def read_archive(path: Path) -> dict[str, Batch]:
    """Read a consistent snapshot of real sanitized SQLite bodies and pending index."""
    if not path.is_file():
        raise FileNotFoundError(path)
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=1)
    try:
        connection.execute("BEGIN")
        rows = connection.execute(
            "SELECT b.id,b.body,b.accepted_ns,b.expires_ns,p.id IS NOT NULL "
            "FROM batches AS b LEFT JOIN pending AS p ON p.id=b.id"
        ).fetchall()
        result: dict[str, Batch] = {}
        for digest, body, accepted, expires, pending in rows:
            if (
                not isinstance(digest, str)
                or len(digest) != 64
                or not isinstance(body, bytes)
                or not isinstance(accepted, int)
                or not isinstance(expires, int)
                or accepted <= 0
                or expires <= accepted
            ):
                raise ValueError("invalid archived batch")
            actual = hashlib.sha256(body).hexdigest()
            if actual != digest:
                raise ValueError("archive digest mismatch")
            result[digest] = Batch(digest, actual, accepted, expires, bool(pending))
        connection.execute("COMMIT")
        return result
    finally:
        connection.close()
