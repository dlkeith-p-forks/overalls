"""Reject corrupted linkage inputs and unsafe alternate-root installation paths."""

import os
import stat
import tempfile
import unittest
from pathlib import Path

import native_candidate as candidate


class CandidateBoundaryTest(unittest.TestCase):
    """@cc [owner:ghuntley,label:verification] native-assembly-input-boundaries
    Tests MUST reject digest/size substitutions, symlink inputs and running-root
    or non-ZFS destinations. These tests MUST NOT establish native linkage,
    boot-archive correctness, target isolation or native admission.
    """

    def test_exact26_objects_and_nine_modules(self) -> None:
        names = [name for module in candidate.MODULES for name in module.objects]
        self.assertEqual(len(names), 26)
        self.assertEqual(len(set(names)), 26)
        self.assertEqual(len(candidate.MODULES), 9)
        self.assertEqual(len(candidate.SOCKFS), 14)
        self.assertNotIn("sockvsock", candidate.SOCKFS)

    def test_digest_size_and_regular_file_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "object"
            path.write_bytes(b"object bytes")
            record = candidate.object_value(
                candidate.json_value(candidate.file_record("object", b"object bytes"))
            )
            self.assertEqual(candidate.verified_file(path, record), b"object bytes")
            path.write_bytes(b"changed size")
            with self.assertRaises(ValueError):
                candidate.verified_file(path, record)
            path.write_bytes(b"object bytes")
            record["bytes"] = True
            with self.assertRaises(ValueError):
                candidate.verified_file(path, record)
            symlink = path.with_name("link")
            symlink.symlink_to(path)
            with self.assertRaises(OSError):
                candidate.read_file(symlink)
            with self.assertRaises(ValueError):
                candidate.read_file(path, 4)
            fifo = path.with_name("fifo")
            os.mkfifo(fifo)
            with self.assertRaises(ValueError):
                candidate.read_file(fifo)

    def test_alternate_root_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / "candidate"
            root.mkdir()
            running = "rpool/ROOT/original - / zfs - no\n"
            alternate = f"rpool/ROOT/candidate - {root} zfs - no\n"
            self.assertEqual(
                candidate.alternate_root(root, running + alternate), "rpool/ROOT/candidate"
            )
            with self.assertRaises(ValueError):
                candidate.alternate_root(Path("/"), running)
            with self.assertRaises(ValueError):
                candidate.alternate_root(root, running)
            with self.assertRaises(ValueError):
                candidate.alternate_root(
                    root, running + alternate.replace("candidate -", "original -")
                )
            with self.assertRaises(ValueError):
                candidate.alternate_root(root, running + alternate.replace(" zfs ", " ufs "))
            symlink = root.with_name("link")
            symlink.symlink_to(root)
            with self.assertRaises(ValueError):
                candidate.alternate_root(symlink, running + alternate)

    def test_destination_rejects_symbolic_link_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / "candidate"
            root.mkdir()
            (root / "kernel").symlink_to(root.parent)
            with self.assertRaises(ValueError):
                candidate.destination(root, "kernel/drv/amd64/viosock")
            with self.assertRaises(ValueError):
                candidate.destination(root, "../outside")

    def test_elf_header_is_not_an_arbitrary_payload(self) -> None:
        for data in (b"", b"x" * 64, b"\x7fELF\x01\x01\x01" + b"\0" * 57):
            with self.assertRaises(ValueError):
                candidate.check_elf(data)

    def test_target_ownership_and_modes(self) -> None:
        candidate.check_ownership(os.stat_result((stat.S_IFDIR | 0o755, 0, 0, 1, 0, 0, 0, 0, 0, 0)))
        for owner, mode in ((1, 0o755), (0, 0o775), (0, 0o777), (0, 0o1777)):
            metadata = os.stat_result((stat.S_IFDIR | mode, 0, 0, 1, owner, 0, 0, 0, 0, 0))
            with self.assertRaises(ValueError):
                candidate.check_ownership(metadata)

    def test_conflicting_family40_mappings(self) -> None:
        candidate.check_socket_mapping("# package header\n2 2 0 tcp\n40 2 0 sockvsock\n")
        for mapping in ("40 2 0 tcp", "40 2 -1 sockvsock", "040 02 00 other", "invalid row"):
            with self.assertRaises(ValueError):
                candidate.check_socket_mapping(mapping)


if __name__ == "__main__":
    unittest.main()
