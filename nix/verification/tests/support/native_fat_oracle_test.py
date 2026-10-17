"""Check actual FAT boot-file preservation and the bounded firmware exception."""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

import native_fat_oracle as fat

SECTOR_BYTES = 512
OFFSET = 4 * SECTOR_BYTES
LENGTH = 16 * 1024**2


def command(arguments: list[str]) -> None:
    subprocess.run(arguments, capture_output=True, check=True, timeout=15)


class FatBoundaryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory[str]()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.disk = self.directory / "disk.raw"
        with self.disk.open("wb") as target:
            target.truncate(OFFSET + LENGTH + SECTOR_BYTES)
        self.image = f"{self.disk}@@{OFFSET}"
        command(["mformat", "-i", self.image, "-T", str(LENGTH // SECTOR_BYTES), "::"])
        command(["mmd", "-i", self.image, "::/EFI", "::/EFI/BOOT", "::/overalls"])
        self.write("EFI/BOOT/bootx64.efi", b"pinned-native-loader\x00\xff\n")
        self.write("overalls/install-status", b"installed-native-payload\n")

    def write(self, name: str, content: bytes) -> None:
        source = self.directory / "source"
        source.write_bytes(content)
        command(["mcopy", "-o", "-i", self.image, str(source), "::/" + name])

    def inventory(self) -> fat.Inventory:
        return fat.inventory(self.disk, OFFSET, LENGTH)

    def test_actual_fat_nvvars_creation_and_replacement_preserve_boot_inventory(self) -> None:
        before = self.inventory()
        self.assertEqual(before.directories, ("EFI", "EFI/BOOT", "overalls"))
        self.assertEqual(
            [value.path for value in before.files],
            ["EFI/BOOT/bootx64.efi", "overalls/install-status"],
        )
        for content in (
            b"firmware-variable-store",
            b"replaced" * 128,
            b"x" * fat.MAX_NV_VARS_BYTES,
        ):
            self.write("NvVars", content)
            self.assertEqual(self.inventory(), before)

    def test_changed_missing_or_added_boot_entry_changes_inventory(self) -> None:
        before = self.inventory()
        self.write("EFI/BOOT/bootx64.efi", b"different-loader\n")
        self.assertNotEqual(self.inventory(), before)
        self.write("EFI/BOOT/bootx64.efi", b"pinned-native-loader\x00\xff\n")
        self.assertEqual(self.inventory(), before)
        command(["mdel", "-i", self.image, "::/overalls/install-status"])
        self.assertNotEqual(self.inventory(), before)
        self.write("overalls/install-status", b"installed-native-payload\n")
        self.write("unexpected", b"unreviewed-entry")
        self.assertNotEqual(self.inventory(), before)

    def test_only_exact_root_regular_bounded_nvvars_is_exempt(self) -> None:
        before = self.inventory()
        self.write("EFI/NvVars", b"nested-variable-name-is-a-boot-file")
        self.assertNotEqual(self.inventory(), before)
        command(["mdel", "-i", self.image, "::/EFI/NvVars"])
        command(["mmd", "-i", self.image, "::/NvVars"])
        with self.assertRaises(ValueError):
            self.inventory()
        command(["mrd", "-i", self.image, "::/NvVars"])
        self.write("NvVars", b"x" * (fat.MAX_NV_VARS_BYTES + 1))
        with self.assertRaises(RuntimeError):
            self.inventory()

    def test_added_directory_changes_inventory(self) -> None:
        before = self.inventory()
        command(["mmd", "-i", self.image, "::/unexpected"])
        self.assertNotEqual(self.inventory(), before)

    def test_partition_bounds_and_malformed_filesystem_refuse(self) -> None:
        for offset, length in ((-1, LENGTH), (OFFSET, LENGTH - 1), (OFFSET, LENGTH + 1024)):
            with self.subTest(offset=offset, length=length), self.assertRaises(ValueError):
                fat.inventory(self.disk, offset, length)
        for header_offset, data in ((11, b"\x00\x10"), (19, b"\x01\x00"), (510, b"\x00\x00")):
            with self.disk.open("r+b") as target:
                target.seek(OFFSET + header_offset)
                original = target.read(len(data))
                target.seek(OFFSET + header_offset)
                target.write(data)
            with self.subTest(header_offset=header_offset), self.assertRaises(ValueError):
                self.inventory()
            with self.disk.open("r+b") as target:
                target.seek(OFFSET + header_offset)
                target.write(original)


if __name__ == "__main__":
    unittest.main()
