"""Service identities must not inherit distro accounts or collide with managed users."""

import tempfile
import unittest
from pathlib import Path

from foreign_linux_accounts import SERVICE_NAMES, install, records


class ServiceIdentityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.etc = self.root / "etc"
        self.etc.mkdir()
        (self.etc / "passwd").write_text(
            "root:x:0:0:root:/root:/bin/bash\n"
            "existing:x:998:997:Existing:/home/existing:/bin/bash\n"
            "sshd:x:50:50:Old sshd:/var/empty:/bin/false\n"
        )
        (self.etc / "group").write_text("root:x:0:\nexisting:x:998:\nsshd:x:50:\n")
        (self.etc / "shadow").write_text("root:!:1:0:99999:7:::\nsshd:old:1:0:99999:7:::\n")

    def test_service_accounts_are_distinct_locked_and_do_not_collide(self) -> None:
        install(self.root)
        passwd = {row[0]: row for row in records(self.etc / "passwd", 7)}
        groups = {row[0]: row for row in records(self.etc / "group", 4)}
        shadows = {row[0]: row for row in records(self.etc / "shadow", 9)}
        self.assertEqual(
            passwd["existing"],
            ["existing", "x", "998", "997", "Existing", "/home/existing", "/bin/bash"],
        )
        self.assertEqual({passwd[name][2] for name in SERVICE_NAMES}, {"999", "996"})
        for name in SERVICE_NAMES:
            self.assertEqual(passwd[name][2:4], [groups[name][2], groups[name][2]])
            self.assertEqual(passwd[name][5:], ["/var/empty", "/usr/sbin/nologin"])
            self.assertEqual(shadows[name][1], "!")
        self.assertEqual((self.etc / "shadow").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.etc / "gshadow").stat().st_mode & 0o777, 0o600)
        first = {path.name: path.read_bytes() for path in self.etc.iterdir()}
        install(self.root)
        self.assertEqual(first, {path.name: path.read_bytes() for path in self.etc.iterdir()})

    def test_malformed_or_duplicate_records_do_not_change_any_database(self) -> None:
        for invalid in (
            "root:x:0\n",
            "root:x:bad:0:root:/root:/bin/bash\n",
            "sshd:x:bad:50:Old:/var/empty:/bin/false\n",
            "root:x:0:0::/:/bin/bash\n" * 2,
        ):
            with self.subTest(invalid=invalid):
                (self.etc / "passwd").write_text(invalid)
                before = {path.name: path.read_bytes() for path in self.etc.iterdir()}
                with self.assertRaises(ValueError):
                    install(self.root)
                self.assertEqual(
                    before, {path.name: path.read_bytes() for path in self.etc.iterdir()}
                )

    def test_exhausted_system_range_fails_before_writing(self) -> None:
        (self.etc / "group").write_text("".join(f"g{gid}:x:{gid}:\n" for gid in range(100, 1000)))
        before = {path.name: path.read_bytes() for path in self.etc.iterdir()}
        with self.assertRaises(ValueError):
            install(self.root)
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.etc.iterdir()})


if __name__ == "__main__":
    unittest.main()
