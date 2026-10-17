"""Reject malformed or stale evidence at the native growth oracle boundary."""

from __future__ import annotations

import unittest

import native_growth_oracle as growth

DISK_BYTES = 12651734 * 512


def receipt() -> dict[str, object]:
    return {
        "version": 1,
        "os": "freebsd",
        "outcome": "unchanged",
        "disk_bytes": DISK_BYTES,
        "root_start": 2165940,
        "root_end_before": 12651700,
        "root_end_after": 12651700,
        "backup_before": 12651733,
        "backup_after": 12651733,
        "native_admission": False,
    }


def table() -> dict[str, object]:
    partitions: list[dict[str, object]] = []
    for index, (start, size) in enumerate(
        ((34, 122), (156, 66584), (66740, 2097152), (2163892, 2048), (2165940, 10485761))
    ):
        partitions.append(
            {
                "node": f"/disposable/root.raw{index + 1}",
                "start": start,
                "size": size,
                "type": growth.SWAP_TYPE if index == 2 else "516e7cb6-6ecf-11d6-8ff8-00022d09712b",
                "uuid": f"92519c{index:02x}-42bc-11f0-9e0b-002590ec5bf2",
                "name": f"fixture-{index}",
            }
        )
    return {
        "label": "gpt",
        "id": "9251b63a-42bc-11f0-9e0b-002590ec5bf2",
        "unit": "sectors",
        "sectorsize": 512,
        "firstlba": 34,
        "lastlba": 12651700,
        "partitions": partitions,
    }


class GrowthBoundaryTest(unittest.TestCase):
    def test_valid_layout_preserves_native_identities(self) -> None:
        layout = growth.layout_value({"partitiontable": table()}, DISK_BYTES)
        self.assertEqual(layout.root.start, 2165940)
        self.assertEqual(layout.root.sectors, 10485761)
        self.assertEqual(layout.partitions[2].kind, growth.SWAP_TYPE)

    def test_layout_refuses_stale_backup_geometry_and_boolean_sector_size(self) -> None:
        for key, value in (
            ("lastlba", 12651699),
            ("firstlba", True),
            ("sectorsize", 4096),
            ("sectorsize", True),
            ("sectorsize", 512.0),
        ):
            raw = table()
            raw[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                growth.layout_value({"partitiontable": raw}, DISK_BYTES)

    def test_layout_refuses_overlap_wrong_uuid_and_wrong_root(self) -> None:
        for key, value in (("start", 2163892), ("uuid", "foreign"), ("start", True)):
            raw = table()
            partitions = raw["partitions"]
            self.assertIsInstance(partitions, list)
            if not isinstance(partitions, list):
                self.fail("invalid typed test fixture")
            normalized = [growth.object_value(partition) for partition in partitions]
            normalized[4][key] = value
            raw["partitions"] = normalized
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                growth.layout_value({"partitiontable": raw}, DISK_BYTES)

    def test_receipt_requires_closed_authority_and_geometry(self) -> None:
        current = growth.guest_value(receipt(), 5 * 1024**3)
        self.assertEqual(current.root_end, 12651700)
        for key, value in (
            ("version", True),
            ("native_admission", True),
            ("os", "illumos"),
            ("backup_after", 12651732),
            ("outcome", "grown"),
            ("root_end_after", True),
            ("extra", "unreviewed"),
        ):
            raw = receipt()
            raw[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                growth.guest_value(raw, 5 * 1024**3)

    def test_expanded_receipt_requires_both_disk_and_partition_to_advance(self) -> None:
        raw = receipt()
        raw["outcome"] = "grown"
        raw["disk_bytes"] = DISK_BYTES + growth.EXPANSION
        raw["backup_after"] = (DISK_BYTES + growth.EXPANSION) // 512 - 1
        with self.assertRaises(ValueError):
            growth.guest_value(raw, 6 * 1024**3)
        raw["root_end_after"] = (DISK_BYTES + growth.EXPANSION) // 512 - 34
        current = growth.guest_value(raw, 6 * 1024**3)
        self.assertEqual(current.disk_bytes, DISK_BYTES + growth.EXPANSION)

    def test_observed_native_gpart_alignment_is_accepted_without_arbitrary_tail_slack(self) -> None:
        # Real pinned FreeBSD disk after a host +2 GiB expansion and native
        # gpart recover/resize: backup=16846036, usable/root end=16845999.
        disk_bytes = 8_625_170_944
        raw = table()
        partitions = raw["partitions"]
        if not isinstance(partitions, list):
            self.fail("invalid typed test fixture")
        normalized = [growth.object_value(partition) for partition in partitions]
        normalized[4]["size"] = 16845999 - 2165940 + 1
        raw["partitions"] = normalized
        raw["lastlba"] = 16845999
        layout = growth.layout_value({"partitiontable": raw}, disk_bytes)
        self.assertEqual(layout.last, 16845999)
        evidence = receipt() | {
            "disk_bytes": disk_bytes,
            "outcome": "grown",
            "root_end_before": 12651699,
            "root_end_after": 16845999,
            "backup_before": 12651732,
            "backup_after": 16846036,
        }
        self.assertEqual(growth.guest_value(evidence, 6 * 1024**3).root_end, 16845999)
        for wrong in (16845998, 16846000, 16846002, 16846004):
            with self.subTest(last=wrong), self.assertRaises(ValueError):
                growth.guest_value(evidence | {"root_end_after": wrong}, 6 * 1024**3)


if __name__ == "__main__":
    unittest.main()
