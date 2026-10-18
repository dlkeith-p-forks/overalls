"""Bounded host parsing checks; no native reset or transport acceptance."""

from __future__ import annotations

import json
import unittest

import native_reset as reset


class NativeResetSerialTest(unittest.TestCase):
    def test_every_fragment_stays_pending_until_its_newline(self) -> None:
        event: dict[str, object] = {
            "event": "native-reset-armed",
            "accept_pending": True,
            "read_pending": True,
            "write_pending": True,
        }
        encoded = json.dumps(event, separators=(",", ":")).encode()
        for length in range(len(encoded) + 1):
            with self.subTest(fragment_bytes=length):
                self.assertIsNone(reset.serial_event(encoded[:length], "native-reset-armed"))
        self.assertEqual(reset.serial_event(encoded + b"\n", "native-reset-armed"), event)

    def test_complete_records_support_crlf_and_ignore_unrelated_console_lines(self) -> None:
        event = {"event": "native-reset-listeners-ready", "build_id": "a" * 64}
        data = b"native console boot\r\n" + json.dumps(event, separators=(",", ":")).encode()
        self.assertEqual(reset.serial_event(data + b"\r\n", "native-reset-listeners-ready"), event)
        self.assertIsNone(reset.serial_event(data + b"\r\n", "native-reset-armed"))

    def test_complete_malformed_or_interleaved_reset_records_refuse(self) -> None:
        for line in (
            b'{"event":"native-reset-armed","accept_pending":}\n',
            b'{"event":"native-reset-armed","accept_pending":true' + b"host-vmm-log" + b"}\n",
        ):
            with (
                self.subTest(boundary="malformed-complete"),
                self.assertRaises(json.JSONDecodeError),
            ):
                reset.serial_event(line, "native-reset-armed")
            self.assertIsNone(reset.serial_event(line[:-1], "native-reset-armed"))

    def test_complete_duplicate_fields_and_failed_probe_refuse(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "duplicate native reset evidence field"):
            reset.serial_event(
                b'{"event":"native-reset-armed","event":"native-reset-verified"}\n',
                "native-reset-armed",
            )
        with self.assertRaisesRegex(RuntimeError, "native reset probe failed: listener"):
            reset.serial_event(
                b'{"event":"native-reset-failed","boundary":"listener"}\n',
                "native-reset-armed",
            )


if __name__ == "__main__":
    unittest.main()
