"""Private, content-free receipts from the independent synthetic origin."""

import http.client
import json
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from core.outcome import Observation, State

_MARKER = re.compile(r"fx-[0-9a-f]{32}\Z")
_FAMILIES = frozenset(("openai", "anthropic", "integration", "git"))


@dataclass(frozen=True)
class OriginReceipt:
    sequence: int
    family: str
    route: str
    operation_id: str
    origin: str
    accepted_at_ns: int
    target_is_a: bool | None
    authorization_matches: bool | None
    static_header_matches: bool | None


@dataclass(frozen=True)
class ReceiptSnapshot:
    sequence: int
    receipts: tuple[OriginReceipt, ...]

    def for_marker(self, marker: str) -> tuple[OriginReceipt, ...]:
        return tuple(row for row in self.receipts if row.operation_id == marker)


@dataclass(frozen=True)
class HoldObservation:
    sequence: int
    state: str
    closed_at_ns: int | None
    eof_observed: bool | None


class SatelliteOrigin:
    def __init__(self, admin_url: str, token_file: Path) -> None:
        parsed = urlparse(admin_url)
        if parsed.scheme != "http" or not parsed.hostname or parsed.path not in ("", "/"):
            raise ValueError("origin admin requires an internal HTTP authority")
        self._host = parsed.hostname
        self._port = parsed.port or 80
        self._token = token_file.read_text(encoding="ascii").strip()
        if len(self._token) < 32:
            raise ValueError("invalid private origin credential")

    def _request(
        self, method: str, path: str, body: dict[str, object] | None = None
    ) -> Observation[object]:
        if method not in ("GET", "POST") or (
            path not in ("/v1/state", "/v1/markers", "/v1/integration/credential", "/v1/fault")
            and not path.startswith("/v1/receipts?after=")
            and not path.startswith("/v1/holds?seq=")
            and path != "/v1/holds/release"
        ):
            raise ValueError("unapproved origin fixture operation")
        connection = http.client.HTTPConnection(self._host, self._port, timeout=5)
        try:
            payload = json.dumps(body, separators=(",", ":")).encode() if body is not None else None
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

    def marker(self) -> Observation[str]:
        result = self._request("POST", "/v1/markers", {})
        if result.state is not State.OBSERVED or not isinstance(result.value, dict):
            return Observation.unavailable()
        marker = result.value.get("marker")
        if not isinstance(marker, str) or _MARKER.fullmatch(marker) is None:
            return Observation.unavailable()
        return Observation.observed(marker)

    def cursor(self) -> Observation[int]:
        result = self._request("GET", "/v1/state")
        if result.state is not State.OBSERVED or not isinstance(result.value, dict):
            return Observation.unavailable()
        sequence = result.value.get("sequence")
        if type(sequence) is not int or sequence < 0:
            return Observation.unavailable()
        return Observation.observed(sequence)

    def receipts_after(self, after: int, maximum: int = 2048) -> Observation[ReceiptSnapshot]:
        """@cc [owner:ghuntley,label:verification] origin-complete-prefix
        Return a receipt snapshot only when every sequence through its claimed
        cursor is present and validated. A page error, gap or capacity limit
        MUST remain unavailable; it cannot prove zero upstream effects.
        """
        if after < 0 or maximum < 1:
            raise ValueError("invalid receipt bound")
        rows: list[OriginReceipt] = []
        cursor = after
        target: int | None = None
        while target is None or cursor < target:
            result = self._request("GET", f"/v1/receipts?after={cursor}&limit=500")
            if result.state is not State.OBSERVED or not isinstance(result.value, dict):
                return Observation.unavailable()
            raw_sequence, raw_rows = result.value.get("sequence"), result.value.get("receipts")
            if (
                type(raw_sequence) is not int
                or raw_sequence < cursor
                or not isinstance(raw_rows, list)
            ):
                return Observation.unavailable()
            if target is None:
                target = raw_sequence
            for raw in raw_rows:
                if cursor >= target:
                    break
                parsed = _receipt(raw)
                if parsed is None or parsed.sequence != cursor + 1:
                    return Observation.unavailable()
                cursor = parsed.sequence
                rows.append(parsed)
                if len(rows) > maximum:
                    return Observation.unavailable()
            if cursor < target and not raw_rows:
                return Observation.unavailable()
        if target is None:
            return Observation.unavailable()
        return Observation.observed(ReceiptSnapshot(target, tuple(rows)))

    def credential_generation(self, generation: int) -> bool:
        if generation not in (1, 2):
            raise ValueError("invalid credential generation")
        result = self._request("POST", "/v1/integration/credential", {"generation": generation})
        return (
            result.state is State.OBSERVED
            and isinstance(result.value, dict)
            and result.value.get("generation") == generation
        )

    def set_fault(self, family: str, mode: str, delay_ms: int = 0) -> bool:
        if (
            family not in ("openai", "anthropic", "integration")
            or mode not in ("normal", "hold", "lost_reply", "delay", "partial")
            or delay_ms not in (0, 500, 1999, 2000, 2001, 3000)
        ):
            raise ValueError("invalid closed satellite fault")
        result = self._request(
            "POST", "/v1/fault", {"family": family, "mode": mode, "delay_ms": delay_ms}
        )
        return (
            result.state is State.OBSERVED
            and isinstance(result.value, dict)
            and result.value.get("family") == family
            and result.value.get("mode") == mode
        )

    def hold(self, sequence: int) -> Observation[HoldObservation]:
        if sequence < 1:
            raise ValueError("invalid hold sequence")
        result = self._request("GET", f"/v1/holds?seq={sequence}")
        if result.state is not State.OBSERVED:
            return Observation.unavailable()
        return _hold(result.value, sequence)

    def release_hold(self, sequence: int) -> Observation[HoldObservation]:
        if sequence < 1:
            raise ValueError("invalid hold sequence")
        result = self._request("POST", "/v1/holds/release", {"seq": sequence})
        if result.state is not State.OBSERVED:
            return Observation.unavailable()
        return _hold(result.value, sequence)


def _hold(raw: object, sequence: int) -> Observation[HoldObservation]:
    if not isinstance(raw, dict) or raw.get("seq") != sequence:
        return Observation.unavailable()
    state = raw.get("state")
    closed = raw.get("closed_at_ns")
    eof = raw.get("eof_observed")
    if (
        state not in ("held", "released", "eof", "timed_out", "unknown")
        or (closed is not None and (type(closed) is not int or closed < 1))
        or (eof is not None and not isinstance(eof, bool))
    ):
        return Observation.unavailable()
    return Observation.observed(HoldObservation(sequence, state, closed, eof))


def _receipt(raw: object) -> OriginReceipt | None:
    if not isinstance(raw, dict):
        return None
    sequence = raw.get("seq")
    family, route, operation_id, origin = (
        raw.get("family"),
        raw.get("route"),
        raw.get("operation_id"),
        raw.get("origin"),
    )
    accepted = raw.get("accepted_at_ns")
    target_a = raw.get("target_is_a")
    auth = raw.get("authorization_matches")
    static = raw.get("static_header_matches")
    if (
        type(sequence) is not int
        or sequence < 1
        or not isinstance(family, str)
        or family not in _FAMILIES
        or not isinstance(route, str)
        or not 1 <= len(route) <= 64
        or not isinstance(operation_id, str)
        or not 1 <= len(operation_id) <= 80
        or not isinstance(origin, str)
        or not 1 <= len(origin) <= 64
        or type(accepted) is not int
        or accepted <= 0
        or any(
            value is not None and not isinstance(value, bool) for value in (target_a, auth, static)
        )
    ):
        return None
    return OriginReceipt(
        sequence, family, route, operation_id, origin, accepted, target_a, auth, static
    )
