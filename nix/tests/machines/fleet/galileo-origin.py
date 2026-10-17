"""Bounded isolated TLS origin for the full Galileo fleet path."""

import hashlib
import json
import socket
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path("/run/galileo-origin")
LOCK = threading.Lock()
REQUESTS = 0
CONNECTIONS = 0
MAX_BODY = 1_048_576
RENEWAL_ACCEPTS: dict[str, int] = {}


class OriginServer(ThreadingHTTPServer):
    def get_request(
        self,
    ) -> tuple[socket.socket, tuple[str, int] | tuple[str, int, int, int] | str]:
        """@cc [owner:ghuntley,label:verification] renewal-origin-all-tls-connections
        The independent connection counter MUST increment before HTTP parsing or
        credential validation, so rejected retries cannot evade no-retry checks.
        """
        global CONNECTIONS
        connection, address = super().get_request()
        with LOCK:
            CONNECTIONS += 1
            temporary = ROOT / "connections.pending"
            temporary.write_text(str(CONNECTIONS))
            temporary.replace(ROOT / "connections")
        return connection, address


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        pass

    def do_GET(self) -> None:
        self.handle_request()

    def do_POST(self) -> None:
        self.handle_request()

    def handle_request(self) -> None:
        global REQUESTS
        if self.headers.get("Authorization") != "Bearer galileo-fleet-secret":
            self.reply(403, b"denied\n")
            return
        if self.headers.get("x-galileo-fleet") != "platform":
            self.reply(403, b"denied\n")
            return

        try:
            body = self.read_body()
        except ValueError:
            self.reply(413, b"bounded\n")
            return

        with LOCK:
            REQUESTS += 1
            (ROOT / "count").write_text(str(REQUESTS))

        if self.path in ("/renewal-member", "/renewal-attachment"):
            self.await_renewal_close(self.path.removeprefix("/"))
            return
        if self.path == "/stall":
            threading.Event().wait(40)
        if self.path == "/upload":
            payload = json.dumps(
                {"bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()}
            ).encode()
            self.reply(200, payload)
            return
        self.reply(200, b"galileo-origin-ok\n")

    def await_renewal_close(self, name: str) -> None:
        """@cc [owner:ghuntley,label:verification] renewal-origin-socket-evidence
        Each fixed renewal case MUST record accepted connections and actual TLS
        EOF/reset separately. Timeout MUST NOT count as authority cancellation.
        The origin sends no response and never retries the upstream request.
        """
        assert name in ("renewal-member", "renewal-attachment")
        with LOCK:
            count = RENEWAL_ACCEPTS.get(name, 0) + 1
            RENEWAL_ACCEPTS[name] = count
            self.renewal_receipt(name, count, closed=False, timed_out=False)
        self.connection.settimeout(90)
        closed = False
        timed_out = False
        try:
            closed = self.connection.recv(1) == b""
        except (ConnectionResetError, ssl.SSLEOFError):
            closed = True
        except TimeoutError:
            timed_out = True
        finally:
            self.close_connection = True
            with LOCK:
                self.renewal_receipt(name, RENEWAL_ACCEPTS[name], closed, timed_out)

    @staticmethod
    def renewal_receipt(name: str, accepts: int, closed: bool, timed_out: bool) -> None:
        temporary = ROOT / (name + ".pending")
        temporary.write_text(
            json.dumps({"accepts": accepts, "closed": closed, "timed_out": timed_out})
        )
        temporary.replace(ROOT / (name + ".json"))

    def read_body(self) -> bytes:
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            parts: list[bytes] = []
            total = 0
            while True:
                line = self.rfile.readline(4097)
                if not line.endswith(b"\r\n") or len(line) > 4096 or b";" in line:
                    raise ValueError("invalid chunk")
                size = int(line[:-2], 16)
                if size == 0:
                    if self.rfile.readline(4097) != b"\r\n":
                        raise ValueError("invalid trailer")
                    return b"".join(parts)
                total += size
                if total > MAX_BODY:
                    raise ValueError("body too large")
                part = self.rfile.read(size)
                if len(part) != size or self.rfile.read(2) != b"\r\n":
                    raise ValueError("truncated chunk")
                parts.append(part)

        length = int(self.headers.get("Content-Length", "0"))
        if length < 0 or length > MAX_BODY:
            raise ValueError("body too large")
        body = self.rfile.read(length)
        if len(body) != length:
            raise ValueError("truncated body")
        return body

    def reply(self, status: int, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    certificate, key = sys.argv[1:3]
    ROOT.mkdir(mode=0o700, exist_ok=True)
    (ROOT / "count").write_text("0")
    (ROOT / "connections").write_text("0")
    server = OriginServer(("11.0.0.1", 443), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
