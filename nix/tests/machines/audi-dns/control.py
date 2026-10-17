"""Isolated control-socket publication fixture; it supplies no production authority."""

import base64
import hashlib
import http.server
import json
import pathlib
import ssl
import struct
import sys
import threading
from collections.abc import Callable
from io import BufferedIOBase
from typing import Literal

STATE = pathlib.Path("/var/lib/audi-dns-control")
LABEL = "demo-0123456789abcdef0123456789abcdef"
TOKEN = "audi_service_" + "A" * 43
MAX_FRAME_BYTES = 65_536


def increment(name: Literal["counter", "snapshot_requests", "version_refusals"]) -> int:
    """Atomically expose fixture-owned counts without recording request content."""
    counter = STATE / name
    value = int(counter.read_text()) + 1 if counter.exists() else 1
    temporary = STATE / (name + ".next")
    temporary.write_text(str(value))
    temporary.replace(counter)
    return value


def mode() -> str:
    return (STATE / "mode").read_text().strip()


def identity(body: object) -> tuple[bool, object]:
    if body != {"version": 1} or mode() == "unavailable":
        return False, "unavailable"
    return True, {
        "version": 1,
        "service": {
            "id": "11111111-1111-4111-8111-111111111111",
            "name": "dns",
            "role": "dns",
            "host_id": None,
            "generation": 1,
            "enabled": True,
        },
    }


def snapshot(body: object) -> tuple[bool, object]:
    if body != {"version": 1, "zone": "apps.example"}:
        return False, "unauthorized"
    current = mode()
    increment("snapshot_requests")
    if current == "unsupported":
        increment("version_refusals")
        return False, "unsupported_version"
    if current == "unavailable":
        return False, "unavailable"
    result: dict[str, object] = {
        "version": 1,
        "zone": "apps.example",
        "revision": increment("counter"),
        "ttl": 5000,
        "routes": [],
        "proofs": [],
    }
    if current == "ready":
        result["routes"] = [{"label": LABEL, "addresses": ["192.0.2.9"], "ttl": 5000}]
        result["proofs"] = [{"label": LABEL, "proofs": ["A" * 43], "ttl": 5000}]
    return True, result


OPS: dict[str, Callable[[object], tuple[bool, object]]] = {
    "audi.identity": identity,
    "audi.dns_snapshot": snapshot,
}


def server_frame(payload: bytes) -> bytes:
    """One unmasked final text frame from the server."""
    size = len(payload)
    if size < 126:
        header = struct.pack("!BB", 0x81, size)
    elif size < 65536:
        header = struct.pack("!BBH", 0x81, 126, size)
    else:
        header = struct.pack("!BBQ", 0x81, 127, size)
    return header + payload


def read_exact(stream: BufferedIOBase, size: int) -> bytes | None:
    data = stream.read(size)
    return data if data is not None and len(data) == size else None


def read_client_frame(stream: BufferedIOBase) -> tuple[int, bytes] | None:
    """One masked client frame; None when the connection ends."""
    head = read_exact(stream, 2)
    if head is None:
        return None
    opcode, length = head[0] & 0x0F, head[1] & 0x7F
    if length == 126:
        extended = read_exact(stream, 2)
        if extended is None:
            return None
        length = struct.unpack("!H", extended)[0]
    elif length == 127:
        extended = read_exact(stream, 8)
        if extended is None:
            return None
        length = struct.unpack("!Q", extended)[0]
    if length > MAX_FRAME_BYTES:
        return None
    mask = read_exact(stream, 4)
    payload = read_exact(stream, length)
    if mask is None or payload is None:
        return None
    return opcode, bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))


class Control(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def refuse(self, status: int) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:
        """The Marshall control WebSocket (ADR-0142), synthetic DNS service."""
        if self.path != "/api/control/v1":
            return self.refuse(404)
        if self.headers.get("overalls-control") != "1":
            return self.refuse(426)
        if (
            self.headers.get("overalls-service") != "audi"
            or self.headers.get("Authorization") != "Bearer " + TOKEN
        ):
            return self.refuse(401)
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        ).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        lock = threading.Lock()

        def send(value: dict[str, object]) -> None:
            with lock:
                self.wfile.write(server_frame(json.dumps(value).encode()))
                self.wfile.flush()

        while True:
            frame = read_client_frame(self.rfile)
            if frame is None or frame[0] == 8:
                return
            if frame[0] != 1:
                continue
            message: object = json.loads(frame[1])
            if not isinstance(message, dict):
                return
            kind = message.get("k")
            if kind == "hello":
                if message.get("bind") != {"role": "dns", "host_id": None}:
                    return
                send({"k": "welcome", "conn": "fixture", "heartbeat_ms": 5000, "limits": {}})
            elif kind == "ping":
                send({"k": "pong", "n": message.get("n")})
            elif kind == "req":
                op = message.get("op")
                handler = OPS.get(op) if isinstance(op, str) else None
                ok, value = handler(message.get("body")) if handler else (False, "unauthorized")
                result = {"ok": True, "body": value} if ok else {"ok": False, "error": value}
                send({"k": "res", "id": message.get("id")} | result)

    def log_message(self, format: str, *args: object) -> None:
        pass


STATE.mkdir(parents=True, exist_ok=True)
if not (STATE / "mode").exists():
    (STATE / "mode").write_text("unavailable")
server = http.server.ThreadingHTTPServer(("127.0.0.1", 9443), Control)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
