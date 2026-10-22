"""Third-party origin fixture: records request paths and serves an embedding page."""

import html
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

HITS = Path(sys.argv[1])
ADDRESS = ("127.0.0.1", 8081)
CONTENT_PREFIX = "https://usercontent.example.test/v/"


class Handler(BaseHTTPRequestHandler):
    """@cc [owner:ghuntley,label:verification] artifact-origin-outside-recorder
    Every request except the explicit framing page and the reset endpoint MUST
    be appended to the hit log, so any escape that reaches this origin fails
    the test. Only the path (never headers or bodies) is recorded.
    """

    def log_message(self, format: str, *args: object) -> None:
        return

    def record(self) -> None:
        path = urlsplit(self.path).path
        if path == "/reset":
            HITS.write_text("")
            return self.reply(204, b"", "text/plain")
        if path == "/embed":
            # Frames a content URL from a non-Marshall origin; frame-ancestors
            # must refuse it. Only the fixed content prefix may be framed.
            target = parse_qs(urlsplit(self.path).query).get("u", [""])[0]
            if not target.startswith(CONTENT_PREFIX):
                return self.reply(400, b"", "text/plain")
            body = (
                '<!doctype html><title>outside</title><iframe id="embedded" src="'
                + html.escape(target, quote=True)
                + '"></iframe>'
            ).encode()
            return self.reply(200, body, "text/html; charset=utf-8")
        if path == "/favicon.ico":
            # The browser's own request for the /embed page's icon, not content.
            return self.reply(404, b"", "text/plain")
        with HITS.open("a") as stream:
            stream.write(self.command + " " + path + "\n")
        return self.reply(200, b"outside", "text/plain")

    def reply(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self) -> None:
        self.record()

    def do_HEAD(self) -> None:
        self.record()

    def do_POST(self) -> None:
        self.record()

    def do_OPTIONS(self) -> None:
        self.record()


def main() -> None:
    HITS.write_text("")
    ThreadingHTTPServer(ADDRESS, Handler).serve_forever()


if __name__ == "__main__":
    main()
