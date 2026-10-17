"""A malformed or changing spool cannot be mistaken for no pending effects."""

import json
import tempfile
from pathlib import Path
from unittest import TestCase
from uuid import UUID

from core.outcome import State
from satellite.spool import SLOT_BYTES, read_slots

REQUEST = UUID("33333333-3333-4333-8333-333333333333")


class SpoolObservationTests(TestCase):
    def test_complete_fixed_slot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            event = {
                "admission": {
                    "request_id": str(REQUEST),
                    "vm_id": "11111111-1111-4111-8111-111111111111",
                    "owner_id": "22222222-2222-4222-8222-222222222222",
                    "provider": "openai",
                    "model": "fixture-model",
                },
                "completion": {"completeness": "unknown"},
            }
            content = json.dumps(event).encode()
            encoded = len(content).to_bytes(4, "big") + content
            (directory / f"{REQUEST}.json").write_bytes(encoded.ljust(SLOT_BYTES, b"\0"))
            observed = read_slots(directory, 1)
            self.assertIs(observed.state, State.OBSERVED)
            slots = observed.value
            self.assertIsNotNone(slots)
            if slots is None:
                return
            self.assertEqual(len(slots), 1)
            self.assertTrue(slots[0].completed)

    def test_truncated_slot_is_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / f"{REQUEST}.json").write_bytes(b"{}")
            self.assertIs(read_slots(directory, 1).state, State.UNAVAILABLE)

    def test_missing_directory_is_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            self.assertIs(read_slots(Path(temporary) / "missing", 1).state, State.UNAVAILABLE)
