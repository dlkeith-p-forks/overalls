"""Durable host backup state machine; observations are not execution state."""

from __future__ import annotations

import time
import uuid
from pathlib import Path
from typing import TypedDict

from common import BackupError, atomic_json, read_json
from schema import JSON, Failure, Phase, boolean, integer, object_value, string

TRANSITIONS: dict[Phase, frozenset[Phase]] = {
    "preparing": frozenset({"capturing", "cleaning"}),
    "capturing": frozenset({"cleaning"}),
    "publishing": frozenset({"completed", "cleaning"}),
    "cleaning": frozenset({"publishing", "failed"}),
    "completed": frozenset(),
    "failed": frozenset(),
}


class State(TypedDict):
    version: int
    run_id: str
    hostname: str
    revision: str | None
    phase: Phase
    sequence: int
    started_at: int
    updated_at: int
    components: list[dict[str, JSON]]
    failures: list[Failure]
    manifest_id: str | None
    cleanup_confirmed: bool


def phase_value(value: object) -> Phase:
    if isinstance(value, str) and value in (
        "preparing",
        "capturing",
        "cleaning",
        "publishing",
        "completed",
        "failed",
    ):
        return value
    raise ValueError("invalid phase")


def failure_value(value: object) -> Failure:
    if not isinstance(value, str):
        raise ValueError("invalid failure")
    match value:
        case (
            "capture"
            | "database"
            | "upload"
            | "cleanup"
            | "retention"
            | "credentials"
            | "repository"
            | "interrupted"
            | "configuration"
        ):
            return value
        case _:
            raise ValueError("invalid failure")


def state_value(raw: object) -> State:
    value = object_value(raw)
    if set(value) != set(State.__annotations__):
        raise ValueError("invalid journal fields")
    components, failures = value["components"], value["failures"]
    if not isinstance(components, list) or not isinstance(failures, list):
        raise ValueError("invalid journal lists")
    result = State(
        version=integer(value["version"]),
        run_id=string(value["run_id"]),
        hostname=string(value["hostname"]),
        revision=string(value["revision"]) if value["revision"] is not None else None,
        phase=phase_value(value["phase"]),
        sequence=integer(value["sequence"]),
        started_at=integer(value["started_at"]),
        updated_at=integer(value["updated_at"]),
        components=[object_value(item) for item in components],
        failures=[failure_value(item) for item in failures],
        manifest_id=string(value["manifest_id"]) if value["manifest_id"] is not None else None,
        cleanup_confirmed=boolean(value["cleanup_confirmed"]),
    )
    if (
        result["version"] != 1
        or str(uuid.UUID(result["run_id"])) != result["run_id"]
        or min(result["sequence"], result["started_at"], result["updated_at"]) < 0
    ):
        raise ValueError("invalid journal identity")
    if result["phase"] in {"publishing", "completed", "failed"} and not result["cleanup_confirmed"]:
        raise ValueError("unconfirmed terminal cleanup")
    if result["phase"] == "completed" and (result["failures"] or not result["manifest_id"]):
        raise ValueError("incomplete completion")
    if result["phase"] == "failed" and not result["failures"]:
        raise ValueError("missing failure")
    return result


class Journal:
    def __init__(self, path: str | Path, value: State) -> None:
        self.path = Path(path)
        self.value = value

    @classmethod
    def create(cls, path: str | Path, hostname: str, revision: str | None) -> Journal:
        if Path(path).exists():
            prior = cls.load(path)
            if prior.value["phase"] not in {"completed", "failed"}:
                raise BackupError("cleanup")
        value = State(
            version=1,
            run_id=str(uuid.uuid4()),
            hostname=hostname,
            revision=revision,
            phase="preparing",
            sequence=0,
            started_at=int(time.time()),
            updated_at=int(time.time()),
            components=[],
            failures=[],
            manifest_id=None,
            cleanup_confirmed=False,
        )
        atomic_json(path, value)
        return cls(path, value)

    @classmethod
    def load(cls, path: str | Path) -> Journal:
        try:
            return cls(path, state_value(read_json(path)))
        except (ValueError, KeyError, TypeError, AttributeError):
            raise BackupError("configuration") from None

    def save(self, **updates: object) -> None:
        try:
            value = state_value(
                {
                    **self.value,
                    **updates,
                    "sequence": self.value["sequence"] + 1,
                    "updated_at": int(time.time()),
                }
            )
        except (ValueError, KeyError, TypeError):
            raise BackupError("configuration") from None
        atomic_json(self.path, value)
        self.value = value

    def transition(self, target: Phase) -> None:
        """@cc [owner:ghuntley,label:recovery] backup-terminal-after-cleanup
        Completion MUST follow publication and verified cleanup. A failed run
        MUST remain in cleaning until every owned snapshot is absent. Terminal
        runs MUST NOT transition back into execution or discard recorded effects.
        """
        if target not in TRANSITIONS[self.value["phase"]]:
            raise BackupError("configuration")
        if target in {"publishing", "completed", "failed"} and not self.value["cleanup_confirmed"]:
            raise BackupError("cleanup")
        self.save(phase=target)

    def component(self, value: dict[str, JSON]) -> None:
        if self.value["phase"] != "capturing":
            raise BackupError("configuration")
        self.save(components=[*self.value["components"], value])

    def failed(self, stage: Failure) -> None:
        if self.value["phase"] in {"completed", "failed"}:
            raise BackupError("configuration")
        self.save(failures=list(dict.fromkeys([*self.value["failures"], stage])))
