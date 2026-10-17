"""Closed controls and durable request receipts from the synthetic Git origin."""

import http.client
import json
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from core.outcome import Observation


@dataclass(frozen=True)
class OriginState:
    sequence: int
    generation: int
    head: str


@dataclass(frozen=True)
class GitReceipt:
    sequence: int
    route: str
    mode: str


class GitOrigin:
    def __init__(self, origin: str, token_file: Path) -> None:
        parsed = urlparse(origin)
        if parsed.scheme != "http" or not parsed.hostname or parsed.path not in ("", "/"):
            raise ValueError("Git fixture admin must be an internal HTTP authority")
        self._host = parsed.hostname
        self._port = parsed.port or 80
        self._token = token_file.read_text(encoding="ascii").strip()
        if len(self._token) < 32:
            raise ValueError("invalid Git fixture admin credential")

    def _request(
        self, method: str, path: str, body: dict[str, object] | None = None
    ) -> Observation[object]:
        if method not in ("GET", "POST") or (
            path not in ("/v1/state", "/v1/git/generation", "/v1/fault")
            and not path.startswith("/v1/receipts?after=")
            and not path.startswith("/v1/holds?seq=")
            and path != "/v1/holds/release"
        ):
            raise ValueError("unapproved origin control path")
        connection = http.client.HTTPConnection(self._host, self._port, timeout=5)
        try:
            payload = json.dumps(body).encode() if body is not None else None
            connection.request(
                method,
                path,
                body=payload,
                headers={"X-Fixture-Admin-Token": self._token, "Content-Type": "application/json"},
            )
            response = connection.getresponse()
            data = response.read(65_537)
            if response.status != 200 or len(data) > 65_536:
                return Observation.unavailable()
            parsed: object = json.loads(data)
            return Observation.observed(parsed)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, TimeoutError):
            return Observation.unavailable()
        finally:
            connection.close()

    def state(self) -> Observation[OriginState]:
        result = self._request("GET", "/v1/state")
        value = result.value
        if not isinstance(value, dict):
            return Observation.unavailable()
        sequence = value.get("sequence")
        generation = value.get("git_generation")
        head = value.get("git_head")
        if type(sequence) is not int or type(generation) is not int or not isinstance(head, str):
            return Observation.unavailable()
        return Observation.observed(OriginState(sequence, generation, head))

    def receipts(self, after: int) -> Observation[tuple[GitReceipt, ...]]:
        if after < 0:
            raise ValueError("negative receipt sequence")
        result = self._request("GET", f"/v1/receipts?after={after}&limit=500")
        value = result.value
        if not isinstance(value, dict) or not isinstance(value.get("receipts"), list):
            return Observation.unavailable()
        raw = value["receipts"]
        receipts: list[GitReceipt] = []
        for item in raw:
            if not isinstance(item, dict):
                return Observation.unavailable()
            if item.get("family") != "git":
                continue
            sequence = item.get("seq")
            route = item.get("route")
            mode = item.get("mode")
            if (
                type(sequence) is not int
                or route not in ("info-refs", "upload-pack")
                or mode
                not in ("normal", "stream", "error", "delay", "lost_reply", "partial", "hold")
            ):
                return Observation.unavailable()
            receipts.append(GitReceipt(sequence, route, mode))
        return Observation.observed(tuple(receipts))

    def set_generation(self, generation: int) -> Observation[str]:
        if generation not in (1, 2, 3):
            raise ValueError("invalid fixture generation")
        result = self._request("POST", "/v1/git/generation", {"generation": generation})
        if not isinstance(result.value, dict) or result.value.get("generation") != generation:
            return Observation.unavailable()
        head = result.value.get("head")
        return Observation.observed(head) if isinstance(head, str) else Observation.unavailable()

    def set_fault(self, mode: str, delay_ms: int = 0) -> bool:
        if mode not in ("normal", "error", "delay", "lost_reply", "hold") or delay_ms not in (
            0,
            500,
            2999,
            3000,
        ):
            raise ValueError("unsupported Git fault selection")
        result = self._request(
            "POST", "/v1/fault", {"family": "git", "mode": mode, "delay_ms": delay_ms}
        )
        return isinstance(result.value, dict) and result.value.get("mode") == mode

    def release_hold(self, sequence: int) -> bool:
        if sequence < 1:
            raise ValueError("invalid hold sequence")
        result = self._request("POST", "/v1/holds/release", {"seq": sequence})
        return isinstance(result.value, dict) and result.value.get("seq") == sequence
