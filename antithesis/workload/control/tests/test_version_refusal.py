"""4001 terminal-refusal verdict needs the complete caller and accept ledger."""

import unittest
from typing import ClassVar
from unittest.mock import patch

from control import version_refusal
from control.peer import PeerResult
from core.outcome import Observation


class VersionRefusalTests(unittest.TestCase):
    complete: ClassVar[dict[str, bool | int]] = {
        "close_class": True,
        "pending_unproven": True,
        "status_retained": True,
        "post_refusal_disconnected": True,
        "client_alive": True,
        "handshakes_after_refusal": 0,
        "quiet_ms": 5_000,
    }

    def _run(self, fields: dict[str, bool | int]) -> tuple[bool | None, bool]:
        with (
            patch("control.version_refusal.choice", side_effect=(8, 50)),
            patch(
                "control.version_refusal.run_peer",
                return_value=Observation.observed(PeerResult(fields)),
            ),
            patch("control.version_refusal.always") as always,
            patch("control.version_refusal.reachable") as reachable,
        ):
            self.assertEqual(version_refusal.run_version_refusal(), 0)
            verdict = always.call_args.args[0] if always.called else None
            return verdict, reachable.called

    def test_complete_terminal_refusal_passes_and_reaches(self) -> None:
        self.assertEqual(self._run(dict(self.complete)), (True, True))

    def test_reconnect_or_lost_class_fails_without_reach(self) -> None:
        for fields in (
            {**self.complete, "handshakes_after_refusal": 1},
            {**self.complete, "close_class": False},
            {**self.complete, "status_retained": False},
            {**self.complete, "pending_unproven": False},
        ):
            with self.subTest(fields=fields):
                self.assertEqual(self._run(fields), (False, False))

    def test_incomplete_ledger_is_unexercised(self) -> None:
        for fields in (
            {key: value for key, value in self.complete.items() if key != "close_class"},
            {**self.complete, "quiet_ms": 1_000},
            {**self.complete, "handshakes_after_refusal": True},
        ):
            with self.subTest(fields=fields):
                self.assertEqual(self._run(fields), (None, False))

    def test_unavailable_peer_is_unexercised(self) -> None:
        with (
            patch("control.version_refusal.choice", side_effect=(8, 50)),
            patch(
                "control.version_refusal.run_peer",
                return_value=Observation.unavailable(),
            ),
            patch("control.version_refusal.always") as always,
            patch("control.version_refusal.reachable") as reachable,
        ):
            self.assertEqual(version_refusal.run_version_refusal(), 0)
            always.assert_not_called()
            reachable.assert_not_called()


if __name__ == "__main__":
    unittest.main()
