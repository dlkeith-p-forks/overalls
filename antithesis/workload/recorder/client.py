"""Closed recorder VM requests with independent observed-state synchronization."""

import json
import os
import secrets
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path

from recorder.oracle import Batch


@dataclass(frozen=True)
class Config:
    requests: Path
    results: Path
    observation: Path
    ledger: Path

    @classmethod
    def from_environment(cls) -> "Config":
        names = (
            "ANTITHESIS_RECORDER_REQUESTS",
            "ANTITHESIS_RECORDER_RESULTS",
            "ANTITHESIS_RECORDER_OBSERVATION",
            "ANTITHESIS_RECORDER_LEDGER",
        )
        paths = tuple(Path(os.environ[name]) for name in names)
        if any(not path.is_absolute() or ".." in path.parts for path in paths):
            raise ValueError("recorder paths must be absolute without parent traversal")
        return cls(*paths)

    @property
    def checkpoint(self) -> Path:
        return self.observation / "state.json"

    @property
    def quality(self) -> Path:
        return self.observation / "quality"

    @property
    def effects(self) -> Path:
        return self.observation / "effects.log"

    @property
    def archive(self) -> Path:
        return self.observation / "archive.sqlite"


@dataclass(frozen=True)
class Reply:
    status: str
    admitted: tuple[int, ...] = ()
    attempted: int = 0
    last_effect: int = 0
    finished: int = 0


@dataclass(frozen=True)
class ControlReply:
    status: str
    enospc: bool = False


@dataclass(frozen=True)
class Identity:
    pid: int
    uid: int
    start_ticks: int
    cgroup: str


@dataclass(frozen=True)
class Filesystem:
    archive_device: int
    root_device: int
    free_bytes: int
    total_bytes: int


@dataclass(frozen=True)
class Status:
    sample_ns: int
    producer: bool
    recorder: bool
    spool: bool
    archive: bool


def _integer(value: object) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ValueError("invalid recorder integer")
    return value


def _record(raw: bytes) -> dict[str, object]:
    parsed: object = json.loads(raw)
    if not isinstance(parsed, dict) or not all(isinstance(key, str) for key in parsed):
        raise ValueError("invalid recorder record")
    return parsed


def _reply(record: dict[str, object]) -> Reply:
    status = record.get("status")
    if not isinstance(status, str) or status not in (
        "ok",
        "unknown",
        "invalid",
        "unavailable",
        "uncertain",
        "200",
        "400",
        "403",
        "429",
        "503",
    ):
        raise ValueError("invalid producer status")
    admitted = record.get("admitted", [])
    if not isinstance(admitted, list) or len(admitted) > 128:
        raise ValueError("invalid admission response")
    return Reply(
        status,
        tuple(_integer(item) for item in admitted),
        _integer(record.get("attempted", 0)),
        _integer(record.get("last_effect", 0)),
        _integer(record.get("finished", 0)),
    )


def _sample(path: Path) -> int:
    try:
        return _integer(_record(path.read_bytes())["sample_ns"])
    except (OSError, ValueError, KeyError):
        return 0


def _read_identity(path: Path) -> Identity | None:
    try:
        record = _record(path.read_bytes())
        cgroup = record["cgroup"]
        if not isinstance(cgroup, str):
            return None
        pid = _integer(record["pid"])
        uid = _integer(record["uid"])
        start_ticks = _integer(record["start_ticks"])
        if min(pid, uid, start_ticks) == 0:
            return None
        return Identity(pid, uid, start_ticks, cgroup)
    except (OSError, ValueError, KeyError):
        return None


def read_identity(config: Config) -> Identity | None:
    return _read_identity(config.observation / "identity.json")


def read_spool_identity(config: Config) -> Identity | None:
    return _read_identity(config.observation / "spool_identity.json")


def read_filesystem(config: Config) -> Filesystem | None:
    try:
        record = _record((config.observation / "filesystem.json").read_bytes())
        archive_device = _integer(record["archive_device"])
        root_device = _integer(record["root_device"])
        free_bytes = _integer(record["free_bytes"])
        total_bytes = _integer(record["total_bytes"])
        if archive_device == 0 or root_device == 0 or total_bytes == 0 or free_bytes > total_bytes:
            return None
        return Filesystem(archive_device, root_device, free_bytes, total_bytes)
    except (OSError, ValueError, KeyError):
        return None


def read_status(config: Config) -> Status | None:
    try:
        record = _record((config.observation / "status.json").read_bytes())
        if set(record) != {"sample_ns", "producer", "recorder", "spool", "archive"}:
            return None
        sample_ns = _integer(record["sample_ns"])
        producer = record["producer"]
        recorder = record["recorder"]
        spool = record["spool"]
        archive = record["archive"]
        age = time.time_ns() - sample_ns
        if age < 0 or age >= 10_000_000_000:
            return None
        if (
            not isinstance(producer, bool)
            or not isinstance(recorder, bool)
            or not isinstance(spool, bool)
            or not isinstance(archive, bool)
        ):
            return None
        return Status(sample_ns, producer, recorder, spool, archive)
    except (OSError, ValueError, KeyError):
        return None


class Client:
    def __init__(self, config: Config) -> None:
        self.config = config
        config.ledger.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(config.ledger) as db:
            db.execute(
                "CREATE TABLE IF NOT EXISTS attempts ("
                "id INTEGER PRIMARY KEY, kind TEXT NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0)"
            )
            db.execute(
                "CREATE TABLE IF NOT EXISTS archive_witness ("
                "digest TEXT PRIMARY KEY, body_sha256 TEXT NOT NULL, "
                "accepted_ns INTEGER NOT NULL, expires_ns INTEGER NOT NULL)"
            )

    def _request(
        self, operation: dict[str, object], kind: str
    ) -> tuple[dict[str, object], int] | None:
        """@cc [owner:ghuntley,label:verification] recorder-attempt-ack-bounds
        The ledger MUST commit an attempt before publishing a VM request and an
        ACK only after a validated result. Lost results stay uncertain. Returned
        results MUST follow a newer independent observation sample.
        """
        payload = json.dumps(operation, separators=(",", ":")).encode("utf-8")
        if len(payload) > 4096:
            raise ValueError("recorder operation too large")
        with sqlite3.connect(self.config.ledger) as db:
            cursor = db.execute("INSERT INTO attempts (kind) VALUES (?)", (kind,))
            attempt_id = cursor.lastrowid
            db.commit()
        name = secrets.token_hex(16) + ".json"
        temporary = self.config.requests / ("." + name)
        destination = self.config.requests / name
        try:
            descriptor = os.open(
                temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
            )
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            temporary.replace(destination)
            directory = os.open(self.config.requests, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
            deadline = time.monotonic() + 30
            result = self.config.results / name
            while time.monotonic() < deadline and not result.is_file():
                time.sleep(0.05)
            record = _record(result.read_bytes())
            if not isinstance(record.get("status"), str):
                raise ValueError("invalid recorder result")
            sample_at_result = _sample(self.config.observation / "status.json")
            while time.monotonic() < deadline:
                if _sample(self.config.observation / "status.json") > sample_at_result:
                    if attempt_id is None:
                        raise ValueError("missing attempt identifier")
                    return record, attempt_id
                time.sleep(0.05)
        except (OSError, ValueError):
            return None
        finally:
            temporary.unlink(missing_ok=True)
        return None

    def _ack(self, attempt_id: int) -> None:
        with sqlite3.connect(self.config.ledger) as db:
            db.execute("UPDATE attempts SET acknowledged=1 WHERE id=?", (attempt_id,))

    def call(self, operation: dict[str, object]) -> Reply | None:
        kind = operation.get("op")
        if kind not in (
            "admit",
            "finish",
            "finish_many",
            "kill_worker",
            "trace",
            "hello",
            "recorder_uncertain_admit",
        ):
            raise ValueError("unreviewed producer operation")
        result = self._request({"op": "producer", "command": operation}, str(kind))
        if result is None:
            return None
        record, attempt_id = result
        reply = _reply(record)
        self._ack(attempt_id)
        return reply

    def control(self, operation: dict[str, object]) -> ControlReply | None:
        op = operation.get("op")
        if op == "service":
            if (
                set(operation) != {"op", "target", "action"}
                or operation["target"]
                not in (
                    "producer",
                    "recorder",
                    "spool",
                )
                or operation["action"] not in ("start", "stop", "restart", "kill")
            ):
                raise ValueError("unreviewed service operation")
        elif op == "spool_quota":
            if set(operation) != {"op", "profile"} or operation["profile"] not in (
                "default",
                "pressure",
            ):
                raise ValueError("unreviewed spool quota operation")
        elif (
            op not in ("pressure_fill", "pressure_clear", "replay", "status") or len(operation) != 1
        ):
            raise ValueError("unreviewed recorder control operation")
        result = self._request(operation, str(op))
        if result is None:
            return None
        record, attempt_id = result
        status = record.get("status")
        enospc = record.get("enospc", False)
        if (
            not isinstance(status, str)
            or status not in ("ok", "unavailable", "invalid")
            or not isinstance(enospc, bool)
        ):
            raise ValueError("invalid recorder control result")
        self._ack(attempt_id)
        return ControlReply(status, enospc)

    def counts(self, kind: str) -> tuple[int, int]:
        with sqlite3.connect(self.config.ledger) as db:
            row = db.execute(
                "SELECT count(*),sum(acknowledged) FROM attempts WHERE kind=?", (kind,)
            ).fetchone()
        assert row is not None
        return int(row[0]), int(row[1] or 0)

    def known_archive(self) -> dict[str, Batch]:
        with sqlite3.connect(self.config.ledger) as db:
            rows = db.execute(
                "SELECT digest,body_sha256,accepted_ns,expires_ns FROM archive_witness"
            ).fetchall()
        return {
            digest: Batch(digest, body_sha256, accepted_ns, expires_ns, False)
            for digest, body_sha256, accepted_ns, expires_ns in rows
        }

    def remember_archive(self, batches: dict[str, Batch]) -> None:
        """Persist independent body digests without copying payloads into the ledger."""
        with sqlite3.connect(self.config.ledger) as db:
            db.executemany(
                "INSERT OR IGNORE INTO archive_witness VALUES (?,?,?,?)",
                [
                    (batch.digest, batch.body_sha256, batch.accepted_ns, batch.expires_ns)
                    for batch in batches.values()
                ],
            )
