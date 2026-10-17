"""Private SMTP receiver validation; synthetic values, no external mail."""

import json
import socket
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, sys.argv.pop(1))
import credentials  # ty: ignore[unresolved-import] # argv[1] guest inception package
import prepare  # ty: ignore[unresolved-import] # argv[1] guest inception package
from runtime import (  # ty: ignore[unresolved-import] # argv[1] guest inception package
    SetupError,
    encode,
    identities,
    private_directory,
    read_private,
)

BOOT = {
    "placement_id": "11111111-1111-4111-8111-111111111111",
    "execution_epoch": 7,
    "boot_challenge": "a" * 64,
}
SMTP = {
    "version": 1,
    "host": "smtp.example.test",
    "port": 587,
    "username": "fixture",
    "password": "synthetic-password",
    "from": "dev@example.test",
    "tls": "starttls",
}


class CredentialsTest(unittest.TestCase):
    def wire(self, **changes: object) -> bytes:
        return encode({"version": 1, **BOOT, "smtp": SMTP, **changes}) + b"\n"

    def test_each_boot_component_and_closed_envelope_are_required(self) -> None:
        self.assertEqual(credentials.envelope(self.wire(), BOOT), SMTP)
        for changes in [
            {"version": True},
            {"version": 2},
            {"path": "/tmp/file"},
            {"execution_epoch": True},
            {"execution_epoch": 8},
            {"placement_id": "22222222-2222-4222-8222-222222222222"},
            {"boot_challenge": "b" * 64},
        ]:
            with self.assertRaises(SetupError):
                credentials.envelope(self.wire(**changes), BOOT)
        for key in ["version", *BOOT, "smtp"]:
            value = json.loads(self.wire())
            del value[key]
            with self.assertRaises(SetupError):
                credentials.envelope(encode(value), BOOT)

    def test_nonhost_is_rejected_without_reading_or_applying_input(self) -> None:
        for cid in [0, 1, 3, 42]:
            server, client = socket.socketpair()
            with server, client:
                accept = Mock()
                credentials.answer(server, (cid, 1025), BOOT, accept)
                accept.assert_not_called()
                server.shutdown(socket.SHUT_WR)
                self.assertEqual(client.recv(1), b"")

    def test_host_receives_only_boot_bound_ack_after_success(self) -> None:
        for success in [True, False]:
            server, client = socket.socketpair()
            with server, client:
                client.sendall(self.wire())
                accept = Mock(side_effect=None if success else SetupError("not applied"))
                if success:
                    credentials.answer(server, (2, 1025), BOOT, accept)
                else:
                    with self.assertRaises(SetupError):
                        credentials.answer(server, (2, 1025), BOOT, accept)
                server.shutdown(socket.SHUT_WR)
                result = client.recv(1024)
                if success:
                    self.assertEqual(
                        json.loads(result), {"version": 1, "state": "configured", **BOOT}
                    )
                    accept.assert_called_once_with(SMTP)
                else:
                    self.assertEqual(result, b"")

    def test_unterminated_and_oversized_input_never_reaches_install(self) -> None:
        for body in [b"{}", b"x" * (credentials.LIMIT + 1) + b"\n"]:
            server, client = socket.socketpair()
            with server, client:
                client.sendall(body)
                client.shutdown(socket.SHUT_WR)
                accept = Mock()
                with self.assertRaises(SetupError):
                    credentials.answer(server, (2, 1025), BOOT, accept)
                accept.assert_not_called()

    def test_rotation_and_interrupted_retry_preserve_internal_identity(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            state = private_directory(Path(root) / "state")
            runtime = private_directory(Path(root) / "runtime")
            ca = Path(root) / "ca.crt"
            ca.write_bytes(b"synthetic public system CA")
            identity = identities(state)
            with (
                patch.object(prepare, "STATE", state),
                patch.object(prepare, "RUNTIME", runtime),
                patch.object(prepare, "public_certificate"),
            ):
                restart = Mock()
                credentials.install(SMTP, {"system_ca": str(ca)}, restart)
                credentials.install(SMTP, {"system_ca": str(ca)}, restart)
                restart.assert_called_once_with()
                next_bundle = {**SMTP, "password": "rotated-synthetic-password"}
                restart.side_effect = SetupError("restart unavailable")
                with self.assertRaises(SetupError):
                    credentials.install(next_bundle, {"system_ca": str(ca)}, restart)
                self.assertEqual(json.loads(read_private(runtime / "smtp-applied.json")), SMTP)
                restart.side_effect = None
                credentials.install(next_bundle, {"system_ca": str(ca)}, restart)
                self.assertEqual(restart.call_count, 3)
                self.assertEqual(
                    json.loads(read_private(runtime / "smtp-applied.json")), next_bundle
                )
                self.assertEqual(identities(state), identity)
                env = json.loads(read_private(runtime / "environment.json"))
                self.assertEqual(env["MARSHALL_SMTP_PASSWORD"], next_bundle["password"])
                self.assertEqual(env["SECRET_KEY_BASE"], identity["secret_key_base"])
                with self.assertRaises(SetupError):
                    credentials.install(
                        {**next_bundle, "database_password": "forbidden"},
                        {"system_ca": str(ca)},
                        restart,
                    )
                self.assertEqual(json.loads(read_private(runtime / "smtp.json")), next_bundle)
                for path in runtime.iterdir():
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
