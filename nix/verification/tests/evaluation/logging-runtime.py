"""Root-only runtime boundary checks, also run inside the NixOS logging machine."""

import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from typing import Protocol, cast
from unittest.mock import patch


def load(name: str, path: str) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError("logging helper unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class NativeCollector(Protocol):
    LOGS: Path

    def write_record(self, identity: str, record: dict[str, object], limit: int) -> object: ...

    def safe_open(self, path: str, flags: int) -> int: ...


runtime = load("logging_runtime", sys.argv.pop(1))
# The collector module is patched below through its LOGS attribute.
collector = cast(NativeCollector, load("native_collector", sys.argv.pop(1)))


class Boundaries(unittest.TestCase):
    def test_credentials_reject_links_and_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            secret = root / "secret"
            secret.write_text("fixture-secret")
            secret.chmod(0o600)
            self.assertEqual(runtime.private_read(str(secret)), "fixture-secret")
            secret.chmod(0o640)
            with self.assertRaises(ValueError):
                runtime.private_read(str(secret))
            secret.chmod(0o600)
            alias = root / "alias"
            alias.symlink_to(secret)
            with self.assertRaises(OSError):
                runtime.private_read(str(alias))
            alias.unlink()
            os.link(secret, alias)
            with self.assertRaises(ValueError):
                runtime.private_read(str(secret))
            alias.unlink()
            parent = root / "parent"
            parent.symlink_to(root, target_is_directory=True)
            with self.assertRaises(OSError):
                runtime.private_read(str(parent / "secret"))

    def test_no_ambient_aws_identity_and_private_runtime_config(self) -> None:
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.dict(os.environ, {"AWS_ACCESS_KEY_ID": "ambient"}),
        ):
            root = Path(directory)
            secret = root / "token"
            secret.write_text("fixture-token")
            secret.chmod(0o600)
            descriptor = {
                "aws": {"mode": "none"},
                "hostname": "test-host",
                "environment": "test",
                "configuration": {
                    "pipeline": {
                        "outputs": [
                            {"name": "http", "_credential_files": {"http_passwd": str(secret)}}
                        ]
                    }
                },
            }
            result = runtime.prepare(descriptor, root)
            self.assertNotIn("AWS_ACCESS_KEY_ID", os.environ)
            self.assertEqual(os.environ["OVERALLS_AWS_MODE"], "none")
            self.assertEqual(result.stat().st_mode & 0o777, 0o600)
            self.assertEqual(
                json.loads(result.read_text())["pipeline"]["outputs"][0]["http_passwd"],
                "fixture-token",
            )

    def test_native_logs_are_bounded_across_generations(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            collector.LOGS = Path(directory)
            identity = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            for generation in range(30):
                collector.write_record(f"{identity}-1-{generation}", {"message": "x" * 500}, 3000)
            files = list(collector.LOGS.glob("*.log*"))
            self.assertLessEqual(len(files), 8)
            self.assertLessEqual(sum(path.stat().st_size for path in files), 3000)
            fifo = collector.LOGS / "fifo"
            os.mkfifo(fifo, 0o600)
            fd = collector.safe_open(str(fifo), os.O_RDONLY | os.O_NONBLOCK)
            os.close(fd)
            alias = collector.LOGS / "alias"
            alias.symlink_to(fifo)
            with self.assertRaises(OSError):
                collector.safe_open(str(alias), os.O_RDONLY | os.O_NONBLOCK)


unittest.main()
