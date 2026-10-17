"""Exercise the isolated authority's real TLS/signing and closed wire boundary."""

from __future__ import annotations

import json
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

import native_control as control


class AuthorityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="native-control-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.ca = self.root / "ssh-ca"
        self.user = self.root / "user"
        for path in (self.ca, self.user):
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", str(path)],
                check=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
        self.public = self.user.with_suffix(".pub").read_text().strip()
        self.receipt = self.root / "receipt.json"
        self.authority = control.Authority(
            control.Config(
                self.ca,
                "native.fixture.test",
                frozenset({"127.0.0.1"}),
                self.public,
                execution_probe=True,
                receipt=self.receipt,
            )
        )

    def rpc(self, path: str, body: object, *, ssh: bool = False) -> dict[str, object]:
        return self.authority.dispatch(
            "POST",
            "ssh.integration.internal" if ssh else "llm.internal",
            path,
            json.dumps(body).encode(),
        )

    def register(self) -> dict[str, object]:
        registration = self.rpc(
            "/agent/v1/register",
            {
                "digest": "a" * 64,
                "capabilities": ["context-v1", "skills-v1"],
            },
        )
        return {name: registration[name] for name in ("executor_id", "fence_epoch")}

    def test_real_host_certificate_and_exact_roster(self) -> None:
        roster = self.authority.dispatch("GET", "ssh.integration.internal", "/ssh/v1/roster", b"")
        self.assertEqual(
            roster, {"version": 1, "accounts": [{"username": "u200000", "uid": 200000}]}
        )
        signed = self.rpc("/ssh/v1/host-certificate", {"public_key": self.public}, ssh=True)
        certificate = signed["certificate"]
        self.assertIsInstance(certificate, str)
        if not isinstance(certificate, str):
            self.fail("certificate must be text")
        leaf = self.root / "host-cert.pub"
        leaf.write_text(certificate)
        report = subprocess.run(
            ["ssh-keygen", "-L", "-f", str(leaf)],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout
        fingerprint = subprocess.run(
            ["ssh-keygen", "-lf", str(self.ca.with_suffix(".pub"))],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.split()[1]
        self.assertIn("host certificate", report)
        self.assertIn("native.fixture.test", report)
        self.assertIn(fingerprint, report)
        self.assertEqual(signed["ca"], self.ca.with_suffix(".pub").read_text().strip())
        self.assertEqual(
            self.rpc(
                "/ssh/v1/authorize",
                {
                    "username": "u200000",
                    "public_key": self.public,
                },
                ssh=True,
            ),
            {"public_key": self.public},
        )

    def test_execution_order_exact_result_and_receipt(self) -> None:
        lease = self.register()
        self.assertIsNotNone(self.rpc("/agent/v1/claim", lease)["command"])
        self.assertEqual(self.rpc("/agent/v1/claim", lease), {"command": None})
        transition = {
            **lease,
            "command_id": control.COMMAND_ID,
            "status": "completed",
            "result": {"exit_code": 0, "stdout": control.PROOF, "stderr": ""},
        }
        with self.assertRaises(control.Refused):
            self.rpc("/agent/v1/transition", transition)
        self.rpc("/agent/v1/transition", {**transition, "status": "started", "result": {}})
        with self.assertRaises(control.Refused):
            self.rpc(
                "/agent/v1/transition",
                {
                    **transition,
                    "result": {
                        "exit_code": False,
                        "stdout": control.PROOF,
                        "stderr": "",
                    },
                },
            )
        self.rpc("/agent/v1/transition", transition)
        with self.assertRaises(control.Refused):
            self.rpc("/agent/v1/transition", transition)
        receipt = self.receipt.read_text()
        self.assertIn('"execution_completed": true', receipt)
        self.assertIn('"native_admission": false', receipt)
        for sensitive in (
            self.public,
            control.PROOF,
            str(lease["executor_id"]),
            control.COMMAND_ID,
        ):
            self.assertNotIn(sensitive, receipt)

    def test_login_refusal_does_not_turn_key_authorization_into_login_authority(self) -> None:
        self.authority.config = replace(self.authority.config, allow_login=False)
        identity = {"username": "u200000", "public_key": self.public}
        self.assertEqual(
            self.rpc("/ssh/v1/authorize", identity, ssh=True), {"public_key": self.public}
        )
        with self.assertRaisesRegex(control.Refused, "login refused"):
            self.rpc("/ssh/v1/login", identity, ssh=True)
        self.assertNotIn("login", self.authority.counters)
        self.assertEqual(self.authority.counters["login_refused"], 1)

    def test_stale_foreign_expired_and_restarted_execution_refused(self) -> None:
        old = self.register()
        self.rpc("/agent/v1/claim", old)
        new = self.register()
        for lease in (old, {**new, "executor_id": "foreign"}, {**new, "fence_epoch": True}):
            with self.assertRaises(control.Refused):
                self.rpc("/agent/v1/heartbeat", lease)
        with self.assertRaises(control.Refused):
            self.rpc(
                "/agent/v1/transition",
                {**new, "command_id": control.COMMAND_ID, "status": "started", "result": {}},
            )
        self.authority.lease_deadline = time.monotonic() - 1
        with self.assertRaises(control.Refused):
            self.rpc("/agent/v1/claim", new)

    def test_unknown_fields_hosts_and_keys_refused(self) -> None:
        for body in (
            b'{"public_key":"a","public_key":"b"}',
            b"[]",
            b'{"public_key":null}',
            json.dumps({"public_key": self.public, "extra": 1}).encode(),
        ):
            with self.assertRaises(control.Refused):
                self.authority.dispatch(
                    "POST", "ssh.integration.internal", "/ssh/v1/host-certificate", body
                )
        for public in (
            self.public + " comment",
            "ssh-ed25519 AAAA",
            self.public.replace("ssh-ed25519", "ssh-rsa"),
        ):
            with self.assertRaises(control.Refused):
                control.key(public)
        for host in (
            "foreign.internal",
            "ssh.integration.internal:443",
            "SSH.integration.internal",
        ):
            with self.assertRaises(control.Refused):
                self.authority.dispatch("GET", host, "/ssh/v1/roster", b"")

    def test_tls_verifies_hostname_and_refuses_foreign_roots(self) -> None:
        cert, private = self.root / "tls.pem", self.root / "tls.key"
        subprocess.run(
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
                "/CN=ssh.integration.internal",
                "-addext",
                "subjectAltName=DNS:ssh.integration.internal,DNS:llm.internal",
                "-keyout",
                str(private),
                "-out",
                str(cert),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, private)
        with control.Server(("127.0.0.1", 0), context, self.authority) as server:
            address = ("127.0.0.1", server.server_address[1])
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
            thread.start()
            try:
                trusted = ssl.create_default_context(cafile=cert)
                with (
                    socket.create_connection(address, timeout=3) as raw,
                    trusted.wrap_socket(raw, server_hostname="ssh.integration.internal") as stream,
                ):
                    stream.sendall(
                        b"GET /ssh/v1/roster HTTP/1.1\r\nHost: ssh.integration.internal\r\n\r\n"
                    )
                    response = bytearray()
                    while part := stream.recv(4096):
                        response.extend(part)
                self.assertIn(b"200 OK", response)
                self.assertIn(b'"username": "u200000"', response)
                for context, hostname in (
                    (trusted, "foreign.internal"),
                    (ssl.create_default_context(), "ssh.integration.internal"),
                ):
                    with (
                        socket.create_connection(address, timeout=3) as raw,
                        self.assertRaises(ssl.SSLCertVerificationError),
                    ):
                        context.wrap_socket(raw, server_hostname=hostname)
            finally:
                server.shutdown()
                thread.join(timeout=5)
                self.assertFalse(thread.is_alive())


class ParserTest(unittest.TestCase):
    def parse(self, payload: bytes) -> tuple[str, str, str, bytes]:
        left, right = socket.socketpair()
        with left, right:
            left.sendall(payload)
            left.shutdown(socket.SHUT_WR)
            return control.request(right)

    def test_framing_bounds_duplicates_chunking_and_pipelining_refused(self) -> None:
        for payload in (
            b"POST / HTTP/1.1\r\nHost: llm.internal\r\nContent-Length: 16385\r\n\r\n",
            b"POST / HTTP/1.1\r\nHost: llm.internal\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            b"GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
            b"GET / HTTP/1.1\r\nHost: a\r\n\r\nGET / HTTP/1.1\r\n\r\n",
            b"GET / HTTP/1.1\r\nHost: " + b"a" * 8192,
            b"POST / HTTP/1.1\r\nContent-Length: 2\r\n\r\nx",
        ):
            with self.assertRaises(control.Refused):
                self.parse(payload)

    def test_one_absolute_deadline_applies_to_partial_header(self) -> None:
        left, right = socket.socketpair()
        with left, right, patch.object(control, "DEADLINE", 0.05):
            left.sendall(b"GET / HTTP/1.1\r\n")
            start = time.monotonic()
            with self.assertRaises(TimeoutError):
                control.request(right)
            self.assertLess(time.monotonic() - start, 1)


if __name__ == "__main__":
    unittest.main()
