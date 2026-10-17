"""Closed Enrico service restart receipt; no generic process or engine access."""

import json
import os
import stat
import time
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID


@dataclass(frozen=True)
class RestartReceipt:
    request_id: UUID
    previous_pid: int
    current_pid: int
    previous_generation: int
    generation: int


class EnricoRestarter:
    def __init__(self, root: Path) -> None:
        self._requests = root / "requests"
        self._results = root / "results"

    def restart(self, request_id: UUID) -> RestartReceipt | None:
        """@cc [owner:ghuntley,label:recovery;security] enrico-closed-restart
        Only the fixed restart_enrico operation may be published. A restart is
        proven only by an exact matching result with a new process identity and
        increasing service generation; missing or malformed results stay unknown.
        """
        body = {"version": 1, "operation": "restart_enrico", "request_id": str(request_id)}
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
        result_file = self._results / f"{request_id}.json"
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                info = result_file.lstat()
            except FileNotFoundError:
                time.sleep(0.1)
                continue
            if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 1024:
                return None
            try:
                raw: object = json.loads(result_file.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError):
                return None
            if not isinstance(raw, dict) or set(raw) != {
                "version",
                "request_id",
                "status",
                "previous_pid",
                "current_pid",
                "previous_generation",
                "generation",
            }:
                return None
            old_pid, new_pid = raw["previous_pid"], raw["current_pid"]
            old_generation, generation = raw["previous_generation"], raw["generation"]
            if (
                raw["version"] != 1
                or type(raw["version"]) is not int
                or raw["request_id"] != str(request_id)
                or raw["status"] != "restarted"
                or type(old_pid) is not int
                or type(new_pid) is not int
                or type(old_generation) is not int
                or type(generation) is not int
                or old_pid < 1
                or new_pid < 1
                or old_pid == new_pid
                or old_generation < 1
                or generation <= old_generation
            ):
                return None
            return RestartReceipt(request_id, old_pid, new_pid, old_generation, generation)
        return None
