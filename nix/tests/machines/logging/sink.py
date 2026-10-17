"""Local native HTTP, CloudWatch and OTLP destination fixtures; no forwarding."""

import json
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        data = self.rfile.read(int(self.headers["Content-Length"]))
        target = self.headers.get("X-Amz-Target", "")
        with lock:
            if "PutLogEvents" in target:
                assert "Credential=isolated-fixture-access/" in self.headers.get(
                    "Authorization", ""
                )
                body: dict[str, object] = json.loads(data)
                with Path("/tmp/cloudwatch.jsonl").open("a") as output:
                    for event in body["logEvents"]:
                        output.write(
                            json.dumps(
                                {
                                    "stream": body["logStreamName"],
                                    "group": body["logGroupName"],
                                    "record": json.loads(event["message"]),
                                },
                                separators=(",", ":"),
                            )
                            + "\n"
                        )
            elif self.path == "/v1/logs":
                with Path("/tmp/otlp.bin").open("ab") as output:
                    output.write(data)
            elif not target:
                with Path("/tmp/received.jsonl").open("ab") as output:
                    output.write(data + b"\n")
        encoded = b"{}" if target else b""
        self.send_response(200)
        self.send_header("x-amzn-RequestId", "fixture-request")
        self.send_header("Content-Type", "application/json" if target else "application/x-protobuf")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_args: object) -> None:
        pass


plain = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
threading.Thread(target=plain.serve_forever, daemon=True).start()
secure = ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
secure.socket = context.wrap_socket(secure.socket, server_side=True)
secure.serve_forever()
