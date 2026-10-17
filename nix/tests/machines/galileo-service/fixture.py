"""Synthetic control authority and upstream origin; production access is absent."""

import base64
import grp
import hashlib
import json
import os
import socket
import ssl
import struct
import sys
import threading
import time
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BufferedIOBase
from pathlib import Path

ROOT = Path("/run/galileo-fixture")
HOST = "11111111-1111-4111-8111-111111111111"
TOKEN = HOST + "." + "A" * 43
SECRET = "sk-origin-secret"
LEASE_TTL_MS = 2000
lock = threading.Lock()
observed: list[dict[str, object]] = []
tls_names: dict[ssl.SSLSocket, str] = {}
MAX_BODY_BYTES = 1_048_576
MAX_LINE_BYTES = 4096
BINDING: dict[str, object] = {
    "host_id": HOST,
    "vm_id": "22222222-2222-4222-8222-222222222222",
    "placement_id": "33333333-3333-4333-8333-333333333333",
    "execution_epoch": 1,
}


def fault_event(event: str) -> None:
    """Record only closed synthetic lifecycle events, without request data."""
    with lock, (ROOT / "fault-events.jsonl").open("a") as output:
        output.write(json.dumps({"event": event, "time": time.monotonic()}) + "\n")


def server_name(peer: ssl.SSLSocket | ssl.SSLObject, name: str | None, _context: object) -> None:
    if isinstance(peer, ssl.SSLSocket) and name is not None:
        with lock:
            tls_names[peer] = name


class Server(ThreadingHTTPServer):
    def get_request(self) -> tuple[socket.socket, tuple[str, int]]:
        peer, address = super().get_request()
        if isinstance(peer, ssl.SSLSocket):
            with lock:
                name = tls_names.pop(peer, None)
            if name == "origin.test":
                fault_event("origin_tls_accepted")
        return peer, address


def mode(name: str) -> str:
    path = ROOT / name
    return path.read_text().strip() if path.exists() else "active"


def receive_exact(peer: socket.socket, size: int) -> bytes:
    value = b""
    while len(value) < size:
        chunk = peer.recv(size - len(value))
        if not chunk:
            raise ConnectionError("truncated fixture request")
        value += chunk
    return value


def grant(peer: socket.socket) -> None:
    # One ADR-0133 v3 watch per connection: a grant keeps the socket open
    # until Audi closes it, because a close is Lilly's revocation.
    try:
        watch(peer)
    except (ConnectionError, OSError, ValueError):
        pass
    finally:
        peer.close()


def watch(peer: socket.socket) -> None:
    size = struct.unpack("!I", receive_exact(peer, 4))[0]
    if size > 2048:
        return
    decoded: object = json.loads(receive_exact(peer, size))
    if not isinstance(decoded, dict) or set(decoded) != {"version", "address", "purpose"}:
        return
    if decoded["version"] != 3 or decoded["purpose"] != "services":
        return
    if not isinstance(decoded["address"], str):
        return
    current = mode("connector-mode")
    if current == "denied":
        return
    binding = dict(BINDING)
    if current == "moved":
        binding["placement_id"] = "44444444-4444-4444-8444-444444444444"
        binding["execution_epoch"] = 2
    raw = json.dumps({"version": 3, "purpose": "services", "binding": binding}).encode()
    peer.sendall(struct.pack("!I", len(raw)) + raw)
    while peer.recv(64):
        pass


def connector() -> None:
    path = ROOT / "connector.sock"
    path.unlink(missing_ok=True)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(path))
        os.chown(path, 0, grp.getgrnam("audi").gr_gid)
        path.chmod(0o660)
        listener.listen(32)
        while True:
            peer, _ = listener.accept()
            threading.Thread(target=grant, args=(peer,), daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        pass

    def reply(self, value: object, status: int = 200) -> None:
        raw = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        if self.headers.get("Host", "").startswith("control.test"):
            return self.control("GET")
        self.origin("GET")

    def do_POST(self) -> None:
        if self.headers.get("Host", "").startswith("control.test"):
            return self.control("POST")
        self.origin("POST")

    def do_PUT(self) -> None:
        self.origin("PUT")

    def control(self, method: str) -> None:
        if self.path == "/api/control/v1" and method == "GET":
            return self.control_socket()
        self.reply({}, 404)

    def control_socket(self) -> None:
        """The Marshall control WebSocket (ADR-0142), synthetic Galileo service."""
        if self.headers.get("overalls-control") != "1":
            return self.reply({}, 426)
        if (
            self.headers.get("overalls-service") != "galileo"
            or self.headers.get("Authorization") != "Bearer " + TOKEN
        ):
            return self.reply({}, 401)
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
        write_lock = threading.Lock()

        def send(value: dict[str, object]) -> None:
            with write_lock:
                self.wfile.write(server_frame(json.dumps(value).encode()))
                self.wfile.flush()

        while True:
            frame = read_client_frame(self.rfile)
            if frame is None:
                return
            opcode, payload = frame
            if opcode == 8:
                return
            if opcode != 1:
                continue
            message: object = json.loads(payload)
            if not isinstance(message, dict):
                return
            kind = message.get("k")
            if kind == "hello":
                send({"k": "welcome", "conn": "fixture", "heartbeat_ms": 5000, "limits": {}})
            elif kind == "ping":
                send({"k": "pong", "n": message.get("n")})
            elif kind == "req":
                threading.Thread(target=self.answer, args=(message, send), daemon=True).start()

    def answer(self, message: dict[str, object], send: Callable[[dict[str, object]], None]) -> None:
        """Answer one request on its own thread, like the old per-request HTTP."""
        op, body = message.get("op"), message.get("body")
        status, value = control_result(op if isinstance(op, str) else "", body)
        if status == 200:
            send({"k": "res", "id": message.get("id"), "ok": True, "body": value})
        else:
            error = {403: "unauthorized", 503: "unavailable"}.get(status, "invalid_request")
            send({"k": "res", "id": message.get("id"), "ok": False, "error": error})

    def origin(self, method: str) -> None:
        fault_upload = self.path == "/lease-blocked-upload"
        fault_response = self.path == "/lease-partial-response"
        if fault_upload:
            fault_event("upload_dispatched")
        try:
            size, digest, chunks = self.read_origin_body()
        except (ConnectionError, OSError, ValueError):
            if fault_upload:
                fault_event("upload_closed")
            return
        if fault_response:
            fault_event("response_dispatched")
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"6\r\nprefix\r\n")
            self.wfile.flush()
            self.connection.settimeout(10)
            try:
                if self.connection.recv(1) == b"":
                    fault_event("response_closed")
            except TimeoutError:
                fault_event("response_timed_out")
            except (ConnectionError, OSError):
                fault_event("response_closed")
            self.close_connection = True
            return
        with lock:
            observed.append(
                dict(
                    method=method,
                    path=self.path,
                    authorization=self.headers.get("Authorization"),
                    x_team=self.headers.get("x-team"),
                    guest_attempt=self.headers.get("x-guest-attempt"),
                    body_bytes=size,
                    body_sha256=digest,
                    transfer_encoding=self.headers.get("Transfer-Encoding"),
                    transport_chunks=chunks,
                )
            )
            (ROOT / "observed.jsonl").write_text(
                "\n".join(json.dumps(row) for row in observed) + "\n"
            )
        if self.path.startswith("/stall"):
            threading.Event().wait(40)
        self.reply(
            dict(
                served=True,
                method=method,
                path=self.path,
                body_bytes=size,
                body_sha256=digest,
                transfer_encoding=self.headers.get("Transfer-Encoding"),
                transport_chunks=chunks,
            )
        )

    def read_origin_body(self) -> tuple[int, str, int]:
        digest = hashlib.sha256()
        total = 0
        chunks = 0

        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            while True:
                line = self.rfile.readline(MAX_LINE_BYTES + 1)
                if not line.endswith(b"\r\n") or len(line) > MAX_LINE_BYTES:
                    raise ValueError("invalid chunk line")
                encoded_size = line[:-2]
                if b";" in encoded_size:
                    raise ValueError("chunk extensions are unsupported")
                size = int(encoded_size, 16)
                if size == 0:
                    if self.rfile.readline(MAX_LINE_BYTES + 1) != b"\r\n":
                        raise ValueError("trailers are unsupported")
                    break
                if total + size > MAX_BODY_BYTES:
                    raise ValueError("request body too large")
                body = self.rfile.read(size)
                if len(body) != size or self.rfile.read(2) != b"\r\n":
                    raise ValueError("truncated chunk")
                digest.update(body)
                total += size
                chunks += 1
        else:
            size = int(self.headers.get("Content-Length", "0"))
            if size < 0 or size > MAX_BODY_BYTES:
                raise ValueError("request body too large")
            body = self.rfile.read(size)
            if len(body) != size:
                raise ValueError("truncated body")
            digest.update(body)
            total = size
            chunks = int(size > 0)

        return total, digest.hexdigest(), chunks


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
    if length > MAX_BODY_BYTES:
        return None
    mask = read_exact(stream, 4)
    payload = read_exact(stream, length)
    if mask is None or payload is None:
        return None
    return opcode, bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))


def control_result(op: str, decoded: object) -> tuple[int, object]:
    """The scripted Marshall decision for one Galileo op (status, body)."""
    if op == "galileo.identity":
        return 200, dict(host_id=HOST)
    if mode("control-mode") == "outage":
        return 503, {}
    if not isinstance(decoded, dict):
        return 400, {}
    if op == "galileo.authorize":
        if (
            mode("control-mode") != "active"
            or decoded.get("name") != "exedev"
            or decoded.get("binding") != BINDING
        ):
            return 403, {}
        return 200, dict(
            target="https://origin.test",
            strip_prefix="/api/v3",
            headers=[["authorization", "Bearer " + SECRET], ["x-team", "platform"]],
            ttl=LEASE_TTL_MS,
        )
    if op == "galileo.renew":
        if (
            set(decoded) != {"name", "binding"}
            or decoded.get("name") != "exedev"
            or decoded.get("binding") != BINDING
            or mode("control-mode") != "active"
            or mode("connector-mode") != "active"
        ):
            fault_event("renewal_refused")
            return 403, {}
        renewal = mode("renewal-mode")
        if renewal == "refused":
            fault_event("renewal_refused")
            return 403, {}
        if renewal == "invalid":
            fault_event("renewal_invalid")
            return 200, dict(version=1, ttl=0)
        if renewal == "blocked":
            fault_event("renewal_stalled")
            threading.Event().wait(3)
        else:
            fault_event("renewal_accepted")
        return 200, dict(version=1, ttl=LEASE_TTL_MS)
    return 400, {}


def main() -> None:
    certificate, key = sys.argv[1], sys.argv[2]
    ROOT.mkdir(mode=0o755, exist_ok=True)
    threading.Thread(target=connector, daemon=True).start()
    server = Server(("127.0.0.1", 443), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    context.set_servername_callback(server_name)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
