"""An acknowledged batch is compared only after the published copy catches up."""

import unittest
from unittest.mock import MagicMock, patch

from recorder.oracle import Batch
from recorder.scenarios import SETTLE_ATTEMPTS, _settled

OLD = Batch("a" * 64, "a" * 64, 1, 2, True)
NEW = Batch("b" * 64, "b" * 64, 3, 4, True)


class SettleTest(unittest.TestCase):
    def test_waits_for_the_lagging_published_copy(self) -> None:
        prior = {OLD.digest: OLD}
        published = [prior, {OLD.digest: OLD, NEW.digest: NEW}]
        with (
            patch("recorder.scenarios._archive", side_effect=published),
            patch("recorder.scenarios.time.sleep"),
        ):
            current = _settled(MagicMock(), prior, prior)
        self.assertEqual(set(current or {}), {OLD.digest, NEW.digest})

    def test_missing_batch_is_returned_after_the_bound(self) -> None:
        prior = {OLD.digest: OLD}
        with (
            patch("recorder.scenarios._archive", return_value=prior) as archive,
            patch("recorder.scenarios.time.sleep"),
        ):
            current = _settled(MagicMock(), prior, prior)
        self.assertEqual(current, prior)
        self.assertEqual(archive.call_count, SETTLE_ATTEMPTS)


if __name__ == "__main__":
    unittest.main()
