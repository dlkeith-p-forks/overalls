"""Bounded implicit-TLS SMTP receiver with content-free durable accept receipts."""

from __future__ import annotations

import base64
import binascii
import http.server
import json
import os
import secrets
import signal
import socketserver
import ssl
import sys
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import TypedDict
from urllib.parse import parse_qs, urlsplit

from origin.server import _publish, _terminate, prepare_tls

MAX_MESSAGE = 10_485_760
MAX_JOURNAL = 8_388_608
MAX_RECEIPTS = 100_000
MAX_CAPTURE = 262_144
MAX_CAPTURED_MESSAGES = 32


class Receipt(TypedDict):
    seq: int
    kind: str
    bytes: int


@dataclass(frozen=True)
class CapturedMessage:
    seq: int
    recipient: str
    message_id: str | None
    data: bytes


def message_id(data: bytes) -> str | None:
    for line in data.splitlines():
        if not line:
            break
        if line.lower().startswith(b"message-id:"):
            value = line.partition(b":")[2].strip()
            if len(value) <= 256:
                return value.decode("ascii", errors="replace")
    return None


class State:
    """An independent SMTP accept ledger; no envelope or message bytes persist."""

    def __init__(self, root: Path) -> None:
        self.root = root
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.journal = root / "accepts.jsonl"
        self.password_file = root / "smtp-password"
        self.admin_file = root / "admin-token"
        if not self.password_file.exists():
            _publish(self.password_file, (secrets.token_urlsafe(24) + "\n").encode())
        if not self.admin_file.exists():
            _publish(self.admin_file, (secrets.token_urlsafe(32) + "\n").encode())
        self.password = self.password_file.read_text(encoding="ascii").strip()
        self.admin_token = self.admin_file.read_text(encoding="ascii").strip()
        self.lock = threading.Lock()
        self.messages: list[CapturedMessage] = []
        self.seq = 0
        if self.journal.exists():
            content = self.journal.read_bytes()
            if len(content) > MAX_JOURNAL:
                raise ValueError("SMTP fixture ledger exhausted")
            complete = content.rfind(b"\n") + 1
            if complete != len(content):
                with self.journal.open("r+b") as stream:
                    stream.truncate(complete)
                    stream.flush()
                    os.fsync(stream.fileno())
                content = content[:complete]
            for line in content.splitlines():
                raw: object = json.loads(line)
                if not isinstance(raw, dict) or type(raw.get("seq")) is not int:
                    raise ValueError("invalid SMTP fixture ledger")
                if raw["seq"] != self.seq + 1:
                    raise ValueError("noncontiguous SMTP fixture ledger")
                self.seq += 1
        else:
            _publish(self.journal, b"")
        self.unavailable_until = self.seq

    def accept(self, byte_count: int, recipient: str, data: bytes | None) -> int:
        """@cc [owner:ghuntley,label:verification;security] smtp-accept-before-ack
        A DATA success reply MUST follow exactly one fsynced bounded acceptance
        receipt; the receipt MUST exclude sender, recipient, headers and content.
        """
        with self.lock:
            if self.seq >= MAX_RECEIPTS or self.journal.stat().st_size > MAX_JOURNAL - 128:
                raise OverflowError("SMTP acceptance ledger full")
            receipt: Receipt = {"seq": self.seq + 1, "kind": "accepted", "bytes": byte_count}
            with self.journal.open("ab") as stream:
                stream.write(json.dumps(receipt, separators=(",", ":")).encode("ascii") + b"\n")
                stream.flush()
                os.fsync(stream.fileno())
            self.seq += 1
            if data is None:
                self.unavailable_until = self.seq
            else:
                self.messages.append(CapturedMessage(self.seq, recipient, message_id(data), data))
                if len(self.messages) > MAX_CAPTURED_MESSAGES:
                    evicted = self.messages.pop(0)
                    self.unavailable_until = evicted.seq
            return self.seq

    def receipts(self, after: int, limit: int) -> list[Receipt]:
        with self.lock:
            result: list[Receipt] = []
            for line in self.journal.read_bytes().splitlines():
                raw = json.loads(line)
                if raw["seq"] > after:
                    result.append(raw)
                    if len(result) == limit:
                        break
            return result

    def captured_after(self, after: int, limit: int) -> list[CapturedMessage]:
        """Return only retained accepted mail; lost memory is explicit unavailability."""
        with self.lock:
            if after < self.unavailable_until:
                raise LookupError("accepted message no longer available")
            return [message for message in self.messages if message.seq > after][:limit]


class SMTPHandler(socketserver.StreamRequestHandler):
    state: State

    def reply(self, code: int, message: str) -> None:
        self.wfile.write(f"{code} {message}\r\n".encode("ascii"))
        self.wfile.flush()

    def handle(self) -> None:
        self.request.settimeout(10)
        self.reply(220, "smtp.fixture.test synthetic receiver")
        authenticated = False
        mail = False
        recipients = 0
        recipient = ""
        while True:
            line = self.rfile.readline(1001)
            if not line:
                return
            if len(line) > 1000 or not line.endswith(b"\n"):
                self.reply(500, "line too long")
                return
            command, _, argument = line.rstrip(b"\r\n").partition(b" ")
            verb = command.upper()
            if verb in (b"EHLO", b"HELO"):
                mail, recipients, recipient = False, 0, ""
                self.wfile.write(
                    b"250-smtp.fixture.test\r\n250-AUTH PLAIN LOGIN\r\n250 SIZE 10485760\r\n"
                )
                self.wfile.flush()
            elif verb == b"AUTH" and argument.upper().startswith(b"PLAIN "):
                try:
                    decoded = base64.b64decode(argument[6:], validate=True)
                except (ValueError, binascii.Error):
                    self.reply(535, "authentication failed")
                    continue
                expected = b"\0fixture\0" + self.state.password.encode("ascii")
                authenticated = secrets.compare_digest(decoded, expected)
                self.reply(
                    235 if authenticated else 535,
                    "authenticated" if authenticated else "authentication failed",
                )
            elif verb == b"AUTH" and argument.upper() == b"LOGIN":
                self.wfile.write(b"334 VXNlcm5hbWU6\r\n")
                self.wfile.flush()
                user = self.rfile.readline(1001).strip()
                self.wfile.write(b"334 UGFzc3dvcmQ6\r\n")
                self.wfile.flush()
                password = self.rfile.readline(1001).strip()
                try:
                    decoded_user = base64.b64decode(user, validate=True)
                    decoded_password = base64.b64decode(password, validate=True)
                except (ValueError, binascii.Error):
                    decoded_user, decoded_password = b"", b""
                authenticated = decoded_user == b"fixture" and secrets.compare_digest(
                    decoded_password, self.state.password.encode("ascii")
                )
                self.reply(
                    235 if authenticated else 535,
                    "authenticated" if authenticated else "authentication failed",
                )
            elif verb == b"MAIL" and argument.upper().startswith(b"FROM:"):
                if not authenticated:
                    self.reply(530, "authentication required")
                else:
                    mail, recipients, recipient = True, 0, ""
                    self.reply(250, "sender accepted")
            elif verb == b"RCPT" and argument.upper().startswith(b"TO:"):
                if not mail or recipients >= 1:
                    self.reply(503, "one recipient required")
                else:
                    try:
                        candidate = argument[3:].strip().decode("ascii")
                    except UnicodeDecodeError:
                        candidate = ""
                    if not 1 <= len(candidate) <= 320:
                        self.reply(501, "invalid recipient")
                    else:
                        recipient = candidate
                        recipients += 1
                        self.reply(250, "recipient accepted")
            elif verb == b"DATA":
                if not mail or recipients != 1:
                    self.reply(503, "sender and recipient required")
                    continue
                self.reply(354, "send message")
                count = 0
                captured: bytearray | None = bytearray()
                while True:
                    data = self.rfile.readline(1001)
                    if not data:
                        return
                    if len(data) > 1000:
                        self.reply(552, "message too large")
                        return
                    if data in (b".\r\n", b".\n"):
                        break
                    count += len(data)
                    if count > MAX_MESSAGE:
                        self.reply(552, "message too large")
                        return
                    if captured is not None:
                        if len(captured) + len(data) <= MAX_CAPTURE:
                            captured.extend(data)
                        else:
                            captured = None
                try:
                    sequence = self.state.accept(
                        count, recipient, bytes(captured) if captured is not None else None
                    )
                except OverflowError:
                    self.reply(452, "fixture ledger full")
                    return
                self.reply(250, f"accepted fixture-{sequence}")
                mail, recipients, recipient = False, 0, ""
            elif verb == b"RSET":
                mail, recipients, recipient = False, 0, ""
                self.reply(250, "reset")
            elif verb == b"NOOP":
                self.reply(250, "ok")
            elif verb == b"QUIT":
                self.reply(221, "bye")
                return
            else:
                self.reply(502, "unsupported command")


class AdminHandler(http.server.BaseHTTPRequestHandler):
    state: State

    def log_message(self, format: str, *_args: object) -> None:
        _ = format

    def do_GET(self) -> None:
        parsed = urlsplit(self.path)
        if parsed.path == "/healthz":
            data = b'{"ready":true}'
            status = 200
        elif not isinstance(self.connection, ssl.SSLSocket) or not secrets.compare_digest(
            self.headers.get("X-Fixture-Admin-Token", ""), self.state.admin_token
        ):
            data, status = b"{}", 403
        elif parsed.path in ("/v1/receipts", "/v1/messages"):
            try:
                query = parse_qs(parsed.query)
                after = int(query.get("after", ["0"])[0])
                default_limit = "8" if parsed.path == "/v1/messages" else "100"
                maximum = 8 if parsed.path == "/v1/messages" else 500
                limit = int(query.get("limit", [default_limit])[0])
                if after < 0 or not 1 <= limit <= maximum:
                    raise ValueError("invalid cursor")
                if parsed.path == "/v1/receipts":
                    data = json.dumps(
                        {"sequence": self.state.seq, "receipts": self.state.receipts(after, limit)},
                        separators=(",", ":"),
                    ).encode("ascii")
                else:
                    messages = self.state.captured_after(after, limit)
                    data = json.dumps(
                        {
                            "sequence": self.state.seq,
                            "messages": [
                                {
                                    "seq": message.seq,
                                    "recipient": message.recipient,
                                    "message_id": message.message_id,
                                    "data_b64": base64.b64encode(message.data).decode("ascii"),
                                }
                                for message in messages
                            ],
                        },
                        separators=(",", ":"),
                    ).encode("ascii")
                status = 200
            except ValueError:
                data, status = b"{}", 400
            except LookupError:
                data = json.dumps({"error": "unavailable", "sequence": self.state.seq}).encode(
                    "ascii"
                )
                status = 410
        else:
            data, status = b"{}", 404
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


class HealthHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format: str, *_args: object) -> None:
        _ = format

    def do_GET(self) -> None:
        data = b'{"ready":true}' if self.path == "/healthz" else b"{}"
        self.send_response(200 if self.path == "/healthz" else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class SMTPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    if sys.argv[1:] != ["serve"]:
        raise SystemExit("usage: python -m smtp serve")
    signal.signal(signal.SIGTERM, _terminate)
    root = Path(os.environ.get("SMTP_STATE_DIR", "/var/lib/overalls-smtp"))
    state = State(root)
    prepare_tls(root)
    for variable, name, mode in (
        ("SMTP_CA_OUT", "ca.pem", 0o644),
        ("SMTP_PASSWORD_OUT", "smtp-password", 0o600),
        ("SMTP_ADMIN_TOKEN_OUT", "admin-token", 0o600),
    ):
        value = os.environ.get(variable)
        if value:
            target = Path(value)
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            _publish(target, (root / name).read_bytes(), mode)
    SMTPHandler.state = state
    AdminHandler.state = state
    smtp = SMTPServer(("0.0.0.0", int(os.environ.get("SMTP_TLS_PORT", "465"))), SMTPHandler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(root / "server.pem", root / "server.key")
    smtp.socket = context.wrap_socket(smtp.socket, server_side=True)
    admin = http.server.ThreadingHTTPServer(
        ("0.0.0.0", int(os.environ.get("SMTP_ADMIN_TLS_PORT", "8444"))), AdminHandler
    )
    admin.socket = context.wrap_socket(admin.socket, server_side=True)
    health = http.server.ThreadingHTTPServer(
        ("0.0.0.0", int(os.environ.get("SMTP_HEALTH_PORT", "8081"))), HealthHandler
    )
    try:
        threading.Thread(target=admin.serve_forever, daemon=True).start()
        threading.Thread(target=health.serve_forever, daemon=True).start()
        smtp.serve_forever()
    finally:
        admin.server_close()
        health.server_close()
        smtp.server_close()


if __name__ == "__main__":
    main()
