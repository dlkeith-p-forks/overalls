"""SMTP transport acceptance, TLS identity and ledger restart tests."""

from __future__ import annotations

import base64
import http.client
import http.server
import json
import os
import smtplib
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
from sys import executable

from origin.server import prepare_tls
from smtp.server import AdminHandler, SMTPHandler, SMTPServer, State


class VerifiedSMTP(smtplib.SMTP_SSL):
    def _get_socket(self, host: str, port: int, timeout: float) -> ssl.SSLSocket:
        _ = host
        raw = socket.create_connection(("127.0.0.1", port), timeout)
        return self.context.wrap_socket(raw, server_hostname="smtp.fixture.test")


class SMTPTest(unittest.TestCase):
    temporary: tempfile.TemporaryDirectory[str]
    server: SMTPServer
    admin: http.server.ThreadingHTTPServer
    state: State

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.state = State(root)
        prepare_tls(root)
        SMTPHandler.state = self.state
        self.server = SMTPServer(("127.0.0.1", 0), SMTPHandler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(root / "server.pem", root / "server.key")
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        AdminHandler.state = self.state
        self.admin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), AdminHandler)
        self.admin.socket = context.wrap_socket(self.admin.socket, server_side=True)
        threading.Thread(target=self.admin.serve_forever, daemon=True).start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.admin.shutdown()
        self.server.server_close()
        self.admin.server_close()
        self.temporary.cleanup()

    def test_tls_authenticated_acceptance_is_durable_and_content_free(self) -> None:
        context = ssl.create_default_context(cafile=str(Path(self.temporary.name) / "ca.pem"))
        with VerifiedSMTP(
            "smtp.fixture.test", self.server.server_address[1], context=context, timeout=3
        ) as client:
            with self.assertRaises(smtplib.SMTPAuthenticationError):
                client.login("fixture", "incorrect")
            client.login("fixture", self.state.password)
            refused = client.sendmail(
                "sender@example.test",
                ["recipient@example.test"],
                "Message-ID: <fixture-mail-1@example.test>\r\nSubject: synthetic\r\n\r\nprivate-mail-marker\r\n",
            )
            self.assertEqual(refused, {})
        self.assertEqual(self.state.seq, 1)
        journal = self.state.journal.read_bytes()
        self.assertNotIn(b"private-mail-marker", journal)
        self.assertNotIn(b"recipient@example.test", journal)
        admin_context = ssl.create_default_context(cafile=str(Path(self.temporary.name) / "ca.pem"))
        admin_context.check_hostname = False
        connection = http.client.HTTPSConnection(
            "127.0.0.1", self.admin.server_port, timeout=3, context=admin_context
        )
        connection.request(
            "GET",
            "/v1/messages?after=0&limit=1",
            headers={"X-Fixture-Admin-Token": self.state.admin_token},
        )
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        body = json.loads(response.read())
        connection.close()
        self.assertEqual(body["sequence"], 1)
        message = body["messages"][0]
        self.assertEqual(message["recipient"], "<recipient@example.test>")
        self.assertEqual(message["message_id"], "<fixture-mail-1@example.test>")
        self.assertIn(b"private-mail-marker", base64.b64decode(message["data_b64"]))
        restarted = State(Path(self.temporary.name))
        self.assertEqual(restarted.seq, 1)
        self.assertEqual(restarted.receipts(0, 10)[0]["kind"], "accepted")
        with self.assertRaises(LookupError):
            restarted.captured_after(0, 1)

    def test_server_exits_on_sigterm(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            process = subprocess.Popen(
                [executable, "-m", "smtp", "serve"],
                env=os.environ
                | {
                    "SMTP_STATE_DIR": temporary,
                    "SMTP_TLS_PORT": "0",
                    "SMTP_ADMIN_TLS_PORT": "0",
                    "SMTP_HEALTH_PORT": "0",
                },
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                for _ in range(100):
                    if (Path(temporary) / "ca.pem").exists():
                        break
                    self.assertIsNone(process.poll())
                    time.sleep(0.02)
                self.assertTrue((Path(temporary) / "ca.pem").exists())
                time.sleep(0.1)
                process.terminate()
                self.assertEqual(process.wait(timeout=3), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
