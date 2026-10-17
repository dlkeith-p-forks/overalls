"""Bounded Phoenix LiveView wire client for actual mounted browser events."""

from __future__ import annotations

import json
import ssl
from contextlib import suppress
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import quote, urlparse
from uuid import uuid4

from websockets.exceptions import ConnectionClosed, InvalidStatus, WebSocketException
from websockets.sync.client import ClientConnection, connect
from websockets.typing import Origin

from access.http import BrowserClient
from core.outcome import Observation


@dataclass(frozen=True)
class LivePage:
    csrf: str
    session: str
    static: str | None
    node_id: str


class _LivePageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.csrf: str | None = None
        self.session: str | None = None
        self.static: str | None = None
        self.node_id: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        fields = dict(attrs)
        if tag == "meta" and fields.get("name") == "csrf-token":
            self.csrf = fields.get("content")
        # Phoenix renders data-phx-main as a bare boolean attribute, which
        # HTMLParser reports with a None value.
        if "data-phx-main" in fields:
            self.session = fields.get("data-phx-session")
            self.static = fields.get("data-phx-static")
            self.node_id = fields.get("id")


def _event_reply(payload: dict[str, object]) -> dict[str, object]:
    """LiveView carries a handle_event {:reply, map} inside the reply diff as
    ``{"diff": {"r": map}}``; the JS client unwraps it before pushEvent
    callbacks see it. Return that map, or the bare payload for :noreply."""
    diff = payload.get("diff")
    reply = diff.get("r") if isinstance(diff, dict) else None
    return reply if isinstance(reply, dict) else payload


def parse_live_page(body: bytes) -> LivePage | None:
    try:
        parser = _LivePageParser()
        parser.feed(body.decode("utf-8"))
    except UnicodeError:
        return None
    if parser.csrf is None or parser.session is None or parser.node_id is None:
        return None
    return LivePage(parser.csrf, parser.session, parser.static, parser.node_id)


class LiveView:
    def __init__(self, connection: ClientConnection, topic: str, join_ref: str) -> None:
        self._connection = connection
        self._topic = topic
        self._join_ref = join_ref
        self._next_ref = 2
        self._pending_events: list[tuple[str, dict[str, object]]] = []

    def _collect_events(self, value: object) -> None:
        if isinstance(value, dict):
            for key, nested in value.items():
                if key == "e" and isinstance(nested, list):
                    for event in nested:
                        if (
                            isinstance(event, list)
                            and len(event) == 2
                            and isinstance(event[0], str)
                            and isinstance(event[1], dict)
                            and all(isinstance(field, str) for field in event[1])
                        ):
                            self._pending_events.append((event[0], event[1]))
                else:
                    self._collect_events(nested)
        elif isinstance(value, list):
            for nested in value:
                self._collect_events(nested)

    @classmethod
    def mount(
        cls, browser: BrowserClient, origin: str, path: str, page: LivePage, ca_file: Path
    ) -> Observation[LiveView]:
        """@cc [owner:ghuntley,label:verification;security] liveview-real-mounted-context
        A mounted event MUST use Marshall's signed session and CSRF from the
        same HTTP cookie context. An absent join reply or severed socket MUST
        remain unavailable rather than being classified as an authorization refusal.
        """
        parsed = urlparse(origin)
        if parsed.scheme != "https" or not parsed.hostname or not path.startswith("/"):
            raise ValueError("invalid LiveView origin or path")
        url = f"{origin}{path}"
        ws_url = f"wss://{parsed.netloc}/live/websocket?_csrf_token={quote(page.csrf)}&vsn=2.0.0"
        context = ssl.create_default_context(cafile=str(ca_file))
        cookie = browser.cookie_header(url)
        try:
            connection = connect(
                ws_url,
                additional_headers={"Cookie": cookie} if cookie else {},
                origin=Origin(origin),
                ssl=context,
                proxy=None,
                compression=None,
                ping_interval=None,
                max_size=1_048_576,
                open_timeout=5,
                close_timeout=1,
            )
            topic = f"lv:{page.node_id}"
            mount_ref = uuid4().hex
            mounted = cls(connection, topic, mount_ref)
            frame = [
                mount_ref,
                "1",
                topic,
                "phx_join",
                {
                    "url": url,
                    "params": {"_csrf_token": page.csrf, "_mounts": 0},
                    "session": page.session,
                    "static": page.static,
                },
            ]
            connection.send(json.dumps(frame, separators=(",", ":")))
            for _ in range(8):
                received = connection.recv(timeout=5)
                if not isinstance(received, str):
                    break
                response: object = json.loads(received)
                mounted._collect_events(response)
                if (
                    isinstance(response, list)
                    and len(response) == 5
                    and response[1] == "1"
                    and response[2] == topic
                    and response[3] == "phx_reply"
                    and isinstance(response[4], dict)
                    and response[4].get("status") == "ok"
                ):
                    return Observation.observed(mounted)
            connection.close()
        except (
            OSError,
            TimeoutError,
            ValueError,
            InvalidStatus,
            ConnectionClosed,
            WebSocketException,
        ):
            pass
        return Observation.unavailable()

    def next_push_event(self, name: str) -> Observation[dict[str, object]]:
        """Receive one server push event, retaining its payload only in memory."""
        for _ in range(12):
            for index, (event_name, payload) in enumerate(self._pending_events):
                if event_name == name:
                    self._pending_events.pop(index)
                    return Observation.observed(payload)
            try:
                received = self._connection.recv(timeout=5)
                if not isinstance(received, str):
                    return Observation.unavailable()
                self._collect_events(json.loads(received))
            except (OSError, TimeoutError, ValueError, ConnectionClosed, WebSocketException):
                return Observation.unavailable()
        return Observation.unavailable()

    def event(
        self, name: str, value: dict[str, object], *, event_type: str = "click"
    ) -> Observation[dict[str, object]]:
        """Send one event and require its exact Phoenix reply before assessing UI state."""
        reference = str(self._next_ref)
        self._next_ref += 1
        frame = [
            self._join_ref,
            reference,
            self._topic,
            "event",
            {"type": event_type, "event": name, "value": value},
        ]
        try:
            self._connection.send(json.dumps(frame, separators=(",", ":")))
            for _ in range(12):
                received = self._connection.recv(timeout=5)
                if not isinstance(received, str):
                    return Observation.unavailable()
                response: object = json.loads(received)
                self._collect_events(response)
                if (
                    isinstance(response, list)
                    and len(response) == 5
                    and response[1] == reference
                    and response[2] == self._topic
                    and response[3] == "phx_reply"
                    and isinstance(response[4], dict)
                ):
                    status = response[4].get("status")
                    payload = response[4].get("response")
                    if status == "ok" and isinstance(payload, dict):
                        return Observation.observed(_event_reply(payload))
                    return Observation.unavailable()
        except (OSError, TimeoutError, ValueError, ConnectionClosed, WebSocketException):
            pass
        return Observation.unavailable()

    def send_event_without_reply(
        self, name: str, value: dict[str, object], *, event_type: str = "click"
    ) -> bool:
        """@cc [owner:ghuntley,label:verification] liveview-lost-browser-reply
        A locally sent event whose reply is intentionally dropped MUST remain
        unproven. Callers MUST reconcile its effect through a separate oracle
        before deciding whether a retry is safe.
        """
        reference = str(self._next_ref)
        self._next_ref += 1
        frame = [
            self._join_ref,
            reference,
            self._topic,
            "event",
            {"type": event_type, "event": name, "value": value},
        ]
        try:
            self._connection.send(json.dumps(frame, separators=(",", ":")))
            return True
        except (OSError, TimeoutError, ConnectionClosed, WebSocketException):
            return False

    def close(self) -> None:
        with suppress(OSError, TimeoutError, WebSocketException):
            self._connection.close()
