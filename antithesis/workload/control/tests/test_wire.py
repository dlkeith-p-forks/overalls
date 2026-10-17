"""Bounded parser and response-correlation tests for the harness wire client."""

import json
import unittest
from collections import deque
from collections.abc import Iterable

from control.client import ControlSession
from control.envelope import InvalidEnvelope, decode

HOST_ID = "cd9e681d-46d3-4213-9361-daa77f95f32d"


class FakeTransport:
    def __init__(self, incoming: Iterable[str | BaseException], *, send_lost: bool = False) -> None:
        self.incoming = deque(incoming)
        self.sent: list[str | bytes] = []
        self.send_lost = send_lost

    def send(self, message: str | bytes) -> None:
        self.sent.append(message)
        if self.send_lost:
            raise TimeoutError("injected uncertain write")

    def recv(self, timeout: float | None = None) -> str | bytes:
        if not self.incoming:
            raise TimeoutError("injected uncertain read")
        item = self.incoming.popleft()
        if isinstance(item, BaseException):
            raise item
        return item

    def close(self) -> None:
        return None


class WireTests(unittest.TestCase):
    def test_closed_parser_rejects_duplicate_unknown_and_unbounded_frames(self) -> None:
        for frame in (
            '{"k":"resync","k":"resync"}',
            '{"k":"resync","extra":1}',
            '{"k":"res","id":true,"ok":true,"body":{}}',
            '{"k":[],"n":1}',
            '{"k":"ping","n":9007199254740992}',
            "x" * 1_052_673,
        ):
            with self.subTest(frame=frame[:80]), self.assertRaises(InvalidEnvelope):
                decode(frame)

    def test_request_waits_through_interleaved_control_frames(self) -> None:
        incoming = (
            '{"k":"welcome","conn":"c","heartbeat_ms":5000,"limits":{}}',
            '{"k":"ping","n":7}',
            '{"k":"resync"}',
            '{"k":"res","id":4,"ok":false,"error":"unauthorized"}',
        )
        peer = FakeTransport(incoming)
        session = ControlSession(peer)
        welcome = session.bind_lilly(HOST_ID).message
        assert welcome is not None
        self.assertEqual(welcome["k"], "welcome")
        result = session.exchange(4, "lilly.sessions", {"version": 4})
        self.assertTrue(result.attempted)
        self.assertTrue(result.acknowledged)
        assert result.response is not None
        self.assertEqual(result.response["error"], "unauthorized")
        self.assertEqual(json.loads(peer.sent[-1]), {"k": "pong", "n": 7})

    def test_send_or_read_loss_remains_unproven(self) -> None:
        welcome = '{"k":"welcome","conn":"c","heartbeat_ms":5000,"limits":{}}'
        for peer in (
            FakeTransport((welcome,)),
            FakeTransport((welcome, TimeoutError("lost reply"))),
        ):
            with self.subTest(peer=peer):
                session = ControlSession(peer)
                session.bind_lilly(HOST_ID)
                if len(peer.incoming) == 0:
                    peer.send_lost = True
                result = session.exchange(0, "lilly.sessions", {})
                self.assertTrue(result.attempted)
                self.assertFalse(result.acknowledged)
                self.assertIsNone(result.response)

    def test_application_request_requires_welcome(self) -> None:
        session = ControlSession(FakeTransport(()))
        with self.assertRaises(ValueError):
            session.exchange(1, "lilly.sessions", {})

    def test_deliberate_post_bind_frame_is_sent_once(self) -> None:
        peer = FakeTransport(('{"k":"welcome","conn":"c","heartbeat_ms":5000,"limits":{}}',))
        session = ControlSession(peer)
        with self.assertRaises(ValueError):
            session.send_raw_frame('{"k":"resync"}')
        session.bind_lilly(HOST_ID)
        peer.send_lost = True
        self.assertFalse(session.send_raw_frame('{"k":"resync"}'))
        self.assertEqual(peer.sent[-1], '{"k":"resync"}')
        self.assertEqual(len(peer.sent), 2)
