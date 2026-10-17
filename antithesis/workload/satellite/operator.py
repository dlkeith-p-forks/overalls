"""Closed, private Galileo fixture mutations through real Ash actions."""

import json
import os
import re
import stat
import time
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID, uuid4

from core.outcome import Observation

_ACTIONS = frozenset(
    ("integration.create", "integration.attach", "integration.detach", "integration.retarget")
)
_NAME = re.compile(r"at-[0-9a-f]{20}\Z")


@dataclass(frozen=True)
class IntegrationResult:
    operation: str
    integration_id: UUID
    name: str
    target: str
    vm_id: UUID | None
    attached: bool | None


class IntegrationOperator:
    def __init__(self, root: Path) -> None:
        self._requests = root / "requests"
        self._results = root / "results"

    def call(self, operation: str, vm_id: UUID | None = None) -> Observation[IntegrationResult]:
        """@cc [owner:ghuntley,label:security;verification] integration-real-ash-only
        The workload MUST select only fixed fixture actions and the observed VM
        ID. A same-ID, same-operation committed receipt is required; absent or
        malformed output remains unavailable. This channel MUST NOT write SQL.
        """
        if operation not in _ACTIONS or (
            operation.endswith(("attach", "detach")) != (vm_id is not None)
        ):
            raise ValueError("invalid integration fixture action")
        request_id = uuid4()
        body: dict[str, object] = {
            "version": 1,
            "operation": operation,
            "request_id": str(request_id),
        }
        if vm_id is not None:
            body["vm_id"] = str(vm_id)
        temporary = self._requests / f".{request_id}.tmp"
        final = self._requests / f"{request_id}.json"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(body, stream, separators=(",", ":"))
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.link(temporary, final)
            temporary.unlink()
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
        result_path = self._results / f"{request_id}.json"
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                info = result_path.lstat()
            except FileNotFoundError:
                time.sleep(0.1)
                continue
            if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 8192:
                return Observation.unavailable()
            try:
                raw: object = json.loads(result_path.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError):
                return Observation.unavailable()
            return _result(raw, request_id, operation, vm_id)
        return Observation.unavailable()


def _result(
    raw: object, request_id: UUID, operation: str, vm_id: UUID | None
) -> Observation[IntegrationResult]:
    if (
        not isinstance(raw, dict)
        or raw.get("version") != 1
        or raw.get("request_id") != str(request_id)
        or raw.get("operation") != operation
        or raw.get("status") != "ok"
    ):
        return Observation.unavailable()
    value = raw.get("value")
    if not isinstance(value, dict):
        return Observation.unavailable()
    raw_id, name, target = value.get("integration_id"), value.get("name"), value.get("target")
    if (
        not isinstance(raw_id, str)
        or not isinstance(name, str)
        or _NAME.fullmatch(name) is None
        or target not in ("A", "B")
        or value.get("vm_id") != (str(vm_id) if vm_id is not None else None)
        or value.get("attached")
        != (operation == "integration.attach" if vm_id is not None else None)
    ):
        return Observation.unavailable()
    try:
        return Observation.observed(
            IntegrationResult(
                operation,
                UUID(raw_id),
                name,
                target,
                vm_id,
                value.get("attached") if vm_id is not None else None,
            )
        )
    except ValueError:
        return Observation.unavailable()
