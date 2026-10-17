"""Exercise private fault-spool custody with actual expendable child processes."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from crash import identity
from fault_worker import process, read_object

EXECUTABLE = Path("/proc/self/exe").resolve()

REQUEST = "11111111-1111-4111-8111-111111111111"
PLACEMENT = "22222222-2222-4222-8222-222222222222"


class FaultWorkerTest(unittest.TestCase):
    def fixture(self, root: Path, child: subprocess.Popen[bytes]) -> tuple[Path, Path, Path]:
        spool, state = root / "spool", root / "state"
        for name in ("requests", "claims", "receipts"):
            (spool / name).mkdir(parents=True)
        directory = state / PLACEMENT
        directory.mkdir(parents=True)
        observed = identity(child.pid)
        launch = {
            "placement_id": PLACEMENT,
            "execution_epoch": 1,
            "generation": 2,
            "qemu": {
                "pid": child.pid,
                "start_ticks": observed.start_ticks,
                "executable": str(Path(str(EXECUTABLE)).resolve()),
            },
        }
        (directory / "launch.json").write_text(json.dumps(launch), encoding="ascii")
        request = spool / "requests" / (REQUEST + ".json")
        request.write_text(
            json.dumps(
                {
                    "version": 1,
                    "operation": "crash_guest",
                    "request_id": REQUEST,
                    "placement_id": PLACEMENT,
                    "execution_epoch": 1,
                    "generation": 2,
                    "qemu_pid": child.pid,
                    "qemu_start_ticks": observed.start_ticks,
                }
            ),
            encoding="ascii",
        )
        return spool, state, request

    def test_receipt_requires_exact_exit_and_replay_is_stable(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            subprocess.Popen([str(EXECUTABLE), "-c", "import time; time.sleep(60)"]) as child,
        ):
            try:
                spool, state, request = self.fixture(Path(temporary), child)
                original = request.read_bytes()
                process(spool, state, Path(str(EXECUTABLE)), request, recovered=False)
                self.assertEqual(child.wait(timeout=2), -9)
                target = spool / "receipts" / request.name
                before = target.read_bytes()
                self.assertEqual(read_object(target)["state"], "exited")
                request.write_bytes(original)
                process(spool, state, Path(str(EXECUTABLE)), request, recovered=False)
                self.assertEqual(target.read_bytes(), before)
                self.assertFalse(request.exists())
            finally:
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=2)

    def test_recovered_uncertain_claim_never_signals(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            subprocess.Popen([str(EXECUTABLE), "-c", "import time; time.sleep(60)"]) as child,
        ):
            try:
                spool, state, request = self.fixture(Path(temporary), child)
                claim = spool / "claims" / request.name
                request.replace(claim)
                process(spool, state, Path(str(EXECUTABLE)), claim, recovered=True)
                self.assertIsNone(child.poll())
                receipt = read_object(spool / "receipts" / claim.name)
                self.assertEqual(receipt["state"], "unavailable")
                self.assertIsNone(receipt["exited_monotonic_ns"])
            finally:
                child.terminate()
                child.wait(timeout=2)

    def test_stale_boot_tuple_preserves_child(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            subprocess.Popen([str(EXECUTABLE), "-c", "import time; time.sleep(60)"]) as child,
        ):
            try:
                spool, state, request = self.fixture(Path(temporary), child)
                raw = read_object(request)
                raw["generation"] = 1
                request.write_text(json.dumps(raw), encoding="ascii")
                process(spool, state, Path(str(EXECUTABLE)), request, recovered=False)
                self.assertIsNone(child.poll())
                result = read_object(spool / "receipts" / request.name)
                self.assertEqual(result["state"], "unavailable")
            finally:
                child.terminate()
                child.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()
