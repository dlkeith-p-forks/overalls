"""Closed Git HTTPS and DNS fixtures for actual native workspace checkout."""

from __future__ import annotations

import hashlib
import ipaddress
import os
import re
import socket
import socketserver
import struct
import subprocess
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

HOST = "github.com"
PREFIX = "/overalls-native-fixture/unpublished-fixture.git"
FILES: dict[str, bytes] = {
    "README.md": b"Isolated native workspace checkout fixture.\n",
    "src/native-proof.txt": b"native-workspace-checkout-proof\n",
}
MAX_REQUEST = 16_384
MAX_RESPONSE = 16_384


@dataclass(frozen=True)
class Response:
    content_type: bytes
    body: bytes


@dataclass(frozen=True)
class Repository:
    root: Path
    git: Path
    commit: str
    manifest: dict[str, str]
    allow_writes: bool = False

    def command(self, arguments: list[str], body: bytes = b"") -> bytes:
        """Run fixed Git operations against only the generated synthetic root."""
        try:
            result = subprocess.run(
                [str(self.git), "-c", "core.hooksPath=/dev/null", *arguments],
                input=body,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=True,
                timeout=3,
                env={
                    "PATH": f"{self.git.parent}{os.pathsep}{os.defpath}",
                    "HOME": str(self.root),
                    "LC_ALL": "C",
                    "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_CONFIG_GLOBAL": "/dev/null",
                    "GIT_TERMINAL_PROMPT": "0",
                    "GIT_NO_REPLACE_OBJECTS": "1",
                    "GIT_NO_LAZY_FETCH": "1",
                    "GIT_AUTHOR_NAME": "Native fixture",
                    "GIT_AUTHOR_EMAIL": "native@fixture.test",
                    "GIT_COMMITTER_NAME": "Native fixture",
                    "GIT_COMMITTER_EMAIL": "native@fixture.test",
                    "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z",
                    "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z",
                },
            )
        except (OSError, subprocess.SubprocessError):
            raise ValueError("isolated Git fixture operation refused") from None
        if len(result.stdout) > MAX_RESPONSE:
            raise ValueError("oversized isolated Git fixture response")
        return result.stdout

    @classmethod
    def create(cls, root: Path, git: Path, *, allow_writes: bool = False) -> Repository:
        if not root.is_absolute() or root != root.resolve() or not git.is_absolute():
            raise ValueError("canonical isolated Git fixture paths required")
        root.mkdir(mode=0o700)
        seed, bare = root / "seed", root / "repository.git"
        fixture = cls(root, git, "", {})
        fixture.command(["init", "--quiet", "--template=", "--initial-branch=main", str(seed)])
        for name, content in FILES.items():
            path = seed / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        fixture.command(["-C", str(seed), "add", "--", *FILES])
        fixture.command(["-C", str(seed), "commit", "--quiet", "-m", "Native workspace fixture"])
        fixture.command(["clone", "--quiet", "--bare", "--no-local", "--", str(seed), str(bare)])
        commit = fixture.command(["--git-dir", str(bare), "rev-parse", "HEAD"]).decode().strip()
        if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
            raise ValueError("invalid isolated Git fixture commit")
        return cls(
            root,
            git,
            commit,
            {name: hashlib.sha256(content).hexdigest() for name, content in FILES.items()},
            allow_writes,
        )

    def source(self) -> dict[str, object]:
        return {
            "version": 2,
            "provider": "github",
            "namespace": ["overalls-native-fixture"],
            "repository": "unpublished-fixture",
            "revision": {"kind": "default"},
        }

    def response(self, method: str, host: str, path: str, body: bytes) -> Response | None:
        """@cc [owner:ghuntley,label:verification;security] native-git-fixture-closed-origin
        Only the exact synthetic repository's smart-HTTP advertisement and
        upload-pack routes MUST execute Git. Request bytes MUST NOT become
        command arguments, environment, repository paths or shell input. The
        generated object graph, request, response and execution time are bounded.
        """
        # Git may include the default TLS port in Host and preserves the query
        # on its request target. Normalize only that transport framing before
        # matching the closed synthetic repository path.
        host = host.partition(":")[0].lower()
        parsed = urlsplit(path)
        query = parse_qs(parsed.query, keep_blank_values=True)
        path = parsed.path
        if host == "com-github.integration.internal" and path.startswith("/git/"):
            host, path = HOST, path.removeprefix("/git")
        if host != HOST:
            return None
        if len(body) > MAX_REQUEST:
            raise ValueError("oversized isolated Git fixture request")
        bare = str(self.root / "repository.git")
        if (
            method == "GET"
            and path == PREFIX + "/info/refs"
            and query == {"service": ["git-upload-pack"]}
            and not body
        ):
            return Response(
                b"application/x-git-upload-pack-advertisement",
                b"001e# service=git-upload-pack\n0000"
                + self.command(["upload-pack", "--stateless-rpc", "--advertise-refs", bare]),
            )
        if method == "POST" and path == PREFIX + "/git-upload-pack" and body:
            return Response(
                b"application/x-git-upload-pack-result",
                self.command(["upload-pack", "--stateless-rpc", bare], body),
            )
        if (
            self.allow_writes
            and method == "GET"
            and path == PREFIX + "/info/refs"
            and query == {"service": ["git-receive-pack"]}
            and not body
        ):
            return Response(
                b"application/x-git-receive-pack-advertisement",
                b"001f# service=git-receive-pack\n0000"
                + self.command(["receive-pack", "--stateless-rpc", "--advertise-refs", bare]),
            )
        if self.allow_writes and method == "POST" and path == PREFIX + "/git-receive-pack" and body:
            return Response(
                b"application/x-git-receive-pack-result",
                self.command(["receive-pack", "--stateless-rpc", bare], body),
            )
        raise ValueError("unknown isolated Git fixture route")


def dns_response(packet: bytes, address: str) -> bytes | None:
    """@cc [owner:ghuntley,label:verification;security] native-git-fixture-closed-dns
    DNS MUST answer only the synthetic Git host's A query with its fixed fixture
    IPv4 address; AAAA MUST return no addresses and other names MUST return
    NXDOMAIN. It MUST NOT forward, accept compressed questions or echo malformed
    framing. One bounded IN question and an optional empty EDNS record are allowed.
    """
    if not 12 <= len(packet) <= 512:
        return None
    ident, flags, questions, answers, authority, additional = struct.unpack("!6H", packet[:12])
    if flags & ~0x0130 or (questions, answers, authority) != (1, 0, 0) or additional > 1:
        return None
    labels: list[str] = []
    position = 12
    while position < len(packet):
        size = packet[position]
        position += 1
        if size == 0:
            break
        if size > 63 or position + size > len(packet):
            return None
        label = packet[position : position + size]
        if re.fullmatch(rb"[A-Za-z0-9-]+", label) is None:
            return None
        labels.append(label.decode("ascii").lower())
        position += size
    else:
        return None
    if position + 4 > len(packet) or len(".".join(labels)) > 253:
        return None
    kind, domain = struct.unpack("!2H", packet[position : position + 4])
    end = position + 4
    if domain != 1:
        return None
    tail = packet[end:]
    if additional:
        if (
            len(tail) != 11
            or tail[:3] != b"\x00\x00\x29"
            or tail[5:9] not in (b"\0\0\0\0", b"\0\0\x80\0")
            or tail[9:] != b"\0\0"
        ):
            return None
    elif tail:
        return None
    known = ".".join(labels) in {HOST, "com-github.integration.internal"}
    answer = (
        b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + ipaddress.IPv4Address(address).packed
        if known and kind == 1
        else b""
    )
    return (
        struct.pack(
            "!6H", ident, 0x8400 | (flags & 0x0100) | (0 if known else 3), 1, bool(answer), 0, 0
        )
        + packet[12:end]
        + answer
    )


class DNSHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        value: object = self.request
        if (
            not isinstance(value, tuple)
            or len(value) != 2
            or not isinstance(self.server, DNSServer)
        ):
            return
        packet: object = value[0]
        stream: object = value[1]
        if not isinstance(packet, bytes) or not isinstance(stream, socket.socket):
            return
        reply = dns_response(packet, self.server.answer)
        if reply is not None:
            stream.sendto(reply, self.client_address)


class DNSServer(socketserver.UDPServer):
    max_packet_size = 513

    def __init__(
        self, address: tuple[str, int], client_ips: frozenset[str], answer: str = "169.254.254.1"
    ) -> None:
        if str(ipaddress.IPv4Address(answer)) != answer or not client_ips:
            raise ValueError("invalid isolated DNS fixture")
        self.answer, self.client_ips = answer, client_ips
        super().__init__(address, DNSHandler)

    def verify_request(self, request: object, client_address: object) -> bool:
        return (
            isinstance(client_address, tuple)
            and len(client_address) == 2
            and client_address[0] in self.client_ips
        )

    def handle_error(self, request: object, client_address: object) -> None:
        """Never print request bytes or exception details."""
