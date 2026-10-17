"""Snapshot and reply boundaries for hosted host-session fence verdicts."""

import unittest
from collections.abc import Sequence
from datetime import UTC, datetime
from typing import LiteralString
from uuid import UUID

from control.client import RequestResult
from control.host_sessions import (
    HostSnapshot,
    _exchange_accepted,
    _opened,
    _snapshot,
    _stale_verdict,
)
from core.outcome import Observation, State
from core.sql import SqlOracle

HOST_ID = UUID("cd9e681d-46d3-4213-9361-daa77f95f32d")
SESSION_ID = UUID("4fdce074-689a-4c8a-9c9c-d709162f3e56")
EMPTY_DIGEST = "d41d8cd98f00b204e9800998ecf8427e"


class FixedSql(SqlOracle):
    def __init__(self, result: Observation[tuple[tuple[object, ...], ...]]) -> None:
        self.result = result
        self.statement = ""
        self.parameters: tuple[object, ...] = ()

    def select(
        self,
        statement: LiteralString,
        parameters: Sequence[object] = (),
        *,
        maximum_rows: int = 4096,
    ) -> Observation[tuple[tuple[object, ...], ...]]:
        self.statement = statement
        self.parameters = tuple(parameters)
        if maximum_rows != 1:
            raise AssertionError("host snapshot query must be bounded")
        return self.result


class HostSessionWitnessTests(unittest.TestCase):
    def test_snapshot_keeps_independent_effects_in_one_sql_read(self) -> None:
        rows: tuple[tuple[object, ...], ...] = (
            (
                SESSION_ID,
                3,
                1,
                datetime(2026, 10, 13, tzinfo=UTC),
                2,
                EMPTY_DIGEST,
                EMPTY_DIGEST,
                EMPTY_DIGEST,
            ),
        )
        sql = FixedSql(Observation.observed(rows))
        witness = _snapshot(sql, HOST_ID)
        self.assertIs(witness.state, State.OBSERVED)
        assert witness.value is not None
        self.assertEqual(witness.value.session_id, SESSION_ID)
        self.assertEqual(witness.value.epoch, 3)
        self.assertEqual(sql.parameters, (str(HOST_ID),))
        for table in (
            "compute_hosts",
            "compute_host_sessions",
            "compute_operations",
            "compute_physical_outcomes",
            "compute_reservations",
        ):
            self.assertIn(table, sql.statement)

    def test_missing_or_malformed_sql_never_becomes_absent_effect(self) -> None:
        for observed in (
            Observation.unavailable(),
            Observation.observed(()),
            Observation.observed(((None, 1, 0, None, 0, "bad", EMPTY_DIGEST, EMPTY_DIGEST),)),
        ):
            with self.subTest(observed=observed):
                self.assertIs(_snapshot(FixedSql(observed), HOST_ID).state, State.UNAVAILABLE)

    def test_positive_reply_requires_exact_nonce_epoch_and_commands(self) -> None:
        response: dict[str, object] = {
            "ok": True,
            "body": {"version": 4, "session_id": str(SESSION_ID), "epoch": 3, "commands": []},
        }
        result = RequestResult(True, True, response)
        self.assertEqual(_opened(result, SESSION_ID), 3)
        self.assertTrue(_exchange_accepted(result, SESSION_ID, 3))
        self.assertFalse(_exchange_accepted(result, SESSION_ID, 4))
        self.assertIsNone(_opened(RequestResult(True, False, response), SESSION_ID))

    def test_stale_verdict_needs_committed_snapshot_and_settled_refusal(self) -> None:
        baseline = HostSnapshot(SESSION_ID, 3, 0, None, 2, EMPTY_DIGEST, EMPTY_DIGEST, EMPTY_DIGEST)
        denied = RequestResult(True, True, {"ok": False, "error": "stale_connection"})
        accepted = RequestResult(True, True, {"ok": True, "body": {}})
        self.assertTrue(_stale_verdict(baseline, Observation.observed(baseline), denied))
        self.assertFalse(_stale_verdict(baseline, Observation.observed(baseline), accepted))
        self.assertIsNone(
            _stale_verdict(baseline, Observation.observed(baseline), RequestResult(True, False))
        )
        self.assertIsNone(_stale_verdict(baseline, Observation.unavailable(), denied))
        changed = HostSnapshot(SESSION_ID, 3, 1, None, 2, EMPTY_DIGEST, EMPTY_DIGEST, EMPTY_DIGEST)
        self.assertFalse(
            _stale_verdict(baseline, Observation.observed(changed), RequestResult(True, False))
        )


if __name__ == "__main__":
    unittest.main()
