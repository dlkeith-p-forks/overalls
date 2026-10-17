"""The selected Restic fixture volume is used only when it is private."""

import os
import tempfile
from pathlib import Path
from unittest import TestCase
from unittest.mock import patch

from backup.fixture import fixture_root


class FixtureRootTests(TestCase):
    def test_unset_root_uses_process_temporary_directory(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(fixture_root())

    def test_private_root_is_selected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "fixture"
            root.mkdir(mode=0o700)
            with patch.dict(os.environ, {"ANTITHESIS_BACKUP_ROOT": str(root)}, clear=True):
                self.assertEqual(fixture_root(), root)

    def test_shared_relative_or_linked_roots_refuse(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            shared = Path(directory) / "shared"
            shared.mkdir()
            shared.chmod(0o777)
            link = Path(directory) / "link"
            link.symlink_to(shared)
            for value in (str(shared), "relative/root", str(link)):
                with (
                    self.subTest(root=value),
                    patch.dict(os.environ, {"ANTITHESIS_BACKUP_ROOT": value}, clear=True),
                    self.assertRaises(RuntimeError),
                ):
                    fixture_root()
