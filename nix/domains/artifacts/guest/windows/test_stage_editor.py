"""Unit checks for deterministic Windows editor media staging."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import tarfile
import tempfile
import unittest
from pathlib import Path
from types import ModuleType

MODULE_PATH = Path(__file__).with_name("stage-editor.py")


def load_module() -> ModuleType:
    """Load the staging script as a typed test module."""
    spec = importlib.util.spec_from_file_location("stage_editor", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load stage editor")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StageEditorTest(unittest.TestCase):
    """Exercise archive closure and refusal boundaries."""

    def test_archive_is_deterministic_and_regular_file_only(self) -> None:
        """Repeated staging has identical bytes and a closed inventory."""
        module = load_module()
        with tempfile.TemporaryDirectory(prefix="stage-editor-test-") as temporary:
            root = Path(temporary) / "source"
            first = Path(temporary) / "first"
            second = Path(temporary) / "second"
            (root / "out" / "deep").mkdir(parents=True)
            (root / "out" / "deep" / "server.js").write_bytes(b"editor\n")
            (root / "LICENSE").write_bytes(b"license\n")
            module.main(["stage-editor.py", str(root), str(first)])
            module.main(["stage-editor.py", str(root), str(second)])
            self.assertEqual(
                (first / "editor.tar").read_bytes(), (second / "editor.tar").read_bytes()
            )
            inventory = json.loads((first / "editor.inventory.json").read_text())
            metadata = json.loads((first / "editor.archive.json").read_text())
            self.assertEqual(metadata["file_count"], len(inventory["files"]))
            self.assertEqual(metadata["archive_size"], (first / "editor.tar").stat().st_size)
            self.assertEqual(
                metadata["archive_sha256"],
                hashlib.sha256((first / "editor.tar").read_bytes()).hexdigest(),
            )
            with tarfile.open(first / "editor.tar") as archive:
                self.assertEqual(archive.getnames(), ["LICENSE", "out/deep/server.js"])
                self.assertTrue(all(member.isfile() for member in archive.getmembers()))

    def test_symlink_and_windows_reserved_names_are_refused(self) -> None:
        """Symlinks and names unsafe on Windows cannot enter the archive."""
        module = load_module()
        with tempfile.TemporaryDirectory(prefix="stage-editor-test-") as temporary:
            root = Path(temporary) / "source"
            destination = Path(temporary) / "output"
            root.mkdir()
            (root / "safe.txt").write_text("safe")
            (root / "link").symlink_to(root / "safe.txt")
            with self.assertRaises(ValueError):
                module.main(["stage-editor.py", str(root), str(destination)])
            (root / "link").unlink()
            (root / "CON.txt").write_text("reserved")
            with self.assertRaises(ValueError):
                module.main(["stage-editor.py", str(root), str(destination)])


if __name__ == "__main__":
    unittest.main()
