"""Deterministic loopback Serper fixture for the fleet agent machine test."""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    """Return one answer box and two organic results to a valid search."""

    def log_message(self, format: str, *args: object) -> None:
        pass

    def do_POST(self) -> None:
        if self.path != "/search" or self.headers.get("x-api-key") != "synthetic-serper-private":
            self.reply(403, {})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 1 or length > 16_384:
                self.reply(400, {})
                return
            request: object = json.loads(self.rfile.read(length))
        except (ValueError, UnicodeDecodeError):
            self.reply(400, {})
            return
        if request != {"q": "example topic"}:
            self.reply(400, {})
            return
        self.reply(
            200,
            {
                "answerBox": {
                    "title": "Example",
                    "answer": "fixture answer",
                    "link": "https://example.org/answer",
                },
                "organic": [
                    {"title": "First", "link": "https://example.org/1", "snippet": "one"},
                    {"title": "Second", "link": "https://example.org/2", "snippet": "two"},
                ],
                "credits": 3,
            },
        )

    def reply(self, status: int, value: dict[str, object]) -> None:
        raw = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def main() -> None:
    ThreadingHTTPServer(("127.0.0.1", 18080), Handler).serve_forever()


if __name__ == "__main__":
    main()
