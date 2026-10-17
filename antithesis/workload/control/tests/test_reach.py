"""Reach claims require the complete independent caller and wire ledger."""

import unittest
from unittest.mock import patch

from control import bounds, pending
from control.peer import PeerResult
from core.outcome import Observation


class ControlReachTests(unittest.TestCase):
    def test_capacity_incomplete_or_wrong_inventory_never_reaches(self) -> None:
        complete: dict[str, bool | int] = {
            "inventory_complete": True,
            "wire_ids_unique": True,
            "busy": True,
            "busy_no_frame": True,
            "matching": True,
            "no_replay": True,
            "fresh": True,
            "observed": 8,
            "limit": 8,
        }
        variants = (
            {**complete, "observed": 7},
            {**complete, "busy_no_frame": False},
            {**complete, "inventory_complete": False},
            {key: value for key, value in complete.items() if key != "wire_ids_unique"},
        )
        for fields in variants:
            with (
                self.subTest(fields=fields),
                patch("control.bounds.choice", return_value=8),
                patch(
                    "control.bounds.run_peer", return_value=Observation.observed(PeerResult(fields))
                ),
                patch("control.bounds.always") as always,
                patch("control.bounds.reachable") as reachable,
            ):
                self.assertEqual(bounds.run_bounds(), 0)
                reachable.assert_not_called()
                if "wire_ids_unique" in fields:
                    self.assertIs(always.call_args.args[0], False)
                else:
                    always.assert_not_called()

    def test_pending_incomplete_or_invalid_ledger_never_reaches(self) -> None:
        complete: dict[str, bool | int] = {
            "distinct_ids": True,
            "reordered_matching": True,
            "timeout_retired": True,
            "late_ignored": True,
            "loss_unproven": True,
            "no_replay": True,
            "sentinel_matching": True,
        }
        variants = (
            {**complete, "distinct_ids": False},
            {**complete, "no_replay": False},
            {key: value for key, value in complete.items() if key != "loss_unproven"},
        )
        for fields in variants:
            with (
                self.subTest(fields=fields),
                patch("control.pending.choice", side_effect=(8, 50)),
                patch(
                    "control.pending.run_peer",
                    return_value=Observation.observed(PeerResult(fields)),
                ),
                patch("control.pending.always") as always,
                patch("control.pending.reachable") as reachable,
            ):
                self.assertEqual(pending.run_pending(), 0)
                reachable.assert_not_called()
                if "loss_unproven" in fields:
                    self.assertIs(always.call_args.args[0], False)
                else:
                    always.assert_not_called()


if __name__ == "__main__":
    unittest.main()
