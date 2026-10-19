"""Fake Susan poke endpoint: scripted statuses over TLS for the compiled origin.

Each request's body and the two install headers are appended to a private
runtime file so the probe can verify signatures and that the body carries
only ciphertext. The status script is read from `script`, one status per
request; once exhausted every request succeeds. A provider send is counted
only for 2xx responses, mirroring Susan forwarding to APNs/FCM.
"""

import http.server
import json
import ssl
import sys
from pathlib import Path

ROOT = Path("/run/push-fixture")
PATH = "/api/push/v1/poke"
MAXIMUM = 1024


def next_status() -> int:
    script = ROOT / "script"
    statuses = script.read_text().split() if script.exists() else []
    if not statuses:
        return 200
    script.write_text(" ".join(statuses[1:]))
    return int(statuses[0])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        length = int(self.headers.get("content-length", "0"))
        if self.path != PATH or length > MAXIMUM:
            self.send_response(400)
            self.end_headers()
            return
        body = self.rfile.read(length).decode()
        status = next_status()
        record = {
            "body": body,
            "key": self.headers.get("overalls-install-key", ""),
            "signature": self.headers.get("overalls-install-signature", ""),
            "status": status,
        }
        with (ROOT / "requests.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        if 200 <= status < 300:
            with (ROOT / "provider-sends").open("a") as stream:
                stream.write(json.loads(body)["delivery_id"] + "\n")
        self.send_response(status)
        self.send_header("content-length", "0")
        self.end_headers()

    def log_message(self, format: str, *args: object) -> None:
        return


def main() -> None:
    certificate, key = sys.argv[1], sys.argv[2]
    ROOT.mkdir(mode=0o700, exist_ok=True)
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.load_cert_chain(certificate, key)
    server = http.server.HTTPServer(("127.0.0.1", 443), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


main()
