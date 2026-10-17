"""Isolated TLS/HTTP fixture: generated runtime keys and fixed synthetic payloads."""

import datetime
import hashlib
import http.server
import json
import os
import re
import ssl
import subprocess
import sys
import threading
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

ROOT = Path("/run/brady-fixture")


def prepare() -> None:
    ROOT.mkdir(mode=0o755)
    now = datetime.datetime.now(datetime.UTC)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Brady isolated test CA")])
    ca = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=1))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(
            x509.KeyUsage(False, False, False, False, False, True, True, False, False),
            critical=True,
        )
        .sign(key, hashes.SHA256())
    )
    leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    leaf = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "origin.brady.test")]))
        .issuer_name(name)
        .public_key(leaf_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=1))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(
            x509.SubjectAlternativeName(
                [
                    x509.DNSName("origin.brady.test"),
                    x509.DNSName("tunnel.brady.test"),
                    x509.DNSName("codeload.github.com"),
                ]
            ),
            False,
        )
        .sign(key, hashes.SHA256())
    )
    for stem, cert, private in [("ca", ca, key), ("origin", leaf, leaf_key)]:
        (ROOT / (stem + ".pem")).write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        file = ROOT / (stem + ".key")
        file.write_bytes(
            private.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.TraditionalOpenSSL,
                serialization.NoEncryption(),
            )
        )
        file.chmod(0o600)
    os.chown(ROOT / "ca.key", 991, -1)
    (ROOT / "issuer.pem").write_bytes((ROOT / "ca.pem").read_bytes())
    (ROOT / "issuer.pem").chmod(0o600)
    os.chown(ROOT / "issuer.pem", 991, -1)
    (ROOT / "config.json").write_text(
        json.dumps(
            dict(
                version=1,
                host_id="11111111-1111-4111-8111-111111111111",
                attribution_uid=0,
                issuer_cert_file="/run/brady/credentials/issuer.pem",
                issuer_key_file="/run/brady/credentials/issuer.key",
                upstream_ca_file=str(ROOT / "ca.pem"),
                protected_cidrs=["8.8.4.5/32"],
                tls_exceptions=[dict(host="tunnel.brady.test", port=443)],
                cache_directory="/var/cache/brady",
                cache_dataset="tank/brady",
                cache_quota_bytes=274877906944
                if os.environ.get("BRADY_TEST_LARGE") == "1"
                else 104857600,
            )
        )
    )


class Origin(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args: object) -> None:
        pass

    def git_backend(self) -> None:
        """Smart-HTTP git through `git http-backend` (CGI), as GitHub serves it."""
        path, _, query = self.path.partition("?")
        length = int(self.headers.get("Content-Length") or 0)
        request = self.rfile.read(length) if length else b""
        environment = {
            "PATH": os.environ.get("PATH", ""),
            "GIT_PROJECT_ROOT": str(ROOT / "git"),
            "GIT_HTTP_EXPORT_ALL": "1",
            "REQUEST_METHOD": self.command,
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(request)),
            "REMOTE_ADDR": self.client_address[0],
        }
        result = subprocess.run(
            ["git", "http-backend"],
            input=request,
            env=environment,
            capture_output=True,
            check=False,
        )
        head, _, body = result.stdout.partition(b"\r\n\r\n")
        status = 200
        headers: list[tuple[str, str]] = []
        for line in head.decode("latin-1").split("\r\n"):
            name, _, value = line.partition(":")
            if name.lower() == "status":
                status = int(value.strip().split()[0])
            elif name:
                headers.append((name, value.strip()))
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        if self.path.startswith("/fixture.git/"):
            self.git_backend()
        else:
            self.send_error(405)

    # @cc [owner:ghuntley,label:verification] brady-large-origin-stream
    # Synthetic large bodies MUST be generated in bounded chunks, with a fixed
    # independent oracle identity. Malformed cases MUST not accidentally finish.
    def stream_fixture(self, kind: str, size: int) -> None:
        with (ROOT / "origin-counts.jsonl").open("a") as counts:
            counts.write(json.dumps({"kind": kind, "size": size}) + "\n")
        self.send_response(200)
        if kind == "fixed":
            self.send_header("Content-Length", str(size))
        else:
            self.send_header("Transfer-Encoding", "chunked")
        if kind.startswith("archive"):
            self.send_header("Vary", "Authorization,Accept-Encoding")
            if kind == "archive-private":
                self.send_header("Cache-Control", "private, max-age=3600")
        else:
            self.send_header(
                "Cache-Control",
                "private, max-age=3600" if kind == "private" else "public, max-age=3600",
            )
        self.end_headers()
        try:
            for offset in range(0, size, 65536):
                count = min(65536, size - offset)
                seed = b"brady-large-" + size.to_bytes(8, "big") + offset.to_bytes(8, "big")
                body = hashlib.shake_256(seed).digest(count)
                if kind != "fixed":
                    self.wfile.write(f"{count:x}\r\n".encode())
                self.wfile.write(body)
                if kind != "fixed":
                    self.wfile.write(b"\r\n")
                if kind in ("truncated", "archive-truncated") and offset >= size // 2:
                    self.close_connection = True
                    return
            if kind == "archive-truncated":
                # A one-chunk archive must still omit terminal framing. The
                # earlier loop cutoff only fires for multi-chunk payloads.
                self.close_connection = True
                return
            if kind != "fixed":
                self.wfile.write(
                    b"0\r\nSet-Cookie: synthetic-private\r\n\r\n"
                    if kind in ("trailer", "archive-trailer")
                    else b"0\r\n\r\n"
                )
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def do_GET(self) -> None:
        archive_history = re.fullmatch(
            r"/Property/fixture/(?:tar\.gz|legacy\.tar\.gz)/([0-3][0-9a-f]{39})", self.path
        )
        if archive_history:
            revision = archive_history[1]
            kinds = ("archive", "archive-private", "archive-trailer", "archive-truncated")
            # Closed canonical commit bytes encode the bounded fixture inputs;
            # production policy receives no test-only header or URL exception.
            size = int(revision[1:9], 16) % 65538
            self.stream_fixture(kinds[int(revision[0])], size)
            return
        if re.fullmatch(r"/NixOS/nixpkgs/(?:tar.gz|legacy.tar.gz)/[0-9a-f]{40}", self.path):
            self.stream_fixture("archive", 8 * 1024 * 1024)
            return
        match = re.fullmatch(
            r"/stream/(fixed|chunked|truncated|trailer|private)/([0-9]{1,10})", self.path
        )
        if match:
            size = int(match[2])
            if size <= 4 * 1024**3 + 1:
                self.stream_fixture(match[1], size)
            else:
                self.send_error(413)
            return
        if self.path.startswith("/fixture.git/"):
            self.git_backend()
            return
        body = b"x" * 200_000 if self.path == "/large" else b"isolated-brady-origin\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "public, max-age=600")
        self.send_header("Alt-Svc", 'h3=":443"; ma=600')
        self.end_headers()
        self.wfile.write(body)


def serve() -> None:
    # A second address lets a guest dial the origin at an IP that Brady's own
    # DNS view does not return, as rotating public names do in production.
    single = os.environ.get("BRADY_TEST_ADDRESS", "8.8.4.4")
    addresses = os.environ.get("BRADY_TEST_ADDRESSES", single).split(",")
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(ROOT / "origin.pem", ROOT / "origin.key")
    servers: list[http.server.ThreadingHTTPServer] = []
    for address in addresses:
        servers.append(http.server.ThreadingHTTPServer((address, 80), Origin))
        https = http.server.ThreadingHTTPServer((address, 443), Origin)
        https.socket = tls.wrap_socket(https.socket, server_side=True)
        servers.append(https)
    for server in servers[:-1]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    servers[-1].serve_forever()


if __name__ == "__main__":
    {"prepare": prepare, "serve": serve}[sys.argv[1]]()
