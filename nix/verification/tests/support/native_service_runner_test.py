"""Refuse unsafe optional API lifetimes without granting native runtime evidence."""

from __future__ import annotations

import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import native_service_runner as runner


class NativeServiceApiTest(unittest.TestCase):
    def test_api_mode_is_explicit_and_unix_only(self) -> None:
        vmm, metadata, config = (Path(name) for name in ("vmm", "metadata", "config"))
        self.assertEqual(
            runner.firecracker_arguments(vmm, metadata, config, None),
            [
                "vmm",
                "--enable-pci",
                "--no-api",
                "--metadata",
                "metadata",
                "--config-file",
                "config",
            ],
        )
        self.assertEqual(
            runner.firecracker_arguments(vmm, metadata, config, Path("work/api.sock")),
            [
                "vmm",
                "--enable-pci",
                "--api-sock",
                "work/api.sock",
                "--metadata",
                "metadata",
                "--config-file",
                "config",
            ],
        )

    def test_cleanup_refuses_regular_files_links_and_directories(self) -> None:
        for kind in ("file", "link", "directory"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "api.sock"
                if kind == "file":
                    path.write_bytes(b"must-survive")
                elif kind == "link":
                    path.symlink_to("missing-target")
                else:
                    path.mkdir()
                with self.assertRaisesRegex(ValueError, "owned Unix socket"):
                    runner.prepare_api_socket(path, None)
                self.assertTrue(path.exists() or path.is_symlink())

    def test_only_stopped_vm_socket_can_be_removed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, socket.socket(socket.AF_UNIX) as stream:
            path = Path(temporary) / "api.sock"
            stream.bind(str(path))
            with subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ) as process:
                try:
                    with self.assertRaisesRegex(RuntimeError, "live native VM"):
                        runner.prepare_api_socket(path, process)
                    self.assertTrue(path.exists())
                    runner.prepare_api_socket(None, process)
                    self.assertTrue(path.exists())
                finally:
                    process.terminate()
                    process.wait(timeout=10)
                runner.prepare_api_socket(path, process)
                self.assertFalse(path.exists())
            runner.prepare_api_socket(path, None)


if __name__ == "__main__":
    unittest.main()
