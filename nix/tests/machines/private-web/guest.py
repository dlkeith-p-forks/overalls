"""Disposable guest origin with closed counters; no request logging or credentials."""

import base64
import hashlib
import http.server
import json
import struct
import threading
import time
from pathlib import Path
from typing import Literal

Counter = Literal["http", "stream", "stream_closed", "ws", "ws_closed", "echoes"]
COUNTS: dict[Counter, int] = {
    "http": 0,
    "stream": 0,
    "stream_closed": 0,
    "ws": 0,
    "ws_closed": 0,
    "echoes": 0,
}
LOCK = threading.Lock()
PATH = Path("/tmp/private-web-counts.json")


def count(key: Counter) -> None:
    with LOCK:
        COUNTS[key] += 1
        temporary = PATH.with_suffix(".tmp")
        temporary.write_text(json.dumps(COUNTS))
        temporary.replace(PATH)


class Handler(http.server.BaseHTTPRequestHandler):
    """@cc [owner:ghuntley,label:verification;security] private-web-guest-counters
    Guest acceptance and EOF/reset MUST be counted independently of browser and
    Marshall state. Forwarded platform cookies MUST refuse
    without guest success. Request bytes and exception text MUST NOT be logged.
    """

    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        pass

    def do_GET(self) -> None:
        cookies = self.headers.get("Cookie", "")
        if "__host-audi_" in cookies.lower():
            self.send_error(400)
            return
        if self.path == "/ws":
            self.websocket()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Connection", "close")
        self.end_headers()
        if self.path == "/stream":
            count("stream")
            try:
                while True:
                    self.wfile.write(b"private-web-data\n")
                    self.wfile.flush()
                    time.sleep(0.05)
            except (BrokenPipeError, ConnectionResetError):
                count("stream_closed")
        else:
            count("http")
            self.wfile.write(b"private-web-ready\n")

    def websocket(self) -> None:
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        ).decode()
        self.send_response(101)
        self.send_header("Connection", "Upgrade")
        self.send_header("Upgrade", "websocket")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        count("ws")
        try:
            while True:
                header = self.rfile.read(2)
                if len(header) != 2 or header[0] == 0x88:
                    return
                length = header[1] & 127
                if length == 126:
                    length = struct.unpack("!H", self.rfile.read(2))[0]
                if length > 1024 or not header[1] & 128:
                    return
                mask, payload = self.rfile.read(4), self.rfile.read(length)
                if len(mask) != 4 or len(payload) != length:
                    return
                data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
                self.wfile.write(bytes([0x81, len(data)]) + data)
                self.wfile.flush()
                count("echoes")
        except (OSError, ValueError, struct.error):
            pass
        finally:
            count("ws_closed")


def main() -> None:
    PATH.write_text(json.dumps(COUNTS))
    for port in (8080, 3000):
        server = http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Event().wait()


if __name__ == "__main__":
    main()
