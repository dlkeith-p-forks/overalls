"""Runtime public host parsing and fail-closed launcher input."""

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

source = sys.argv.pop(1)
spec = importlib.util.spec_from_file_location("public_host", source)
if spec is None or spec.loader is None:
    raise RuntimeError("public host helper unavailable")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PublicHostTest(unittest.TestCase):
    def test_one_canonical_name(self) -> None:
        for data in [
            b"control.vm-01234567890123456789012345678901.inception.example.test",
            b"control.example.test\n",
            b"localhost",
        ]:
            self.assertEqual(module.hostname(data), data.rstrip(b"\n").decode())

    def test_invalid_values_and_extra_bytes_are_rejected(self) -> None:
        for data in [
            b"",
            b"\n",
            b"::1",
            b"[::1]",
            b"a..b",
            b"a.\n",
            b"UPPER.example",
            b"a\nb",
            b"a\n\n",
            b"a\x00",
            b"$(id)",
            b"a;id",
            b"a b",
            b"a\r\n",
            b"-bad.example",
            b"a" * 64,
            b"\xff",
            (b"a." * 127) + b"a",
        ]:
            with self.subTest(data=data), self.assertRaises(ValueError):
                module.hostname(data)

    def test_cli_does_not_echo_bad_input_or_accept_oversized_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "host"
            for data in [b"private-invalid;value", b"a" * 100000]:
                path.write_bytes(data)
                result: subprocess.CompletedProcess[bytes] = subprocess.run(
                    [sys.executable, source, str(path)], capture_output=True
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(
                    result.stderr, b"Marshall public hostname unavailable or invalid\n"
                )
            path.write_bytes(b"control.example.test\n")
            self.assertEqual(
                subprocess.check_output([sys.executable, source, str(path)]),
                b"control.example.test\n",
            )


unittest.main()
