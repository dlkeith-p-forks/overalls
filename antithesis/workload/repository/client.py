"""Typed client for Enrico's authenticated, versioned HTTPS interface."""

import json
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote, urlparse
from uuid import UUID

from core.http import HttpClient
from core.outcome import Observation, State

SHA = re.compile(r"[0-9a-f]{40,64}\Z")


@dataclass(frozen=True)
class Attempt:
    state: str
    head: str | None = None


class EnricoClient:
    def __init__(self, origin: str, ca_file: Path, token_file: Path) -> None:
        parsed = urlparse(origin)
        if parsed.scheme != "https" or not parsed.hostname or parsed.path not in ("", "/"):
            raise ValueError("Enrico origin must be an HTTPS authority")
        token = token_file.read_text(encoding="ascii").strip()
        if not 32 <= len(token) <= 256:
            raise ValueError("invalid Enrico credential")
        self._origin = origin.rstrip("/")
        self._http = HttpClient(ca_file, 6)
        self._headers = {"Authorization": f"Bearer {token}"}

    @staticmethod
    def _attempt(payload: bytes) -> Attempt | None:
        try:
            parsed: object = json.loads(payload)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None
        if not isinstance(parsed, dict):
            return None
        status = parsed.get("status")
        if status in ("running", "failed", "missing"):
            return Attempt(status)
        if isinstance(status, dict) and status.get("state") == "succeeded":
            head = status.get("head")
            if isinstance(head, str) and SHA.fullmatch(head):
                return Attempt("succeeded", head)
        return None

    def refresh(
        self, repository_id: UUID, attempt_id: UUID, owner: str, repo: str
    ) -> Observation[Attempt]:
        """@cc [owner:ghuntley,label:recovery] enrico-replay-id
        A retry within the retained receipt window MUST reuse its exact repository
        and attempt IDs. Transport uncertainty MUST NOT create a replacement ID.
        """
        body = json.dumps({"attempt_id": str(attempt_id), "owner": owner, "repo": repo}).encode()
        response = self._http.request(
            "POST",
            f"{self._origin}/v1/repos/{repository_id}/refresh",
            body=body,
            headers=self._headers | {"Content-Type": "application/json"},
        )
        if response.state is not State.OBSERVED or response.value is None:
            return Observation(response.state, status=response.status)
        if response.value.status != 202:
            return Observation.unavailable()
        attempt = self._attempt(response.value.body)
        return (
            Observation.observed(attempt, 202) if attempt is not None else Observation.unavailable()
        )

    def status(self, repository_id: UUID, attempt_id: UUID) -> Observation[Attempt]:
        """@cc [owner:ghuntley,label:verification] enrico-status-200-only
        Only a parsed authenticated HTTP 200 response may be an observed attempt
        status. Other successful HTTP codes and unavailable transport MUST NOT
        become an observed "missing" attempt.
        """
        response = self._http.request(
            "GET",
            f"{self._origin}/v1/repos/{repository_id}/attempts/{attempt_id}",
            headers=self._headers,
        )
        if response.state is not State.OBSERVED or response.value is None:
            return Observation(response.state, status=response.status)
        if response.value.status != 200:
            return Observation.unavailable()
        attempt = self._attempt(response.value.body)
        return (
            Observation.observed(attempt, 200) if attempt is not None else Observation.unavailable()
        )

    def blob(self, repository_id: UUID, head: str, path: str = "README.md") -> Observation[bytes]:
        if SHA.fullmatch(head) is None or path != "README.md":
            raise ValueError("only a fixed fixture blob at an explicit SHA is allowed")
        response = self._http.request(
            "GET",
            f"{self._origin}/v1/repos/{repository_id}/git/blob?ref={head}&path={quote(path)}",
            headers=self._headers,
        )
        if response.state is not State.OBSERVED or response.value is None:
            return Observation(response.state, status=response.status)
        return Observation.observed(response.value.body, 200)
