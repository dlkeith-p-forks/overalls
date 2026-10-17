"""Bounded real terminal viewer WebSocket; terminal bytes stay private."""

import json
import ssl
from contextlib import suppress
from dataclasses import dataclass
from uuid import UUID

from websockets.exceptions import ConnectionClosed, InvalidStatus, WebSocketException
from websockets.sync.client import ClientConnection, connect

from core.outcome import Observation
from terminal.client import TerminalClient


@dataclass(frozen=True)
class Attachment:
    channel: int
    guest_session_id: int
    mode: str
    replay_bytes: int


class Viewer:
    def __init__(self, connection: ClientConnection, attachment: Attachment) -> None:
        self._connection = connection
        self.attachment = attachment
        self._output_frames = 0
        self._output_bytes = 0

    @classmethod
    def attach(cls, client: TerminalClient, session_id: UUID) -> Observation["Viewer"]:
        """@cc [owner:ghuntley,label:security;verification] viewer-needs-real-attach
        A viewer is attached only after a current single-use Marshall ticket
        upgrades the real HTTPS socket and an `attached` frame arrives. Socket
        open alone MUST NOT establish guest delivery or viewer queue pressure.
        """
        ticket = client.ticket(session_id)
        if ticket.value is None:
            return Observation.unavailable()
        context = ssl.create_default_context(cafile=str(client.ca_file()))
        try:
            connection = connect(
                client.viewer_url(session_id, ticket.value),
                additional_headers={"Cookie": client.cookie_header(session_id)},
                ssl=context,
                proxy=None,
                compression=None,
                ping_interval=None,
                max_size=65_550,
                open_timeout=5,
                close_timeout=1,
            )
            for _ in range(8):
                raw = connection.recv(timeout=5)
                if not isinstance(raw, str):
                    break
                parsed: object = json.loads(raw)
                if not isinstance(parsed, dict) or parsed.get("op") != "attached":
                    continue
                channel = parsed.get("channel")
                guest_id = parsed.get("guest_session_id")
                mode = parsed.get("mode")
                replay_bytes = parsed.get("replay_bytes")
                if (
                    type(channel) is int
                    and channel > 0
                    and type(guest_id) is int
                    and guest_id > 0
                    and mode in ("rw", "ro")
                    and type(replay_bytes) is int
                    and 0 <= replay_bytes <= 8_388_608
                ):
                    return Observation.observed(
                        cls(connection, Attachment(channel, guest_id, mode, replay_bytes))
                    )
                break
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

    def input(self, data: bytes) -> Observation[bool]:
        """Send bounded bytes; a sent frame is not proof of guest consumption."""
        if self.attachment.mode != "rw" or not 1 <= len(data) <= 65_536:
            raise ValueError("invalid terminal input")
        try:
            self._connection.send(data)
        except (OSError, TimeoutError, ConnectionClosed, WebSocketException):
            return Observation.unavailable()
        return Observation.observed(True)

    def receive(self, *, timeout: float = 5.0, acknowledge: bool = True) -> Observation[bytes]:
        """Return private bytes for an exact marker check; optionally grant read credit."""
        if not 0 < timeout <= 30:
            raise ValueError("invalid terminal timeout")
        try:
            for _ in range(16):
                received = self._connection.recv(timeout=timeout)
                if isinstance(received, bytes):
                    if acknowledge:
                        self._output_frames += 1
                        self._output_bytes += len(received)
                        self._connection.send(
                            json.dumps(
                                {
                                    "op": "output_ack",
                                    "frames": self._output_frames,
                                    "bytes": self._output_bytes,
                                },
                                separators=(",", ":"),
                            )
                        )
                    return Observation.observed(received)
                if isinstance(received, str):
                    # Attached/heartbeat/input ACK are controls, not output evidence.
                    parsed: object = json.loads(received)
                    if not isinstance(parsed, dict) or parsed.get("op") not in (
                        "heartbeat",
                        "input_ack",
                    ):
                        return Observation.unavailable()
            return Observation.unavailable()
        except (OSError, TimeoutError, ValueError, ConnectionClosed, WebSocketException):
            return Observation.unavailable()

    def resize(self, cols: int, rows: int) -> Observation[bool]:
        if self.attachment.mode != "rw" or not 1 <= cols <= 4096 or not 1 <= rows <= 512:
            raise ValueError("invalid resize")
        try:
            self._connection.send(json.dumps({"op": "resize", "cols": cols, "rows": rows}))
        except (OSError, TimeoutError, ConnectionClosed, WebSocketException):
            return Observation.unavailable()
        return Observation.observed(True)

    def close(self) -> None:
        with suppress(OSError, TimeoutError, WebSocketException):
            self._connection.close()
