"""Editor callback parsing and committed-cardinality classification."""

from unittest import TestCase
from unittest.mock import MagicMock

from core.outcome import Observation, State
from satellite.editor import (
    Redemption,
    authorize_ticket,
    callback_tokens,
    classify,
    redemption,
)

TICKET = "audi_editor_login_" + "A" * 43
CODE = "audi_editor_code_" + "b" * 43
HOST = "e-label.editor.fixture.test"


class EditorTests(TestCase):
    def test_callback_requires_exact_host_path_and_tokens(self) -> None:
        location = f"https://{HOST}/_editor/callback?ticket={TICKET}&code={CODE}"
        self.assertEqual(callback_tokens(location, HOST), (443, TICKET, CODE))
        self.assertIsNone(callback_tokens(location, "e-other.editor.fixture.test"))
        self.assertIsNone(callback_tokens(location.replace("_editor", "_audi"), HOST))
        self.assertIsNone(callback_tokens(location + "&extra=1", HOST))
        self.assertIsNone(callback_tokens(location.replace(CODE, "short"), HOST))

    def test_authorize_ticket_uses_configured_browser_origin(self) -> None:
        origin = "https://marshall-a"
        self.assertEqual(authorize_ticket(f"{origin}/editor/authorize/{TICKET}", origin), TICKET)
        self.assertIsNone(authorize_ticket(f"https://evil/editor/authorize/{TICKET}", origin))
        self.assertIsNone(authorize_ticket(None, origin))

    def test_classification_distinguishes_rollback_and_duplicates(self) -> None:
        self.assertTrue(classify(None, Redemption("consumed", 1)))
        self.assertTrue(classify(None, Redemption("approved", 0)))
        self.assertFalse(classify(None, Redemption("consumed", 2)))
        self.assertFalse(classify(None, Redemption("consumed", 0)))
        self.assertFalse(classify(None, Redemption("approved", 1)))
        self.assertFalse(classify(Redemption("approved", 0), Redemption("consumed", 1)))
        self.assertTrue(classify(Redemption("consumed", 1), Redemption("consumed", 1)))

    def test_unreadable_redemption_stays_unavailable(self) -> None:
        sql = MagicMock()
        sql.select.return_value = Observation.unavailable()
        self.assertIs(redemption(sql, TICKET).state, State.UNAVAILABLE)
        sql.select.return_value = Observation.observed((("consumed", 1),))
        self.assertEqual(redemption(sql, TICKET).value, Redemption("consumed", 1))
        sql.select.return_value = Observation.observed(())
        self.assertIs(redemption(sql, TICKET).state, State.UNAVAILABLE)
