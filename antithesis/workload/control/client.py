"""Verified-TLS, bounded synchronous client for the real Marshall Control listener."""

import json
import ssl
import time
from contextlib import suppress
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Protocol
from urllib.parse import urlparse
from uuid import UUID

from websockets.exceptions import ConnectionClosed, InvalidStatus, WebSocketException
from websockets.sync.client import connect

from control.credential import LillyCredential
from control.envelope import MAX_FRAME, InvalidEnvelope, decode, hello, request


class WireState(Enum):
    MESSAGE = "message"
    CLOSED = "closed"
    UNAVAILABLE = "unavailable"


@dataclass(frozen=True)
class WireEvent:
    state: WireState
    message: dict[str, object] | None = None
    close_code: int | None = None


@dataclass(frozen=True)
class Opening:
    session: "ControlSession | None"
    http_status: int | None = None


@dataclass(frozen=True)
class RequestResult:
    attempted: bool
    acknowledged: bool
    response: dict[str, object] | None = None
    close_code: int | None = None


class ControlTransport(Protocol):
    def send(self, message: str | bytes) -> None: ...

    def recv(self, timeout: float | None = None) -> str | bytes: ...

    def close(self) -> None: ...


def _fleet_url(origin: str) -> str:
    parsed = urlparse(origin)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
        or parsed.username
        or parsed.password
    ):
        raise ValueError("Control requires a Marshall HTTPS origin")
    return f"wss://{parsed.hostname}:5443/api/control/v1"


class ControlWire:
    def __init__(self, origin: str, ca_file: Path, credential: LillyCredential) -> None:
        self._url = _fleet_url(origin)
        self._context = ssl.create_default_context(cafile=str(ca_file))
        self._credential = credential

    def open(self, *, version: int = 1) -> Opening:
        """Upgrade using a real issued credential and verified Marshall fleet TLS."""
        if type(version) is not int or version < 1:
            raise ValueError("invalid Control outer version")
        try:
            connection = connect(
                self._url,
                additional_headers={
                    "overalls-control": str(version),
                    "overalls-service": "lilly",
                    "authorization": f"Bearer {self._credential.token}",
                },
                ssl=self._context,
                proxy=None,
                compression=None,
                ping_interval=None,
                max_size=MAX_FRAME,
                open_timeout=5,
                close_timeout=1,
            )
            return Opening(ControlSession(connection))
        except InvalidStatus as error:
            return Opening(None, error.response.status_code)
        except (OSError, TimeoutError, WebSocketException):
            return Opening(None)


class ControlSession:
    def __init__(self, connection: ControlTransport) -> None:
        self._connection = connection
        self._welcomed = False

    @property
    def welcomed(self) -> bool:
        return self._welcomed

    def close(self) -> None:
        with suppress(OSError, TimeoutError, WebSocketException):
            self._connection.close()

    def first_frame(self, payload: str | bytes) -> bool:
        """Send exactly one intentionally invalid first application frame."""
        if self._welcomed:
            raise ValueError("first frame cannot follow welcome")
        try:
            self._connection.send(payload)
            return True
        except (OSError, TimeoutError, WebSocketException):
            return False

    def send_raw_frame(self, payload: str | bytes) -> bool:
        """Send one deliberate post-bind frame, without retrying an uncertain write."""
        if not self._welcomed:
            raise ValueError("raw Control frame requires welcome")
        try:
            self._connection.send(payload)
            return True
        except (OSError, TimeoutError, WebSocketException):
            return False

    def bind_lilly(self, host_id: str) -> WireEvent:
        if self._welcomed:
            raise ValueError("Control session already bound")
        try:
            if str(UUID(host_id)) != host_id:
                raise ValueError("noncanonical Control host bind")
        except ValueError as error:
            raise ValueError("invalid Control host bind") from error
        if not self.first_frame(hello("lilly", {"host_id": host_id})):
            return WireEvent(WireState.UNAVAILABLE)
        result = self.receive(5)
        if result.state is WireState.MESSAGE and result.message is not None:
            if result.message.get("k") == "welcome":
                self._welcomed = True
            else:
                return WireEvent(WireState.UNAVAILABLE)
        return result

    def receive(self, timeout_seconds: float) -> WireEvent:
        try:
            frame = self._connection.recv(timeout=timeout_seconds)
            if not isinstance(frame, str):
                return WireEvent(WireState.UNAVAILABLE)
            return WireEvent(WireState.MESSAGE, decode(frame))
        except ConnectionClosed as error:
            return WireEvent(WireState.CLOSED, close_code=error.rcvd.code if error.rcvd else None)
        except (InvalidEnvelope, OSError, TimeoutError, WebSocketException):
            return WireEvent(WireState.UNAVAILABLE)

    def exchange(self, identifier: int, op: str, body: dict[str, object]) -> RequestResult:
        """@cc [owner:ghuntley,label:protocol;verification] control-client-reply-uncertainty
        Application requests MUST be sent only after welcome. Each attempted
        request retains its identifier; transport loss or an uncorrelated reply
        MUST remain unproven, never a SUT refusal or absent domain effect.
        """
        if not self._welcomed:
            raise ValueError("Control request requires welcome")
        payload = request(identifier, op, body)
        try:
            self._connection.send(payload)
        except (OSError, TimeoutError, WebSocketException):
            return RequestResult(attempted=True, acknowledged=False)
        deadline = time.monotonic() + 5
        for _ in range(32):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            event = self.receive(remaining)
            if event.state is WireState.CLOSED:
                return RequestResult(True, False, close_code=event.close_code)
            if event.state is WireState.UNAVAILABLE or event.message is None:
                break
            kind = event.message["k"]
            if kind == "res":
                if event.message.get("id") != identifier:
                    break
                return RequestResult(True, True, response=event.message)
            if kind == "ping":
                try:
                    self._connection.send(json.dumps({"k": "pong", "n": event.message["n"]}))
                except (OSError, TimeoutError, WebSocketException):
                    break
            elif kind not in {"hint", "resync", "pong"}:
                break
        return RequestResult(True, False)
