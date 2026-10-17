"""Real child-process checks; these do not establish emulated guest recovery."""

import subprocess
import unittest
from pathlib import Path

from crash import ProcessIdentity, crash, identity

EXECUTABLE = Path("/proc/self/exe").resolve()


class CrashTest(unittest.TestCase):
    def test_exact_process_exits(self) -> None:
        with subprocess.Popen([str(EXECUTABLE), "-c", "import time; time.sleep(60)"]) as child:
            try:
                expected = identity(child.pid)
                receipt = crash(expected, EXECUTABLE)
                self.assertEqual(receipt["pid"], child.pid)
                self.assertEqual(receipt["start_ticks"], expected.start_ticks)
                self.assertEqual(receipt["state"], "exited")
                self.assertGreaterEqual(
                    receipt["exited_monotonic_ns"], receipt["sent_monotonic_ns"]
                )
                self.assertEqual(child.wait(timeout=2), -9)
            finally:
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=2)

    def test_wrong_start_tick_preserves_process(self) -> None:
        with subprocess.Popen([str(EXECUTABLE), "-c", "import time; time.sleep(60)"]) as child:
            try:
                expected = identity(child.pid)
                with self.assertRaises(ProcessLookupError):
                    crash(
                        ProcessIdentity(child.pid, expected.start_ticks + 1), Path(str(EXECUTABLE))
                    )
                self.assertIsNone(child.poll())
            finally:
                child.terminate()
                child.wait(timeout=2)

    def test_wrong_executable_preserves_process(self) -> None:
        with subprocess.Popen([str(EXECUTABLE), "-c", "import time; time.sleep(60)"]) as child:
            try:
                with self.assertRaises(ValueError):
                    crash(identity(child.pid), Path("/proc/self/stat"))
                self.assertIsNone(child.poll())
            finally:
                child.terminate()
                child.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()
