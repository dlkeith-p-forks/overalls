"""Closed local HTTP/TLS fixture with an fsynced origin-effect journal."""

import datetime
import grp
import http.server
import json
import os
import re
import ssl
import sys
import threading
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

ROOT = Path("/run/brady-fixture")
JOURNAL = Path("/var/lib/router-storage/origin-effects.jsonl")
BODY = b"isolated-brady-origin\n"


def certificate(pem: Path, key_path: Path, cert: x509.Certificate, key: rsa.RSAPrivateKey) -> None:
    pem.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        )
    )
    key_path.chmod(0o600)


def prepare() -> None:
    ROOT.mkdir(mode=0o755, exist_ok=True)
    brady_group = grp.getgrnam("brady").gr_gid
    os.chown(ROOT, 0, brady_group)
    ROOT.chmod(0o750)
    now = datetime.datetime.now(datetime.UTC)
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Router synthetic CA")])
    ca = (
        x509.CertificateBuilder()
        .subject_name(ca_name)
        .issuer_name(ca_name)
        .public_key(ca_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=1))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .sign(ca_key, hashes.SHA256())
    )
    origin_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    origin_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "origin.brady.test")])
    origin = (
        x509.CertificateBuilder()
        .subject_name(origin_name)
        .issuer_name(ca_name)
        .public_key(origin_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=1))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(
            x509.SubjectAlternativeName([x509.DNSName("origin.brady.test")]), critical=False
        )
        .sign(ca_key, hashes.SHA256())
    )
    certificate(ROOT / "ca.pem", ROOT / "ca.key", ca, ca_key)
    certificate(ROOT / "origin.pem", ROOT / "origin.key", origin, origin_key)
    os.chown(ROOT / "ca.pem", 0, brady_group)
    (ROOT / "ca.pem").chmod(0o640)
    (ROOT / "issuer.pem").write_bytes((ROOT / "ca.pem").read_bytes())
    (ROOT / "issuer.pem").chmod(0o600)
    os.chown(ROOT / "issuer.pem", 991, -1)
    os.chown(ROOT / "ca.key", 991, -1)
    runtime = {
        "version": 1,
        "host_id": "11111111-1111-4111-8111-111111111111",
        "issuer_cert_file": "/run/brady/credentials/issuer.pem",
        "issuer_key_file": "/run/brady/credentials/issuer.key",
        "upstream_ca_file": str(ROOT / "ca.pem"),
        "protected_cidrs": ["8.8.4.5/32"],
        "tls_exceptions": [],
        "cache_directory": "/var/cache/brady",
        "cache_dataset": "tank/brady",
        "cache_quota_bytes": 67108864,
    }
    (ROOT / "config.json").write_text(json.dumps(runtime), encoding="ascii")
    os.chown(ROOT / "config.json", 0, brady_group)
    (ROOT / "config.json").chmod(0o640)
    if not JOURNAL.exists():
        with JOURNAL.open("xb") as stream:
            stream.flush()
            os.fsync(stream.fileno())


def record(kind: str, scheme: str) -> None:
    """@cc [owner:ghuntley,label:security;verification] independent-origin-effects
    Record only a closed route class and scheme. Never persist URLs, headers,
    credentials or bodies. fsync makes the effect independent of Brady state.
    """
    with JOURNAL.open("a", encoding="ascii") as stream:
        stream.write(json.dumps({"kind": kind, "scheme": scheme}, separators=(",", ":")) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *_args: object) -> None:
        _ = format
        pass

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        kind = (
            "public"
            if path == "/public" or re.fullmatch(r"/public/[0-9a-f]{16}", path)
            else "large"
            if path == "/large"
            else "private"
        )
        if self.headers.get("Authorization") or self.headers.get("Cookie") or "?" in self.path:
            kind = "private"
        scheme = "https" if isinstance(self.connection, ssl.SSLSocket) else "http"
        record(kind, scheme)
        body = b"x" * 200_000 if kind == "large" else BODY
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "public, max-age=600" if kind != "private" else "private")
        self.end_headers()
        self.wfile.write(body)


def serve() -> None:
    listeners: list[http.server.ThreadingHTTPServer] = []
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(ROOT / "origin.pem", ROOT / "origin.key")
    for address in ("8.8.4.4", "8.8.4.6"):
        listeners.append(http.server.ThreadingHTTPServer((address, 80), Handler))
        https = http.server.ThreadingHTTPServer((address, 443), Handler)
        https.socket = tls.wrap_socket(https.socket, server_side=True)
        listeners.append(https)
    for listener in listeners[:-1]:
        threading.Thread(target=listener.serve_forever, daemon=True).start()
    listeners[-1].serve_forever()


def main() -> None:
    if sys.argv == [sys.argv[0], "prepare"]:
        prepare()
    elif sys.argv == [sys.argv[0], "serve"]:
        serve()
    else:
        raise ValueError("expected prepare or serve")


if __name__ == "__main__":
    main()
