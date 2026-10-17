"""Exercise service-client framing/refusal oracles; no native runtime claims."""

from __future__ import annotations

import json
import socket
import struct
import tempfile
import time
import unittest
from collections.abc import Callable, Iterator
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from pathlib import Path

import native_services as services

BINDING = services.Binding("dddddddd-dddd-4ddd-8ddd-000000000201", 7, "b" * 64)
BOOT = services.Boot(BINDING, "0f0e0d0c-0b0a-4908-8706-050403020100")


@contextmanager
def peer(handler: Callable[[services.Connection], None]) -> Iterator[Path]:
    """One bounded local Firecracker handshake fixture, without a guest VM."""
    with tempfile.TemporaryDirectory(prefix="native-services-") as directory:
        path = Path(directory) / "v.sock"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.settimeout(3)
            listener.bind(str(path))
            listener.listen(1)

            def serve() -> None:
                with listener.accept()[0] as stream:
                    channel = services.Connection(stream, time.monotonic() + 3)
                    request = channel.line(64)
                    if not request.startswith(b"CONNECT "):
                        raise RuntimeError("invalid local service fixture handshake")
                    channel.send(b"OK 1234\n")
                    handler(channel)

            with ThreadPoolExecutor(max_workers=1) as executor:
                completed = executor.submit(serve)
                try:
                    yield path
                finally:
                    completed.result(timeout=4)


class NativeServiceClientTests(unittest.TestCase):
    """Untrusted bytes cannot make an incomplete service history look successful."""

    def test_readiness_requires_exact_identity_and_scalar_types(self) -> None:
        good = {"version": 1, "state": "ready", **BOOT.fields()}
        mutations: list[dict[str, object]] = [
            {**good, "execution_epoch": 8},
            {**good, "version": True},
            {**good, "unexpected": 1},
            {**good, "boot_id": "invalid"},
        ]
        for mutation in mutations:
            with self.subTest(kind=list(mutation)):

                def answer(
                    channel: services.Connection, message: bytes = services.encode(mutation) + b"\n"
                ) -> None:
                    channel.send(message)

                with peer(answer) as path, self.assertRaises(services.ProtocolError):
                    services.readiness(path, BINDING)

        def correct(channel: services.Connection) -> None:
            channel.send(services.encode(good) + b"\n")

        with peer(correct) as path:
            self.assertEqual(services.readiness(path, BINDING), BOOT)

    def test_duplicate_and_nonobject_json_never_narrow(self) -> None:
        for body in (b'{"version":2,"version":1}', b"[]", b"true", b"null", b"\xff"):
            with self.subTest(body=body), self.assertRaises(services.ProtocolError):
                services.decode_object(body)

    def test_truncated_and_oversized_frames_fail_before_parsing(self) -> None:
        for data in (b"\x00\x00", struct.pack(">I", services.MAX_FRAME + 1), b"\x00" * 4):
            with self.subTest(size=len(data)):
                reader, writer = socket.socketpair()
                with reader, writer:
                    writer.sendall(data)
                    writer.shutdown(socket.SHUT_WR)
                    channel = services.Connection(reader, time.monotonic() + 1)
                    with self.assertRaises(services.ProtocolError):
                        channel.framed_object()

    def test_bounded_line_does_not_consume_next_frame(self) -> None:
        reader, writer = socket.socketpair()
        with reader, writer:
            writer.sendall(b"first\nsecond\n")
            channel = services.Connection(reader, time.monotonic() + 1)
            self.assertEqual(channel.line(6), b"first\n")
            self.assertEqual(channel.line(7), b"second\n")
            writer.sendall(b"oversized\n")
            with self.assertRaises(services.ProtocolError):
                channel.line(4)

    def test_expired_deadline_fails_with_data_already_available(self) -> None:
        reader, writer = socket.socketpair()
        with reader, writer:
            writer.sendall(b"ready\n")
            channel = services.Connection(reader, time.monotonic() - 1)
            with self.assertRaises(TimeoutError):
                channel.line(6)

    def test_refusal_requires_connected_peer_close_and_no_bytes(self) -> None:
        def close(channel: services.Connection) -> None:
            self.assertEqual(channel.exact(3), b"bad")

        with peer(close) as path:
            services.refused(path, 1026, b"bad")

        def unexpected(channel: services.Connection) -> None:
            channel.exact(3)
            channel.send(b"unexpected")

        with peer(unexpected) as path, self.assertRaises(services.ProtocolError):
            services.refused(path, 1026, b"bad")
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(OSError):
            services.refused(Path(directory) / "missing", 1026, b"bad")

    def test_withheld_readiness_requires_a_live_daemon_and_no_response(self) -> None:
        def close(_channel: services.Connection) -> None:
            return

        with peer(close) as path:
            services.readiness_withheld(path)

        def answer(channel: services.Connection) -> None:
            channel.send(services.encode({"version": 1, "state": "ready", **BOOT.fields()}) + b"\n")

        with peer(answer) as path, self.assertRaises(services.ProtocolError):
            services.readiness_withheld(path)

    def test_refusal_cannot_hide_bad_firecracker_handshake(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "v.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(path))
                listener.listen(1)
                listener.settimeout(2)

                def serve() -> None:
                    with listener.accept()[0] as stream:
                        stream.settimeout(2)
                        stream.recv(64)
                        stream.sendall(b"ERR\n")

                with ThreadPoolExecutor(max_workers=1) as executor:
                    task = executor.submit(serve)
                    with self.assertRaises(services.ProtocolError):
                        services.refused(path, 1026, b"bad")
                    task.result(timeout=3)

    def test_kernel_attestation_is_bound_to_boot_and_exact_digest(self) -> None:
        def answer(channel: services.Connection) -> None:
            channel.send(
                services.encode(
                    {
                        "version": 1,
                        "state": "attested",
                        "os": "freebsd",
                        **BOOT.fields(),
                        "kernel_sha256": "a" * 64,
                    }
                )
                + b"\n"
            )

        with peer(answer) as path:
            services.kernel(path, BOOT, "freebsd", "a" * 64)
        with peer(answer) as path:
            self.assertEqual(services.kernel_boot(path, BINDING, "freebsd", "a" * 64), BOOT)
        with peer(answer) as path, self.assertRaises(services.ProtocolError):
            services.kernel(path, BOOT, "freebsd", "c" * 64)

    def test_fixture_file_has_closed_keys_and_no_boolean_epoch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "binding.json"
            path.write_text(json.dumps(BINDING.fields()), encoding="utf-8")
            self.assertEqual(services.fixture_binding(path), BINDING)
            for mutation in (
                {**BINDING.fields(), "execution_epoch": True},
                {**BINDING.fields(), "unexpected": 1},
            ):
                path.write_text(json.dumps(mutation), encoding="utf-8")
                with self.assertRaises(ValueError):
                    services.fixture_binding(path)

    def test_terminal_proof_changes_for_every_binding_dimension(self) -> None:
        nonce = bytes(range(16))
        proof = services.terminal_hello(BINDING, nonce)
        self.assertEqual(len(proof), 48)
        self.assertEqual(proof[:16], nonce)
        alternatives = (
            services.Binding(BINDING.placement_id, 8, BINDING.boot_challenge),
            services.Binding(BINDING.placement_id, 7, "c" * 64),
            services.Binding("dddddddd-dddd-4ddd-8ddd-000000000202", 7, BINDING.boot_challenge),
        )
        for alternative in alternatives:
            self.assertNotEqual(services.terminal_hello(alternative, nonce), proof)
        self.assertNotEqual(services.terminal_hello(BINDING, b"x" * 16), proof)


if __name__ == "__main__":
    unittest.main()
