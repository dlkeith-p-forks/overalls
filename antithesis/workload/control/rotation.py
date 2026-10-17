"""Closed private-file request for the reviewed Marshall operator rotation path."""

import json
import os
import stat
import time
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID

from control.credential import LillyCredential, read_lilly_credential


@dataclass(frozen=True)
class RotationReceipt:
    request_id: UUID
    generation: int
    credential: LillyCredential


class RotationCoordinator:
    def __init__(self, root: Path, credential_root: Path) -> None:
        self._requests = root / "requests"
        self._results = root / "results"
        self._credential_root = credential_root

    def rotate(self, request_id: UUID, host_id: UUID) -> RotationReceipt | None:
        """@cc [owner:ghuntley,label:security;verification] control-rotation-closed-helper
        Only a validated rotate_lilly request for the enrolled host may be
        published. A result MUST be matched to its exact request and issued
        private credential file; timeout or malformed output is unproven.
        """
        body = {
            "version": 1,
            "operation": "rotate_lilly",
            "request_id": str(request_id),
            "expected_host_id": str(host_id),
            "ttl_seconds": 3600,
        }
        final = self._requests / f"{request_id}.json"
        temporary = self._requests / f".{request_id}.tmp"
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
        deadline = time.monotonic() + 15
        result_file = self._results / f"{request_id}.json"
        while time.monotonic() < deadline:
            try:
                info = result_file.lstat()
            except FileNotFoundError:
                time.sleep(0.1)
                continue
            if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 4096:
                return None
            try:
                parsed: object = json.loads(result_file.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError):
                return None
            if not isinstance(parsed, dict) or set(parsed) != {
                "version",
                "request_id",
                "status",
                "credential_file",
                "generation",
            }:
                return None
            location = parsed["credential_file"]
            generation = parsed["generation"]
            if (
                parsed["version"] != 1
                or type(parsed["version"]) is not int
                or parsed["request_id"] != str(request_id)
                or parsed["status"] != "issued"
                or type(generation) is not int
                or generation < 1
                or not isinstance(location, str)
                or location != str(self._credential_root / f"{request_id}.json")
            ):
                return None
            try:
                credential = read_lilly_credential(Path(location))
            except (OSError, ValueError):
                return None
            if credential.host_id != host_id:
                return None
            return RotationReceipt(request_id, generation, credential)
        return None
