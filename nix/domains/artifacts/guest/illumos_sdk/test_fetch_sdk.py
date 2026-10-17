"""Refusal and integrity checks for the official OmniOS sysroot extractor."""

import gzip
import hashlib
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from .fetch_sdk import Entry, fetch_file, parse_manifest, safe_path, sha512_256


def payload(data: bytes) -> tuple[Entry, bytes]:
    compressed = gzip.compress(data, mtime=0)
    return (
        Entry(
            "file",
            "usr/include/probe.h",
            hashlib.sha1(data).hexdigest(),
            sha512_256(compressed),
            sha512_256(data),
            len(data),
            len(compressed),
            False,
            "",
        ),
        compressed,
    )


class SysrootExtractionTests(unittest.TestCase):
    def test_only_canonical_relative_paths_are_allowed(self) -> None:
        for value in ("", ".", "/root", "../root", "a/../../root", "a//b", "a/./b", "a\nb"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                safe_path(value)
        self.assertEqual(safe_path("usr/include/sys/socket.h"), "usr/include/sys/socket.h")

    def test_link_targets_cannot_escape_and_absolute_guest_paths_stay_relative(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "package.p5m"
            identity = "set name=pkg.fmri value=pkg://omnios/system/header@0.5.11,5.11-151050.0:20240426T120142Z\n"
            manifest.write_text(identity + "link path=usr/include/probe target=../../../outside\n")
            with self.assertRaises(ValueError):
                parse_manifest(manifest)
            manifest.write_text(
                identity + "link path=usr/lib/amd64/libc.so target=/lib/amd64/libc.so.1\n"
            )
            entry = parse_manifest(manifest).entries[0]
            self.assertEqual(entry.target, "../../../lib/amd64/libc.so.1")

    def test_verified_payload_preserves_exact_bytes_and_never_overwrites(self) -> None:
        entry, compressed = payload(b"#define PROBE 1\n")
        limits: list[int] = []

        def receive(_url: str, limit: int) -> bytes:
            limits.append(limit)
            return compressed

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = fetch_file(root, entry, receive)
            self.assertEqual((root / entry.path).read_bytes(), b"#define PROBE 1\n")
            self.assertEqual(record["sha256"], hashlib.sha256(b"#define PROBE 1\n").hexdigest())
            self.assertEqual(limits, [len(compressed) + 1])
            with self.assertRaises(FileExistsError):
                fetch_file(root, entry, receive)

    def test_selected_setid_payload_refuses(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "package.p5m"
            manifest.write_text(
                "set name=pkg.fmri value=pkg://omnios/system/header@0.5.11,5.11-151050.0:20240426T120142Z\n"
                "file " + "0" * 40 + " path=usr/include/probe mode=04755 pkg.size=1 pkg.csize=1 "
                "pkg.content-hash=gzip:sha512t_256:"
                + "0" * 64
                + " pkg.content-hash=file:sha512t_256:"
                + "0" * 64
                + "\n"
            )
            with self.assertRaisesRegex(ValueError, "file mode"):
                parse_manifest(manifest)

    def test_tampering_and_underreported_sizes_refuse_without_output(self) -> None:
        entry, compressed = payload(b"a" * 4096)
        variants: list[tuple[Entry, bytes]] = [
            (entry, compressed[:-1] + bytes([compressed[-1] ^ 1])),
            (replace(entry, size=1), compressed),
            (replace(entry, compressed_size=1), compressed),
            (replace(entry, content_digest="0" * 64), compressed),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for invalid, value in variants:
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    fetch_file(root, invalid, lambda _url, _limit, value=value: value)
                self.assertFalse((root / entry.path).exists())


if __name__ == "__main__":
    unittest.main()
