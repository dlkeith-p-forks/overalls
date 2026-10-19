"""Real shallow TLS clones and closed DNS boundary regressions."""

from __future__ import annotations

import hashlib
import os
import shutil
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

import native_control as control
import native_git_fixture as fixture


class GitFixtureTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="native-git-https-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        git = shutil.which("git")
        if git is None:
            self.fail("native Git fixture tests require actual Git")
        self.git = Path(git)
        self.repository = fixture.Repository.create(self.root / "repository", self.git)

    def command(self, arguments: list[str]) -> None:
        subprocess.run(
            arguments,
            check=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )

    def test_repository_commit_and_file_manifest_are_deterministic(self) -> None:
        other = fixture.Repository.create(self.root / "other", self.git)
        self.assertEqual(self.repository.commit, other.commit)
        self.assertEqual(self.repository.manifest, other.manifest)
        self.assertEqual(self.repository.source()["provider"], "github")
        with self.assertRaises(FileExistsError):
            fixture.Repository.create(self.root / "repository", self.git)

    def test_exact_git_routes_and_framing_refuse(self) -> None:
        self.assertIsNone(self.repository.response("GET", "foreign.test", "/", b""))
        for method, path, body in (
            ("GET", fixture.PREFIX + "/../config", b""),
            ("POST", fixture.PREFIX + "/git-receive-pack", b"0000"),
            ("GET", fixture.PREFIX + "/info/refs?service=git-receive-pack", b""),
            ("POST", fixture.PREFIX + "/git-upload-pack", b"x" * 16_385),
            ("POST", fixture.PREFIX + "/git-upload-pack", b"not-a-git-packet"),
            ("POST", fixture.PREFIX + "/git-upload-pack?service=git-upload-pack", b"0000"),
            ("GET", fixture.PREFIX + "/info/refs?service=git-upload-pack&extra=1", b""),
            (
                "GET",
                fixture.PREFIX + "/info/refs?service=git-upload-pack&service=git-upload-pack",
                b"",
            ),
        ):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.repository.response(method, fixture.HOST, path, body)

    def test_advertisements_match_service_query_separately_from_repository_path(self) -> None:
        writable = fixture.Repository.create(self.root / "writable", self.git, allow_writes=True)
        for host, prefix in (
            (fixture.HOST + ":443", fixture.PREFIX),
            ("com-github.integration.internal", "/git" + fixture.PREFIX),
        ):
            for service in ("git-upload-pack", "git-receive-pack"):
                with self.subTest(host=host, service=service):
                    result = writable.response(
                        "GET", host, prefix + "/info/refs?service=" + service, b""
                    )
                    self.assertIsNotNone(result)
                    assert result is not None
                    self.assertEqual(
                        result.content_type,
                        ("application/x-" + service + "-advertisement").encode(),
                    )
                    self.assertIn(writable.commit.encode(), result.body)

    def test_real_shallow_git_clone_requires_fixture_ca_and_has_exact_tree(self) -> None:
        ca, ca_key = self.root / "ca.pem", self.root / "ca.key"
        cert, key, csr = self.root / "leaf.pem", self.root / "leaf.key", self.root / "leaf.csr"
        self.command(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-subj",
                "/CN=Native Git fixture root",
                "-addext",
                "basicConstraints=critical,CA:TRUE",
                "-keyout",
                str(ca_key),
                "-out",
                str(ca),
            ]
        )
        self.command(
            [
                "openssl",
                "req",
                "-new",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-subj",
                "/CN=github.com",
                "-keyout",
                str(key),
                "-out",
                str(csr),
            ]
        )
        extensions = self.root / "leaf.ext"
        extensions.write_text("basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:github.com\n")
        self.command(
            [
                "openssl",
                "x509",
                "-req",
                "-in",
                str(csr),
                "-CA",
                str(ca),
                "-CAkey",
                str(ca_key),
                "-CAcreateserial",
                "-days",
                "1",
                "-extfile",
                str(extensions),
                "-out",
                str(cert),
            ]
        )
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        authority = control.Authority(
            control.Config(self.root / "unused", "native.fixture.test", frozenset({"127.0.0.1"}))
        )
        with control.Server(("127.0.0.1", 0), context, authority, self.repository) as server:
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
            thread.start()
            try:
                port = server.server_address[1]
                arguments = [
                    str(self.git),
                    "-c",
                    f"http.curloptResolve=github.com:{port}:127.0.0.1",
                    "-c",
                    "http.extraHeader=Host: github.com",
                    "clone",
                    "--depth",
                    "1",
                    "--",
                    f"https://github.com:{port}{fixture.PREFIX}",
                ]
                environment = {
                    "PATH": os.defpath,
                    "HOME": str(self.root),
                    "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_CONFIG_GLOBAL": "/dev/null",
                    "GIT_TERMINAL_PROMPT": "0",
                }
                refused = subprocess.run(
                    [*arguments, str(self.root / "untrusted")],
                    env=environment,
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    timeout=10,
                )
                self.assertNotEqual(refused.returncode, 0)
                checkout = self.root / "checkout"
                subprocess.run(
                    [*arguments, str(checkout)],
                    env={**environment, "GIT_SSL_CAINFO": str(ca)},
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    check=True,
                    timeout=10,
                )
                self.assertEqual(
                    (checkout / ".git/shallow").read_text().strip(), self.repository.commit
                )
                head = (
                    subprocess.run(
                        [str(self.git), "-C", str(checkout), "rev-parse", "HEAD"],
                        capture_output=True,
                        check=True,
                        timeout=5,
                    )
                    .stdout.decode()
                    .strip()
                )
                self.assertEqual(head, self.repository.commit)
                for name, digest in self.repository.manifest.items():
                    self.assertEqual(
                        hashlib.sha256((checkout / name).read_bytes()).hexdigest(), digest
                    )
            finally:
                server.shutdown()
                thread.join(timeout=3)


class DNSFixtureTest(unittest.TestCase):
    def question(self, host: str = fixture.HOST, kind: int = 1) -> bytes:
        labels = b"".join(bytes([len(label)]) + label.encode() for label in host.split("."))
        return (
            struct.pack("!6H", 42, 0x0100, 1, 0, 0, 0)
            + labels
            + b"\0"
            + struct.pack("!2H", kind, 1)
        )

    def test_exact_dns_answers_and_malformed_queries(self) -> None:
        query = self.question()
        for host in (fixture.HOST, "com-github.integration.internal", "llm.internal"):
            response = fixture.dns_response(self.question(host), "169.254.254.1")
            if response is None:
                self.fail("exact fixture DNS query must respond")
            self.assertEqual(response[-4:], socket.inet_aton("169.254.254.1"))
            self.assertEqual(struct.unpack("!6H", response[:12])[3], 1)
        for host, kind, expected_code in (
            (fixture.HOST, 28, 0),
            ("llm.internal", 28, 0),
            ("foreign.test", 1, 3),
            ("llm.internal.foreign.test", 1, 3),
        ):
            response = fixture.dns_response(self.question(host, kind), "169.254.254.1")
            if response is None:
                self.fail("valid negative fixture DNS query must respond")
            fields = struct.unpack("!6H", response[:12])
            self.assertEqual(fields[1] & 15, expected_code)
            self.assertEqual(fields[3], 0)
        for packet in (
            query + b"foreign",
            query[:12] + b"\xc0\x0c" + query[-4:],
            b"x" * 513,
            query[:-1],
        ):
            self.assertIsNone(fixture.dns_response(packet, "169.254.254.1"))

    def test_real_udp_socket_and_edns_query(self) -> None:
        packet = bytearray(self.question())
        packet[10:12] = b"\0\x01"
        packet.extend(b"\x00\x00\x29\x04\xd0\0\0\0\0\0\0")
        with fixture.DNSServer(("127.0.0.1", 0), frozenset({"127.0.0.1"})) as server:
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
            thread.start()
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                    client.settimeout(3)
                    client.sendto(packet, server.server_address)
                    response, _ = client.recvfrom(512)
                    self.assertEqual(response[-4:], socket.inet_aton("169.254.254.1"))
            finally:
                server.shutdown()
                thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
