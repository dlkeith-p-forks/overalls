"""Loopback-only, single-admission TLS adapter for the native Windows fixture."""

import json
import re
import socket
import socketserver
import ssl
import struct
import threading
from contextlib import suppress
from dataclasses import dataclass
from urllib.parse import urlsplit
from uuid import UUID


def object_mapping(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("fixture object required")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ValueError("fixture key required")
        result[key] = item
    return result


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("fixture duplicate JSON field")
        result[key] = value
    return result


@dataclass(frozen=True)
class Admission:
    uid: int
    origin: str
    hostname: str
    authority: str
    frame: bytes

    @staticmethod
    def parse(raw: bytes) -> "Admission":
        """@cc [owner:ghuntley,label:verification;security] windows-editor-fixed-admission
        A fixture MUST accept only one bounded complete editor binding with a
        canonical SAM name and HTTPS DNS origin. Unknown/missing fields and
        credential-bearing or noncanonical origins MUST fail before SSH or TLS.
        The real broker and production authorizer retain final binding authority.
        """
        if not 0 < len(raw) <= 2048:
            raise ValueError("fixture binding bound")
        parsed: object = json.loads(raw, object_pairs_hook=unique_object)
        document = object_mapping(parsed)
        if set(document) != {"version", "binding"} or type(document["version"]) is not int:
            raise ValueError("fixture preface shape")
        if document["version"] != 1:
            raise ValueError("fixture protocol")
        binding = object_mapping(document["binding"])
        keys = {
            "vm_id",
            "host_id",
            "placement_id",
            "session_id",
            "execution_epoch",
            "generation",
            "label",
            "service",
            "port",
            "user_id",
            "guest_account_id",
            "uid",
            "username",
            "editor_protocol",
            "editor_commit",
            "editor_release",
            "editor_origin",
        }
        if set(binding) != keys:
            raise ValueError("fixture binding shape")
        for key in (
            "vm_id",
            "host_id",
            "placement_id",
            "session_id",
            "user_id",
            "guest_account_id",
        ):
            value = binding[key]
            if not isinstance(value, str) or str(UUID(value)) != value:
                raise ValueError("fixture binding UUID")
        for key in ("generation", "execution_epoch"):
            value = binding[key]
            if type(value) is not int or not 1 <= value <= 2**63 - 1:
                raise ValueError("fixture binding epoch")
        uid = binding["uid"]
        if type(uid) is not int or not 200000 <= uid <= 999999 or binding["username"] != f"u{uid}":
            raise ValueError("fixture canonical account")
        if (
            binding["service"] != "editor"
            or type(binding["port"]) is not int
            or binding["port"] != 4444
            or type(binding["editor_protocol"]) is not int
            or binding["editor_protocol"] != 1
        ):
            raise ValueError("fixture editor service")
        for key, length in (("editor_commit", 40), ("editor_release", 64)):
            value = binding[key]
            if not isinstance(value, str) or re.fullmatch(f"[a-f0-9]{{{length}}}", value) is None:
                raise ValueError("fixture package tuple")
        origin, label = binding["editor_origin"], binding["label"]
        if not isinstance(origin, str) or not isinstance(label, str):
            raise ValueError("fixture origin type")
        if re.fullmatch(r"e-[a-z2-7]{26}-[a-z2-7]{26}", label) is None:
            raise ValueError("fixture editor label")
        url = urlsplit(origin)
        hostname = url.hostname
        if (
            url.scheme != "https"
            or hostname is None
            or not hostname.startswith(label + ".")
            or url.username is not None
            or url.password is not None
            or url.path
            or url.query
            or url.fragment
            or re.fullmatch(r"[a-z0-9-]+(?:\.[a-z0-9-]+)+", hostname) is None
        ):
            raise ValueError("fixture HTTPS origin")
        authority = hostname + (f":{url.port}" if url.port not in {None, 443} else "")
        if origin != "https://" + authority:
            raise ValueError("fixture canonical origin")
        body = json.dumps(document, separators=(",", ":")).encode()
        return Admission(uid, origin, hostname, authority, struct.pack("!I", len(body)) + body)


def read_exact(stream: socket.socket, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        block = stream.recv(length - len(result))
        if not block:
            raise EOFError("fixture readiness closed")
        result.extend(block)
    return bytes(result)


class RelayServer(socketserver.ThreadingTCPServer):
    """@cc [owner:ghuntley,label:verification;security] windows-editor-loopback-tls-relay
    The relay MUST bind loopback, use only the supplied loopback gateway tunnel,
    reject foreign TLS names and initial HTTP Host/Origin, and consume exact
    broker readiness before forwarding HTTP or WebSocket bytes. Payloads,
    addresses and exception details MUST NOT enter fixture diagnostics.
    """

    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, admission: Admission, gateway_port: int, tls: ssl.SSLContext) -> None:
        if not 1 <= gateway_port <= 65535:
            raise ValueError("fixture gateway port")
        self.admission = admission
        self.gateway_port = gateway_port
        self.tls = tls
        super().__init__(("127.0.0.1", 0), RelayRequest)

    def handle_error(self, request: object, client_address: object) -> None:
        # socketserver's default traceback includes request addresses.
        return


class RelayRequest(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        if not isinstance(self.server, RelayServer) or not isinstance(self.request, socket.socket):
            raise ValueError("fixture relay type")
        server = self.server
        try:
            self.request.settimeout(30)
            with server.tls.wrap_socket(self.request, server_side=True) as browser:
                head = bytearray()
                while b"\r\n\r\n" not in head:
                    block = browser.recv(4096)
                    if not block or len(head) + len(block) > 65536:
                        raise ValueError("fixture HTTP header bound")
                    head.extend(block)
                header = bytes(head).split(b"\r\n\r\n", 1)[0].decode("ascii")
                lines = header.split("\r\n")
                parts = lines[0].split(" ")
                if len(parts) != 3 or not parts[1].startswith("/"):
                    raise ValueError("fixture request target")
                fields: dict[str, list[str]] = {}
                for line in lines[1:]:
                    key, separator, value = line.partition(":")
                    if not separator:
                        raise ValueError("fixture HTTP header")
                    fields.setdefault(key.lower(), []).append(value.strip())
                if fields.get("host") != [server.admission.authority]:
                    raise ValueError("fixture foreign HTTP host")
                if "origin" in fields and fields["origin"] != [server.admission.origin]:
                    raise ValueError("fixture foreign HTTP origin")
                with socket.create_connection(
                    ("127.0.0.1", server.gateway_port), timeout=30
                ) as worker:
                    worker.sendall(server.admission.frame)
                    length = struct.unpack("!I", read_exact(worker, 4))[0]
                    if not 0 < length <= 128:
                        raise ValueError("fixture readiness bound")
                    ready: object = json.loads(read_exact(worker, length))
                    status = object_mapping(ready)
                    if (
                        set(status) != {"version", "ready"}
                        or type(status["version"]) is not int
                        or status["version"] != 1
                        or status["ready"] is not True
                    ):
                        raise ValueError("fixture broker readiness")
                    browser.settimeout(None)
                    worker.settimeout(None)
                    worker.sendall(head)

                    def copy(source: socket.socket, destination: socket.socket) -> None:
                        try:
                            while data := source.recv(65536):
                                destination.sendall(data)
                        except OSError:
                            pass
                        finally:
                            for stream in (source, destination):
                                with suppress(OSError):
                                    stream.shutdown(socket.SHUT_RDWR)

                    upstream = threading.Thread(target=copy, args=(browser, worker), daemon=True)
                    upstream.start()
                    copy(worker, browser)
                    upstream.join(timeout=5)
        except (OSError, EOFError, ValueError):
            return
