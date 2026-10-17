"""Exercise native archive boundaries independently of the pinned upstream data."""

import hashlib
import io
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from .extract_freebsd import extract, package_records


class PackageExtractionTest(unittest.TestCase):
    temporary: tempfile.TemporaryDirectory[str]
    directory: Path

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def archive(self, members: list[tuple[tarfile.TarInfo, bytes]]) -> tuple[Path, str]:
        plain = self.directory / "package.tar"
        with tarfile.open(plain, "w") as archive:
            for member, data in members:
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        compressed = self.directory / "package.pkg"
        subprocess.run(["zstd", "-q", "-f", str(plain), "-o", str(compressed)], check=True)
        return compressed, hashlib.sha256(compressed.read_bytes()).hexdigest()

    def root(self) -> Path:
        root = self.directory / "root"
        root.mkdir()
        return root

    def test_absolute_guest_paths_and_links_remain_inside_output(self) -> None:
        executable = tarfile.TarInfo("/usr/local/bin/git")
        executable.mode = 0o755
        link = tarfile.TarInfo("/usr/local/bin/git-alias")
        link.type, link.linkname = tarfile.SYMTYPE, "/usr/local/bin/git"
        hard = tarfile.TarInfo("/usr/local/bin/git-hard")
        hard.type, hard.linkname = tarfile.LNKTYPE, "/usr/local/bin/git"
        archive, digest = self.archive([(executable, b"native"), (link, b""), (hard, b"")])
        root = self.root()
        extract(root, archive, digest)
        self.assertEqual((root / "usr/local/bin/git-alias").read_bytes(), b"native")
        self.assertEqual(
            (root / "usr/local/bin/git-hard").stat().st_ino,
            (root / "usr/local/bin/git").stat().st_ino,
        )
        self.assertFalse((root / "usr/local/bin/git-alias").readlink().is_absolute())

    def test_digest_tampering_refuses_before_output(self) -> None:
        archive, _ = self.archive([(tarfile.TarInfo("/usr/local/bin/git"), b"native")])
        root = self.root()
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            extract(root, archive, "0" * 64)
        self.assertEqual(list(root.iterdir()), [])

    def test_escaping_paths_and_links_refuse(self) -> None:
        for name, target in (("../escape", ""), ("/usr/local/bin/git", "../../../../escape")):
            with self.subTest(name=name):
                member = tarfile.TarInfo(name)
                if target:
                    member.type, member.linkname = tarfile.SYMTYPE, target
                archive, digest = self.archive([(member, b"")])
                with self.assertRaisesRegex(ValueError, "unsafe package path"):
                    extract(self.directory, archive, digest)

    def test_special_entries_setid_and_conflicts_refuse(self) -> None:
        for kind, mode in ((tarfile.FIFOTYPE, 0o644), (tarfile.REGTYPE, 0o4755)):
            with self.subTest(kind=kind, mode=mode):
                member = tarfile.TarInfo("/usr/local/bin/git")
                member.type, member.mode = kind, mode
                archive, digest = self.archive([(member, b"")])
                with self.assertRaises(ValueError):
                    extract(self.directory, archive, digest)
        member = tarfile.TarInfo("/existing")
        archive, digest = self.archive([(member, b"changed")])
        (self.directory / "existing").write_bytes(b"original")
        with self.assertRaisesRegex(ValueError, "conflicting package file"):
            extract(self.directory, archive, digest)
        self.assertEqual((self.directory / "existing").read_bytes(), b"original")

    def test_package_scripts_are_data_and_never_execute(self) -> None:
        archive, digest = self.archive(
            [(tarfile.TarInfo("+INSTALL"), b"exit 99\n"), (tarfile.TarInfo("/data"), b"kept")]
        )
        root = self.root()
        extract(root, archive, digest)
        self.assertEqual((root / "data").read_bytes(), b"kept")
        self.assertFalse((root / "+INSTALL").exists())

    def test_only_exact_pinned_sudo_setid_is_stripped(self) -> None:
        member = tarfile.TarInfo("/usr/local/bin/sudo")
        member.mode = 0o4755
        archive, digest = self.archive([(member, b"sudo")])
        root = self.root()
        with self.assertRaisesRegex(ValueError, "unsupported package mode"):
            extract(root, archive, digest)
        with patch("native_git.extract_freebsd.SUDO_PACKAGE_SHA256", digest):
            extract(root, archive, digest)
        self.assertEqual((root / "usr/local/bin/sudo").stat().st_mode & 0o7777, 0o755)
        for name, mode, uid in (
            ("/usr/local/bin/other", 0o4755, 0),
            ("/usr/local/bin/sudo", 0o6755, 0),
            ("/usr/local/bin/sudo", 0o4755, 1),
        ):
            member = tarfile.TarInfo(name)
            member.mode, member.uid = mode, uid
            archive, digest = self.archive([(member, b"refused")])
            with (
                patch("native_git.extract_freebsd.SUDO_PACKAGE_SHA256", digest),
                self.assertRaisesRegex(ValueError, "unsupported package mode"),
            ):
                extract(root, archive, digest)

    def test_later_package_cannot_write_through_directory_link(self) -> None:
        root = self.root()
        (root / "real").mkdir()
        (root / "redirect").symlink_to("real", target_is_directory=True)
        archive, digest = self.archive([(tarfile.TarInfo("/redirect/data"), b"refused")])
        with self.assertRaisesRegex(ValueError, "traverses a symlink"):
            extract(root, archive, digest)
        self.assertFalse((root / "real/data").exists())

    def test_early_refusal_terminates_decompressor(self) -> None:
        bad = tarfile.TarInfo("/refused")
        bad.type = tarfile.FIFOTYPE
        archive, digest = self.archive(
            [(bad, b""), (tarfile.TarInfo("/large"), b"payload" * (1024 * 1024))]
        )
        result = subprocess.run(
            [
                "python3.13",
                "-c",
                "from pathlib import Path; from native_git.extract_freebsd import extract; "
                "import sys; extract(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])",
                str(self.root()),
                str(archive),
                digest,
            ],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("special package entry refused", result.stderr)

    def test_newer_release_and_missing_dependency_refuse(self) -> None:
        record: dict[str, object] = {
            "name": "git-lite",
            "version": "2.49.0",
            "url": "https://pkg.freebsd.org/FreeBSD:14:amd64/release_3/All/git.pkg",
            "sha256": "0" * 64,
            "freebsd_version": 1404000,
            "dependencies": [],
        }
        with self.assertRaisesRegex(ValueError, "compatible official package"):
            package_records([record])
        record.update(freebsd_version=1402000, dependencies=["missing"])
        with self.assertRaisesRegex(ValueError, "dependency closure"):
            package_records([record])


if __name__ == "__main__":
    unittest.main()
