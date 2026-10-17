"""Check native loader search paths without pretending to execute guest ELF."""

import tempfile
import unittest
from pathlib import Path

from .verify_runtime import Dynamic, dependency


class RuntimeSearchTest(unittest.TestCase):
    temporary: tempfile.TemporaryDirectory[str]
    root: Path

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def library(self, relative: str, width: int = 2) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        header = bytearray(20)
        header[:6] = b"\x7fELF" + bytes((width, 1))
        header[18:20] = (62 if width == 2 else 3).to_bytes(2, "little")
        path.write_bytes(header)
        return path

    def test_unrelated_same_named_library_is_not_a_runtime_dependency(self) -> None:
        path = self.root / "usr/bin/git"
        self.library("unused/libprobe.so.1")
        self.assertIsNone(
            dependency(self.root, path, 2, "libprobe.so.1", Dynamic((), None, ()), "illumos")
        )
        expected = self.library("lib/amd64/libprobe.so.1")
        self.assertEqual(
            dependency(self.root, path, 2, "libprobe.so.1", Dynamic((), None, ()), "illumos"),
            expected,
        )

    def test_origin_runpath_and_elf_width_control_resolution(self) -> None:
        path = self.root / "opt/runtime/bin/git"
        description = Dynamic((), None, ("$ORIGIN/../lib",))
        expected = self.library("opt/runtime/lib/libprobe.so.1", width=1)
        self.assertIsNone(dependency(self.root, path, 2, "libprobe.so.1", description, "illumos"))
        self.library("opt/runtime/lib/libprobe.so.1", width=2)
        self.assertEqual(
            dependency(self.root, path, 2, "libprobe.so.1", description, "illumos"), expected
        )

    def test_relative_unknown_and_escaping_search_paths_refuse(self) -> None:
        path = self.root / "usr/bin/git"
        for runpath in ("relative", "$UNKNOWN/lib"):
            with self.subTest(runpath=runpath), self.assertRaisesRegex(ValueError, "runpath"):
                dependency(
                    self.root, path, 2, "libprobe.so.1", Dynamic((), None, (runpath,)), "illumos"
                )
        (self.root / "escape").symlink_to(self.root.parent)
        with self.assertRaisesRegex(ValueError, "escapes payload"):
            dependency(
                self.root, path, 2, "libprobe.so.1", Dynamic((), None, ("/escape",)), "illumos"
            )


if __name__ == "__main__":
    unittest.main()
