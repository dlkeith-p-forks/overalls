"""Native-shaped procfs fixtures; no physical relocation acceptance claim."""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("relocation_diagnostics", sys.argv.pop(1))
if spec is None or spec.loader is None:
    raise RuntimeError("Relocation diagnostic helper unavailable")
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


def observed(value: object) -> tuple[bool, list[dict[str, object]]]:
    if not isinstance(value, dict):
        raise ValueError("Invalid observation")
    complete: object = value.get("complete")
    entries: object = value.get("entries")
    if not isinstance(complete, bool) or not isinstance(entries, list):
        raise ValueError("Invalid observation")
    rows: list[dict[str, object]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("Invalid process")
        row: dict[str, object] = {}
        for key, item in entry.items():
            if not isinstance(key, str):
                raise ValueError("Invalid process field")
            row[key] = item
        rows.append(row)
    return complete, rows


class RelocationDiagnosticsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.proc = Path(self.temp.name)

    def process(
        self,
        pid: int,
        parent: int,
        flags: int = 0,
        executable: str | None = None,
        read_bytes: int = 2_097_152,
    ) -> Path:
        path = self.proc / str(pid)
        path.mkdir()
        # Native stat fields: state, ppid, pgrp, session, tty, tpgid, flags.
        (path / "stat").write_bytes(
            f"{pid} (private-process-name) S {parent} 0 0 0 0 {flags} 0 0 0\n".encode()
        )
        if executable is not None:
            (path / "exe").symlink_to("/private-executable-path/bin/" + executable)
            (path / "wchan").write_text("pipe_read\n")
            (path / "io").write_text(f"rchar: {read_bytes}\nwchar: 0\n")
            (path / "fd").mkdir()
            (path / "fd" / "0").symlink_to("pipe:[101]")
            (path / "fd" / "1").symlink_to("/private-descriptor-target")
        return path

    def scan(self) -> tuple[bool, list[dict[str, object]]]:
        value: object = diagnostics.transfer_processes(self.proc)
        return observed(value)

    def test_kernel_thread_without_exe_preserves_complete_native_stream_witness(self) -> None:
        """@cc [owner:ghuntley,label:verification;recovery] kernel-thread-not-userspace-ambiguity
        A native-shaped PF_KTHREAD process with no executable MUST NOT hide the
        unique helper/ZFS child and its numeric input bytes. This parser fixture
        MUST NOT claim physical stream execution, receipt or cleanup acceptance.
        """
        self.process(2, 0, flags=1 << 21)
        self.process(100, 90, executable="lilly-transfer-stream")
        self.process(101, 100, executable="zfs")
        complete, rows = self.scan()
        self.assertTrue(complete)
        self.assertEqual({row["pid"] for row in rows}, {100, 101})
        helpers = [row for row in rows if row["executable"] == "lilly-transfer-stream"]
        consumers = [row for row in rows if row["executable"] == "zfs"]
        self.assertEqual(len(helpers), 1)
        self.assertEqual(len(consumers), 1)
        self.assertEqual(consumers[0]["parent"], helpers[0]["pid"])
        self.assertEqual(consumers[0]["read_bytes"], 2_097_152)
        encoded = json.dumps(rows)
        for private in ("private-process-name", "private-executable-path", "private-descriptor"):
            self.assertNotIn(private, encoded)

    def test_userspace_missing_executable_keeps_scan_incomplete(self) -> None:
        self.process(100, 90, executable="lilly-transfer-stream")
        self.process(101, 100, executable="zfs")
        self.process(102, 100)
        complete, rows = self.scan()
        self.assertFalse(complete)
        self.assertEqual(len(rows), 2)

    def test_racing_userspace_stat_keeps_scan_incomplete(self) -> None:
        path = self.process(100, 90, executable="lilly-transfer-stream")
        (path / "stat").unlink()
        complete, rows = self.scan()
        self.assertFalse(complete)
        self.assertEqual(rows, [])

    def test_malformed_oversized_and_unbounded_flags_do_not_classify_kernel_threads(self) -> None:
        path = self.process(2, 0, flags=1 << 21)
        for record in (
            b"malformed",
            b"2 (kernel) S 0 0 0 0 0 -1\n",
            b"2 (kernel) S 0 0 0 0 0 18446744073709551616\n",
            b"2 (kernel) Q 0 0 0 0 0 2097152\n",
            b"x" * 4097,
        ):
            with self.subTest(size=len(record)):
                (path / "stat").write_bytes(record)
                complete, rows = self.scan()
                self.assertFalse(complete)
                self.assertEqual(rows, [])

    def test_process_name_cannot_claim_kernel_identity(self) -> None:
        self.process(2, 0)
        complete, rows = self.scan()
        self.assertFalse(complete)
        self.assertEqual(rows, [])

    def test_unknown_numeric_input_remains_unknown(self) -> None:
        path = self.process(101, 100, executable="zfs")
        for counter in ("rchar: -1\n", "rchar: 1\nrchar: 2\n", "rchar: 9223372036854775808\n"):
            with self.subTest(counter_length=len(counter)):
                (path / "io").write_text(counter)
                complete, rows = self.scan()
                self.assertTrue(complete)
                self.assertEqual(rows[0]["read_bytes"], "unknown")


if __name__ == "__main__":
    unittest.main()
