"""Runtime default image identity parsing and fail-closed launcher input."""

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

source = sys.argv.pop(1)
spec = importlib.util.spec_from_file_location("default_image", source)
if spec is None or spec.loader is None:
    raise RuntimeError("default image helper unavailable")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DefaultImageTest(unittest.TestCase):
    def test_canonical_identity_or_empty(self) -> None:
        self.assertEqual(module.image_id(b""), "")
        self.assertEqual(module.image_id(b"\n"), "")
        identity = b"sha256:" + b"a1b2c3d4" * 8
        self.assertEqual(module.image_id(identity), identity.decode())
        self.assertEqual(module.image_id(identity + b"\n"), identity.decode())

    def test_invalid_values_are_rejected(self) -> None:
        for data in [
            b"sha256:XYZ",
            b"sha256:" + b"a" * 63,
            b"sha256:" + b"a" * 65,
            b"SHA256:" + b"a" * 64,
            b"sha256:" + b"g" * 64,
            b" name",
            b"sha256:" + b"a" * 63 + b"\nA",
            b"a\nb",
            b"a\x00",
            b"$(id)",
            b"sha256:" + b"a" * 64 + b"\n\n",
            b"\xff",
        ]:
            with self.subTest(data=data), self.assertRaises(ValueError):
                module.image_id(data)

    def test_cli_does_not_echo_bad_input_or_accept_oversized_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image"
            for data in [b"private-invalid;value", b"a" * 100000]:
                path.write_bytes(data)
                result: subprocess.CompletedProcess[bytes] = subprocess.run(
                    [sys.executable, source, str(path)], capture_output=True
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, b"Marshall default image unavailable or invalid\n")
            identity = "sha256:" + "b2c3d4e5" * 8 + "\n"
            path.write_bytes(identity.encode())
            self.assertEqual(
                subprocess.check_output([sys.executable, source, str(path)]), identity.encode()
            )


unittest.main()
