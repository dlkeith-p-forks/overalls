"""Controlled HTTPS key responses; no production publication authority."""

import ssl
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        expected = "/api/audi/v1/known-hosts/vm-11111111111141118111111111111111"
        status = int(Path("/run/audi-openssh/status").read_text()) if self.path == expected else 404
        body = Path("/run/audi-openssh/published_key").read_bytes()
        parts = self.path.split("/")
        if (
            len(parts) == 8
            and parts[1:5] == ["api", "audi", "v1", "inception-known-hosts"]
            and parts[5] == "vm-11111111111141118111111111111111"
            and parts[6] in ["audi", "porsche"]
            and parts[7] in ["gateway", "inner"]
        ):
            status = int(Path("/run/audi-openssh/status").read_text())
            alias = "gateway" if parts[7] == "gateway" else parts[6]
            body = (alias + "." + parts[5] + ".inception.vm.example.test ").encode()
            body += Path("/run/audi-openssh/published_" + parts[7]).read_bytes()
        oversized = Path("/run/audi-openssh/oversized").exists()
        if oversized:
            body += b"\n#" + b"x" * 16384
        self.send_response(status)
        if status == 302:
            self.send_header("Location", expected)
        if not oversized:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args: object) -> None:
        pass


server = HTTPServer(("127.0.0.1", 4443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/run/audi-openssh/tls.crt", "/run/audi-openssh/tls.key")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
