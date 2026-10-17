"""Guest flush protocol failure boundaries over real local sockets."""

import contextlib
import importlib.util
import json
import socket
import subprocess
import sys
import unittest

spec = importlib.util.spec_from_file_location("flush", sys.argv.pop(1))
if spec is None or spec.loader is None:
    raise RuntimeError("flush helper unavailable")
flush = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flush)
BOOT = {
    "placement_id": "11111111-1111-4111-8111-111111111111",
    "execution_epoch": 3,
    "boot_challenge": "a" * 64,
}
BOOT_ID = "22222222-2222-4222-8222-222222222222"
REQUEST = {"version": 1, "operation": "sync", "nonce": "b" * 64, **BOOT}


class FlushTest(unittest.TestCase):
    def exchange(
        self, request: object, peer: int = 2, failure: Exception | None = None
    ) -> tuple[bytes, list[str]]:
        calls: list[str] = []

        def sync() -> None:
            calls.append("sync")
            if failure:
                raise failure

        client, server = socket.socketpair()
        with client, server:
            client.sendall(
                request if isinstance(request, bytes) else json.dumps(request).encode() + b"\n"
            )
            client.shutdown(socket.SHUT_WR)
            with contextlib.suppress(ValueError, subprocess.SubprocessError):
                flush.answer(server, (peer, 1), BOOT, BOOT_ID, sync)
            server.shutdown(socket.SHUT_WR)
            return client.recv(2048), calls

    def test_acknowledges_only_after_sync_and_binds_request_and_boot(self) -> None:
        reply, calls = self.exchange(REQUEST)
        self.assertEqual(calls, ["sync"])
        self.assertEqual(
            json.loads(reply),
            {
                "version": 1,
                "state": "flushed",
                "nonce": REQUEST["nonce"],
                "boot_id": BOOT_ID,
                **BOOT,
            },
        )

    def test_rejects_foreign_peer_and_invalid_requests_without_sync(self) -> None:
        self.assertEqual(self.exchange(REQUEST, peer=3), (b"", []))
        for value in [
            [],
            {},
            {**REQUEST, "command": "freeze"},
            {**REQUEST, "operation": "freeze"},
            {**REQUEST, "nonce": "bad"},
            {**REQUEST, "version": True},
            {**REQUEST, "execution_epoch": 2},
            {**REQUEST, "boot_challenge": "c" * 64},
            b"x" * 1025,
            b"{}",
            b"not-json\n",
        ]:
            with self.subTest(value=value):
                self.assertEqual(self.exchange(value), (b"", []))

    def test_failed_or_timed_out_sync_never_acknowledges_success(self) -> None:
        for failure in [
            subprocess.CalledProcessError(1, "sync"),
            subprocess.TimeoutExpired("sync", 8),
        ]:
            self.assertEqual(self.exchange(REQUEST, failure=failure), (b"", ["sync"]))


unittest.main()
