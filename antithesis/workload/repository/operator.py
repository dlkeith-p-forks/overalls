"""Closed request for Marshall's real registered repository refresh action."""

import json
import os
import stat
import time
from pathlib import Path
from uuid import UUID


class RepositoryOperator:
    def __init__(self, root: Path) -> None:
        self._requests = root / "requests"
        self._results = root / "results"

    def refresh(self, request_id: UUID, repository_id: UUID) -> bool:
        """@cc [owner:ghuntley,label:verification] repository-refresh-closed-action
        Only the registered fixture ID may be sent to the closed Marshall
        refresh_repository action. A matching applied receipt proves enqueue,
        while SQL audit is required separately to prove worker settlement.
        """
        body = {
            "version": 1,
            "operation": "refresh_repository",
            "request_id": str(request_id),
            "expected_repository_id": str(repository_id),
        }
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
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            try:
                info = result_file.lstat()
            except FileNotFoundError:
                time.sleep(0.1)
                continue
            if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 1024:
                return False
            try:
                raw: object = json.loads(result_file.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError):
                return False
            return isinstance(raw, dict) and raw == {
                "version": 1,
                "request_id": str(request_id),
                "status": "applied",
                "operation": "refresh_repository",
                "repository_id": str(repository_id),
            }
        return False
