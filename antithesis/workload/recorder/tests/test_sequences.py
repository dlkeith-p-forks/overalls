"""Each traces command draws producer sequences no other command has used."""

import tempfile
import unittest
from pathlib import Path

from recorder.client import Client, Config


class SequenceBlockTest(unittest.TestCase):
    def test_blocks_are_disjoint_and_persist_across_clients(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = Config(
                root / "requests", root / "results", root / "observation", root / "ledger.sqlite"
            )
            starts = [Client(config).reserve_sequences(400) for _ in range(3)]
        self.assertEqual(starts, [0, 400, 800])

    def test_rejects_unreviewed_span(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = Config(
                root / "requests", root / "results", root / "observation", root / "ledger.sqlite"
            )
            with self.assertRaises(ValueError):
                Client(config).reserve_sequences(0)


if __name__ == "__main__":
    unittest.main()
