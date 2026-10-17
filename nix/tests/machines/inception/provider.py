"""Isolated provider fixture; it exposes no Marshall authority endpoints."""

import json
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args: object) -> None:
        pass

    def authorized(self) -> bool:
        host = self.headers.get("Host", "").split(":")[0]
        if host == "api.openai.com":
            return self.headers.get("Authorization") in [
                f"Bearer synthetic-inception-openai-{i}" for i in (1, 2)
            ]
        if host == "api.anthropic.com":
            return self.headers.get("x-api-key") in [
                f"synthetic-inception-anthropic-{i}" for i in (1, 2)
            ]
        return False

    def reply(self, value: object, status: int = 200) -> None:
        raw = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        if self.path == "/v1/models" and self.authorized():
            return self.reply({"data": [{"id": "fixture-model"}], "has_more": False})
        self.reply({}, 403)

    def do_POST(self) -> None:
        # @cc [owner:ghuntley,label:verification;security] inception-provider-fixture-boundary
        # Only isolated provider routes and the two fixtures' explicit keys may
        # succeed. Caller binding headers MUST NOT reach the provider. This
        # service MUST NOT replace inner Marshall authentication or accounting.
        if (
            self.path not in ("/v1/responses", "/v1/messages")
            or not self.authorized()
            or self.headers.get("x-overalls-binding")
        ):
            return self.reply({}, 403)
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 1048576:
                return self.reply({}, 400)
            value: dict[str, object] = json.loads(self.rfile.read(size))
            if not isinstance(value, dict):
                return self.reply({}, 400)
        except (ValueError, TypeError):
            return self.reply({}, 400)
        if value.get("stream"):
            events = (
                [
                    {"type": "response.output_text.delta", "delta": "synthetic-output"},
                    {
                        "type": "response.completed",
                        "response": {"usage": {"input_tokens": 3, "output_tokens": 7}},
                    },
                ]
                if self.path == "/v1/responses"
                else [
                    {
                        "type": "message_start",
                        "message": {"usage": {"input_tokens": 3, "output_tokens": 0}},
                    },
                    {"type": "message_delta", "usage": {"output_tokens": 7}},
                ]
            )
            raw = "".join("data: " + json.dumps(event) + "\n\n" for event in events).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
        else:
            self.reply(
                {"usage": {"input_tokens": 3, "output_tokens": 7}, "output": "synthetic-output"}
            )


server = ThreadingHTTPServer(("11.0.0.2", 443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
