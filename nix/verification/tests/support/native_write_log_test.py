"""Check the dm-log-writes replay boundary with synthetic journals only."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import native_write_log as log

SECTOR = 512


def entry(sector: int, sectors: int, flags: int, data: bytes = b"", mark: bytes = b"") -> bytes:
    body = log.ENTRY.pack(sector, sectors, flags, len(mark)) + mark
    return body.ljust(SECTOR, b"\0") + data


def journal(*parts: bytes, count: int | None = None) -> bytes:
    total = len(parts) if count is None else count
    return log.SUPER.pack(log.MAGIC, log.VERSION, total, SECTOR).ljust(SECTOR, b"\0") + b"".join(
        parts
    )


class WriteLogTest(unittest.TestCase):
    def run_replay(self, body: bytes, cut: bytes = b"power-cut") -> tuple[log.Replay, bytes]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "log").write_bytes(body)
            (root / "target").write_bytes(b"\xaa" * (8 * SECTOR))
            result = log.replay(root / "log", root / "target", cut)
            return result, (root / "target").read_bytes()

    def test_applies_prefix_before_cut_only(self) -> None:
        result, target = self.run_replay(
            journal(
                entry(1, 1, 0, b"A" * SECTOR),
                entry(0, 0, log.FLUSH),
                entry(2, 2, log.FUA, b"B" * (2 * SECTOR)),
                entry(7, 1, log.DISCARD),
                entry(0, 0, log.MARK, mark=b"power-cut"),
                entry(4, 1, 0, b"C" * SECTOR),
                entry(0, 0, log.FLUSH),
            )
        )
        self.assertEqual(target[SECTOR : 2 * SECTOR], b"A" * SECTOR)
        self.assertEqual(target[2 * SECTOR : 4 * SECTOR], b"B" * (2 * SECTOR))
        self.assertEqual(target[4 * SECTOR : 5 * SECTOR], b"\xaa" * SECTOR)
        self.assertEqual(target[7 * SECTOR :], bytes(SECTOR))
        self.assertEqual(
            result,
            log.Replay(SECTOR, 4, 2, 1, 1, 1, 3 * SECTOR, 2),
        )

    def test_other_marks_do_not_cut(self) -> None:
        result, target = self.run_replay(
            journal(
                entry(0, 0, log.MARK, mark=b"other"),
                entry(0, 1, 0, b"D" * SECTOR),
                entry(0, 0, log.MARK, mark=b"power-cut"),
            )
        )
        self.assertEqual(target[:SECTOR], b"D" * SECTOR)
        self.assertEqual(result.entries_before_cut, 2)
        self.assertEqual(result.segments, (log.Segment("other", 0, 1),))

    def test_segments_count_flushes_between_marks(self) -> None:
        result, _ = self.run_replay(
            journal(
                entry(0, 0, log.MARK, mark=b"start"),
                entry(0, 1, 0, b"H" * SECTOR),
                entry(0, 0, log.MARK, mark=b"acknowledged"),
                entry(1, 1, 0, b"I" * SECTOR),
                entry(0, 0, log.FLUSH),
                entry(0, 0, log.MARK, mark=b"power-cut"),
            )
        )
        self.assertEqual(
            result.segments, (log.Segment("start", 0, 1), log.Segment("acknowledged", 1, 1))
        )

    def test_refuses_malformed_journals(self) -> None:
        cases = {
            "missing-cut": journal(entry(0, 1, 0, b"E" * SECTOR)),
            "unknown-flag": journal(entry(0, 0, 1 << 9), entry(0, 0, log.MARK, mark=b"power-cut")),
            "beyond-target": journal(
                entry(8, 1, 0, b"F" * SECTOR), entry(0, 0, log.MARK, mark=b"power-cut")
            ),
            "truncated-data": journal(entry(0, 4, 0, b"G" * SECTOR)),
            "count-past-log": journal(entry(0, 0, log.MARK, mark=b"power-cut"), count=9),
            "bad-magic": b"\0" * (2 * SECTOR),
        }
        for name, body in cases.items():
            with self.subTest(name), self.assertRaises(log.LogError):
                self.run_replay(body)
        with self.assertRaises(log.LogError):
            self.run_replay(journal(), cut=b"")


if __name__ == "__main__":
    unittest.main()
