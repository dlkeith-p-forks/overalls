"""Check native durability parsers; host-only checks establish no VM durability."""

from __future__ import annotations

import hashlib
import json
import unittest

import native_durability as durability
import native_services as services


class TraceParserTest(unittest.TestCase):
    def test_tracks_lseek_write_and_positional_writes_for_disk_only(self) -> None:
        parser = durability.TraceParser(frozenset({19}))
        self.assertIsNone(parser.line(b"412 lseek(0x13, 0x200000000, 0) = 0x200000000"))
        write = parser.line(b"412 write(0x13, 0x7f00, 0x1000) = 0x1000")
        self.assertEqual(write, durability.Write(19, 0x200000000, 0x1000))
        self.assertEqual(
            parser.line(b"412 write(0x13, 0x7f00, 0x200 <unfinished ...>"),
            durability.Write(19, 0x200001000, 0x200),
        )
        self.assertEqual(
            parser.line(b"[pid 413] pwrite64(0x13, 0x7f00, 0x200, 0x400) = 0x200"),
            durability.Write(19, 0x400, 0x200),
        )
        self.assertIsNone(parser.line(b"412 write(0x1, 0x7f00, 0x1) = 0x1"))
        self.assertIsNone(parser.line(b"412 <... write resumed>) = 0x200"))
        self.assertIsNone(parser.line(b"412 lseek(0x13, 0x10, 0x2) = 0x10"))
        self.assertIsNone(parser.line(b"garbage(0x13"))

    def test_beyond_counts_writes_reaching_the_new_region(self) -> None:
        self.assertFalse(durability.beyond(durability.Write(3, 0, 512), 1024))
        self.assertTrue(durability.beyond(durability.Write(3, 768, 512), 1024))
        self.assertTrue(durability.beyond(durability.Write(3, 1024, None), 1024))
        self.assertFalse(durability.beyond(durability.Write(3, 1022, None), 1024))


class StateTest(unittest.TestCase):
    def prior(self) -> durability.Prior:
        return durability.Prior(
            services.Boot(
                services.Binding(durability.SOURCE_PLACEMENT, 7, "a" * 64),
                "22222222-2222-4222-8222-222222222222",
            ),
            "b" * 64,
        )

    def test_round_trip(self) -> None:
        prior = self.prior()
        self.assertEqual(durability.prior_value(prior.encode().encode()), prior)

    def test_refuses_extra_missing_or_invalid_fields(self) -> None:
        value = json.loads(self.prior().encode())
        for mutation in (
            {**value, "extra": 1},
            {key: item for key, item in value.items() if key != "boot_id"},
            {**value, "version": 2},
            {**value, "workspace_sha256": "x"},
            {**value, "execution_epoch": "7"},
        ):
            with (
                self.subTest(mutation=sorted(mutation)),
                self.assertRaises((durability.DurabilityError, ValueError)),
            ):
                durability.prior_value(json.dumps(mutation).encode())
        with self.assertRaises(durability.DurabilityError):
            durability.prior_value(b" " * 4097)

    def test_workspace_script_and_host_bytes_agree_in_shape(self) -> None:
        data = durability.workspace_bytes()
        self.assertEqual(len(data), durability.WORKSPACE_LINES * 27)
        self.assertTrue(data.startswith(b"native-relocation-00000000\n"))
        self.assertIn("native-relocation-%08d", durability.workspace_script())
        self.assertEqual(len(hashlib.sha256(data).hexdigest()), 64)


if __name__ == "__main__":
    unittest.main()
