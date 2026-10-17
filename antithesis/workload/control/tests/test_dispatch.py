"""Effect-witness boundaries for the cross-service and legacy dispatch verdicts."""

import unittest
from collections.abc import Sequence
from pathlib import Path
from typing import LiteralString
from unittest.mock import MagicMock, patch
from uuid import UUID

from control import dispatch
from control.client import ControlSession, ControlTransport, RequestResult
from control.credential import LillyCredential
from control.dispatch import DispatchFixture, _negative
from control.oracle import ControlOracle, ForeignEffects, HostSession
from core.config import Config
from core.outcome import Observation
from core.sql import SqlOracle

HOST_ID = UUID("cd9e681d-46d3-4213-9361-daa77f95f32d")
OLD_SESSION = HostSession(UUID("4fdce074-689a-4c8a-9c9c-d709162f3e56"), 3)
OTHER_SESSION = HostSession(UUID("6f0c1f3e-1d0f-4b7e-9a51-0d7f6b1c2a3e"), 4)
EFFECTS = ForeignEffects(0, 0, 0, 0)
PRIMARY = "Control rejects cross-service and invalid documents before domain effects"
LEGACY = "Execution v4 refuses legacy authority without changing durable command"


class UnusedSql(SqlOracle):
    def __init__(self) -> None:
        pass

    def select(
        self,
        statement: LiteralString,
        parameters: Sequence[object] = (),
        *,
        maximum_rows: int = 4096,
    ) -> Observation[tuple[tuple[object, ...], ...]]:
        raise AssertionError("scripted oracle must not query SQL")


class ScriptedOracle(ControlOracle):
    """Returns scripted observations in call order for each witness."""

    def __init__(
        self,
        rows: list[Observation[bool]],
        effects: list[Observation[ForeignEffects]],
        commands: list[Observation[HostSession | None]],
    ) -> None:
        super().__init__(UnusedSql())
        self.rows = rows
        self.effects = effects
        self.commands = commands

    def session_exists(self, host_id: UUID, session_id: UUID) -> Observation[bool]:
        return self.rows.pop(0)

    def foreign_effects(self) -> Observation[ForeignEffects]:
        return self.effects.pop(0)

    def current_host_session(self, host_id: UUID) -> Observation[HostSession | None]:
        return self.commands.pop(0)


class UnusedTransport(ControlTransport):
    def send(self, message: str | bytes) -> None:
        raise AssertionError("scripted session sends nothing")

    def recv(self, timeout: float | None = None) -> str | bytes:
        raise AssertionError("scripted session receives nothing")

    def close(self) -> None:
        pass


class ScriptedSession(ControlSession):
    def __init__(self, results: list[RequestResult]) -> None:
        super().__init__(UnusedTransport())
        self.results = results
        self.sent: list[tuple[str, dict[str, object]]] = []

    def exchange(self, identifier: int, op: str, body: dict[str, object]) -> RequestResult:
        self.sent.append((op, body))
        return self.results.pop(0)


def _fixture(oracle: ControlOracle) -> DispatchFixture:
    config = Config(
        marshall_urls=("https://marshall-a:5443",),
        ca_file=Path("/nonexistent/ca.pem"),
        fixture_manifest=Path("/nonexistent/fixture.json"),
        db_host="pg",
        db_port=5432,
        db_user="overalls_oracle",
        db_name="overalls",
        db_password_file=Path("/nonexistent/password"),
        timeout_seconds=5,
    )
    credential = LillyCredential(HOST_ID, HOST_ID, "synthetic")
    return DispatchFixture(config, HOST_ID, "sha256:" + "a" * 64, credential, oracle)


def _reply(ok: bool, error: str | None = None) -> RequestResult:
    response: dict[str, object] = {"ok": ok}
    if error is not None:
        response["error"] = error
    return RequestResult(attempted=True, acknowledged=True, response=response)


LOST = RequestResult(attempted=True, acknowledged=False)


class ForeignDispatchTests(unittest.TestCase):
    def _negative(
        self, variant: str, reply: RequestResult, after_effects: ForeignEffects
    ) -> tuple[MagicMock, MagicMock, ScriptedSession]:
        oracle = ScriptedOracle(
            [Observation.observed(False), Observation.observed(False)],
            [Observation.observed(EFFECTS), Observation.observed(after_effects)],
            [],
        )
        session = ScriptedSession([reply])
        with (
            patch("control.dispatch.always") as always,
            patch("control.dispatch.reachable") as reachable,
        ):
            _negative(_fixture(oracle), session, variant, 1)
        return always, reachable, session

    def test_foreign_documents_use_their_own_service_route(self) -> None:
        for variant, op in (
            ("foreign_audi", "audi.ssh_open"),
            ("foreign_porsche", "porsche.commands"),
            ("foreign_ziggy", "ziggy.agent_next"),
            ("foreign_galileo", "galileo.authorize"),
        ):
            with self.subTest(variant=variant):
                always, reachable, session = self._negative(
                    variant, _reply(False, "invalid_request"), EFFECTS
                )
                self.assertEqual(session.sent[0][0], op)
                self.assertNotIn("session_id", session.sent[0][1])
                always.assert_called_once_with(True, PRIMARY)
                reachable.assert_called_once()

    def test_changed_foreign_effect_fails_even_after_refusal_or_loss(self) -> None:
        changed = ForeignEffects(1, 0, 0, 0)
        for reply in (_reply(False, "invalid_request"), LOST):
            with self.subTest(reply=reply):
                always, reachable, _ = self._negative("foreign_porsche", reply, changed)
                always.assert_called_once_with(False, PRIMARY)
                reachable.assert_not_called()

    def test_lost_reply_without_effect_stays_unknown(self) -> None:
        always, reachable, _ = self._negative("foreign_galileo", LOST, EFFECTS)
        always.assert_not_called()
        reachable.assert_not_called()

    def test_unavailable_effect_snapshot_is_not_unchanged(self) -> None:
        oracle = ScriptedOracle(
            [Observation.observed(False), Observation.observed(False)],
            [Observation.observed(EFFECTS), Observation.unavailable()],
            [],
        )
        session = ScriptedSession([_reply(False, "invalid_request")])
        with patch("control.dispatch.always") as always:
            _negative(_fixture(oracle), session, "foreign_audi", 1)
        always.assert_not_called()


class LegacyDispatchTests(unittest.TestCase):
    def _run(
        self,
        commands_after: tuple[HostSession | None, HostSession | None],
        replies: tuple[RequestResult, RequestResult],
    ) -> MagicMock:
        oracle = ScriptedOracle(
            [Observation.observed(value) for value in (False, True, False, False, False, False)],
            [],
            [
                Observation.observed(OLD_SESSION),
                Observation.observed(commands_after[0]),
                Observation.observed(OLD_SESSION),
                Observation.observed(commands_after[1]),
            ],
        )
        session = ScriptedSession([_reply(True), *replies])
        with (
            patch("control.dispatch._fixture", return_value=_fixture(oracle)),
            patch("control.dispatch._open", return_value=session),
            patch("control.dispatch.choice", return_value=3),
            patch("control.dispatch.always_or_unreachable") as always,
            patch("control.dispatch.reachable"),
        ):
            self.assertEqual(dispatch.run_legacy_request(), 0)
        return always

    def test_refusal_with_unchanged_command_passes(self) -> None:
        refused = _reply(False, "unsupported_version")
        always = self._run((OLD_SESSION, OLD_SESSION), (refused, refused))
        self.assertEqual([call.args for call in always.call_args_list], [(True, LEGACY)] * 2)

    def test_erased_command_fails(self) -> None:
        refused = _reply(False, "unsupported_version")
        always = self._run((None, OLD_SESSION), (refused, refused))
        self.assertEqual(
            [call.args for call in always.call_args_list], [(False, LEGACY), (True, LEGACY)]
        )

    def test_concurrent_live_reconnect_is_unexercised(self) -> None:
        refused = _reply(False, "unsupported_version")
        always = self._run((OTHER_SESSION, OLD_SESSION), (refused, refused))
        self.assertEqual([call.args for call in always.call_args_list], [(True, LEGACY)])


if __name__ == "__main__":
    unittest.main()
