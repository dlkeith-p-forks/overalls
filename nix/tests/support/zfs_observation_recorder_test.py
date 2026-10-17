"""Disposable executable checks for the fixture's observation pass-through boundary."""

import base64
import ctypes
import fcntl
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import instrument_clone_observation as instrument
import zfs_observation_recorder as recorder


class RecorderTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.ring = self.root / "ring"
        self.ring.mkdir(mode=0o700)
        (self.ring / "armed").touch(mode=0o600)
        self.native = self.root / "zfs"
        self.native.write_text(
            f"#!{sys.executable}\n"
            "import json, os, signal, sys, time\n"
            "from pathlib import Path\n"
            "root = Path(os.environ['FAKE_ROOT'])\n"
            "(root / 'pid').write_text(str(os.getpid()))\n"
            "(root / 'group').write_text(str(os.getpgrp()))\n"
            "if 'FAKE_CHANGE_CONTEXT' in os.environ:\n"
            "    Path(os.environ['FAKE_CHANGE_CONTEXT']).unlink()\n"
            "if 'FAKE_FD' in os.environ:\n"
            "    os.fstat(int(os.environ['FAKE_FD']))\n"
            "    (root / 'inherited').touch()\n"
            "with (root / 'calls').open('a') as output:\n"
            "    output.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "os.write(1, (root / 'stdout').read_bytes())\n"
            "os.write(2, (root / 'stderr').read_bytes())\n"
            "time.sleep(float(os.environ.get('FAKE_SLEEP', '0')))\n"
            "status = int(os.environ['FAKE_STATUS'])\n"
            "if status < 0:\n"
            "    os.kill(os.getpid(), -status)\n"
            "sys.exit(status)\n"
        )
        self.native.chmod(0o700)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def invoke(
        self,
        arguments: list[str],
        stdout: bytes = b"public\x00\xff\n",
        stderr: bytes = b"err\n",
        status: int = 7,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[bytes]:
        (self.root / "stdout").write_bytes(stdout)
        (self.root / "stderr").write_bytes(stderr)
        return subprocess.run(
            self.launcher(arguments),
            env={
                **os.environ,
                "FAKE_ROOT": str(self.root),
                "FAKE_STATUS": str(status),
                **(environment or {}),
            },
            capture_output=True,
            check=False,
            timeout=5,
        )

    def launcher(self, arguments: list[str]) -> list[str]:
        code = (
            "import sys; from pathlib import Path; "
            f"sys.path.insert(0, {str(Path(__file__).parent)!r}); "
            "import zfs_observation_recorder as recorder; "
            f"recorder.finish(recorder.forward({str(self.native)!r}, {arguments!r}, Path({str(self.ring)!r})))"
        )
        return [sys.executable, "-c", code]

    def slow(self, descriptor: int | None = None) -> subprocess.Popen[bytes]:
        (self.root / "stdout").write_bytes(b"native output")
        (self.root / "stderr").write_bytes(b"")
        return subprocess.Popen(
            self.launcher(recorder.ARGUMENTS),
            env={
                **os.environ,
                "FAKE_ROOT": str(self.root),
                "FAKE_STATUS": "0",
                "FAKE_SLEEP": "60",
                **({"FAKE_FD": str(descriptor)} if descriptor is not None else {}),
            },
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            pass_fds=() if descriptor is None else (descriptor,),
        )

    def native_pid(self) -> int:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            path = self.root / "pid"
            if path.exists() and path.read_text():
                return int(path.read_text())
            time.sleep(0.01)
        self.fail("Disposable native child failed to start")

    def sample(self, slot: int = 0) -> dict[str, object]:
        data: object = json.loads((self.ring / f"sample-{slot:03d}.json").read_text())
        assert isinstance(data, dict)
        result: dict[str, object] = {}
        for key, value in data.items():
            assert isinstance(key, str)
            result[key] = value
        return result

    def test_target_preserves_bytes_status_argv_and_single_execution(self) -> None:
        result = self.invoke(recorder.ARGUMENTS)
        self.assertEqual(
            (result.stdout, result.stderr, result.returncode), (b"public\x00\xff\n", b"err\n", 7)
        )
        sample = self.sample()
        self.assertEqual(sample["stdout_base64"], base64.b64encode(result.stdout).decode())
        self.assertEqual(sample["stderr_base64"], base64.b64encode(result.stderr).decode())
        self.assertEqual(sample["returncode"], 7)
        self.assertEqual((self.root / "calls").read_text(), json.dumps(recorder.ARGUMENTS) + "\n")
        for path in self.ring.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_nonallowlisted_and_unarmed_commands_leave_no_samples(self) -> None:
        for arguments in [
            ["get", "-Hp", "-o", "value", "org.overalls:owner", "zroot/lilly"],
            ["receive", "-s", "zroot/lilly/vm-example"],
            [*recorder.ARGUMENTS[:-1], "zroot/foreign"],
            [*recorder.ARGUMENTS, "--extra"],
            [
                argument.replace("readonly", "receive_resume_token")
                for argument in recorder.ARGUMENTS
            ],
        ]:
            result = self.invoke(arguments, b"synthetic-token", status=11)
            self.assertEqual(
                (result.stdout, result.stderr, result.returncode),
                (b"synthetic-token", b"err\n", 11),
            )
        (self.ring / "armed").unlink()
        self.assertEqual(self.invoke(recorder.ARGUMENTS).returncode, 7)
        self.assertEqual(list(self.ring.iterdir()), [])
        self.assertEqual(len((self.root / "calls").read_text().splitlines()), 6)

    def test_output_limits_do_not_truncate_forwarded_streams(self) -> None:
        stdout = b"a" * (recorder.STREAM_LIMIT + 17)
        stderr = b"b" * (recorder.STREAM_LIMIT + 29)
        result = self.invoke(recorder.ARGUMENTS, stdout, stderr, 0)
        self.assertEqual((result.stdout, result.stderr, result.returncode), (stdout, stderr, 0))
        sample = self.sample()
        for name, original in (("stdout", stdout), ("stderr", stderr)):
            self.assertEqual(
                sample[name + "_base64"],
                base64.b64encode(original[: recorder.STREAM_LIMIT]).decode(),
            )
            self.assertEqual(sample[name + "_bytes"], len(original))
            self.assertIs(sample[name + "_truncated"], True)

    def test_ring_reuses_slots_and_recording_failure_preserves_result(self) -> None:
        sample: recorder.ObservationSample = {
            "started_ns": 1,
            "finished_ns": 2,
            "returncode": 0,
            "stdout_base64": "",
            "stderr_base64": "",
            "stdout_bytes": 0,
            "stderr_bytes": 0,
            "stdout_truncated": False,
            "stderr_truncated": False,
            "readiness": {"state": "missing"},
        }
        for _sequence in range(recorder.SAMPLE_COUNT + 3):
            recorder.save_sample(self.ring, sample)
        self.assertEqual(len(list(self.ring.glob("sample-*.json"))), recorder.SAMPLE_COUNT)
        self.assertEqual(self.sample(2)["sequence"], recorder.SAMPLE_COUNT + 2)
        (self.ring / "next").write_text("malformed")
        result = self.invoke(recorder.ARGUMENTS)
        self.assertEqual(
            (result.stdout, result.stderr, result.returncode), (b"public\x00\xff\n", b"err\n", 7)
        )

    def test_signal_status_is_preserved(self) -> None:
        result = self.invoke(recorder.ARGUMENTS, status=-signal.SIGTERM)
        self.assertEqual(result.returncode, -signal.SIGTERM)
        self.assertEqual(self.sample()["returncode"], -signal.SIGTERM)

    def test_persistence_lock_contention_never_waits(self) -> None:
        with (self.ring / "lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = self.invoke(recorder.ARGUMENTS)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(list(self.ring.glob("sample-*.json")), [])

    def test_wrapper_signal_reaps_child_in_original_group(self) -> None:
        with self.slow() as wrapper:
            child = self.native_pid()
            self.assertEqual(int((self.root / "group").read_text()), os.getpgid(wrapper.pid))
            wrapper.terminate()
            self.assertEqual(wrapper.wait(timeout=3), -signal.SIGTERM)
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)

    def test_broken_consumer_reaps_child(self) -> None:
        with self.slow() as wrapper:
            assert wrapper.stdout is not None
            wrapper.stdout.close()
            child = self.native_pid()
            self.assertEqual(wrapper.wait(timeout=3), -signal.SIGPIPE)
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)

    def test_abrupt_wrapper_death_kills_child_and_releases_inherited_lock(self) -> None:
        # Adopt the killed grandchild solely in this disposable test process so
        # the assertion also reaps it rather than relying on the host's PID 1.
        library = ctypes.CDLL(None)
        prctl = library.prctl
        prctl.argtypes = [
            ctypes.c_int,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
        ]
        prctl.restype = ctypes.c_int
        self.assertEqual(prctl(36, 1, 0, 0, 0), 0)  # PR_SET_CHILD_SUBREAPER
        lock_path = self.root / "custody.lock"
        descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        with self.slow(descriptor) as wrapper:
            child = self.native_pid()
            deadline = time.monotonic() + 3
            while not (self.root / "inherited").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.root / "inherited").exists())
            os.close(descriptor)
            with lock_path.open("r") as contender:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                wrapper.kill()
                self.assertEqual(wrapper.wait(timeout=3), -signal.SIGKILL)
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    reaped, status = os.waitpid(child, os.WNOHANG)
                    if reaped:
                        self.assertTrue(os.WIFSIGNALED(status))
                        self.assertEqual(os.WTERMSIG(status), signal.SIGKILL)
                        break
                    time.sleep(0.01)
                else:
                    os.kill(child, signal.SIGKILL)
                    os.waitpid(child, 0)
                    self.fail("Parent-death fence did not kill the native child")
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_child_parent_identity_race_refuses_native_execution(self) -> None:
        result = subprocess.run(
            [str(self.native)],
            preexec_fn=lambda: recorder.child_custody(0),
            capture_output=True,
            check=False,
            timeout=3,
        )
        self.assertEqual(result.returncode, 127)
        self.assertFalse((self.root / "pid").exists())

    def test_context_requires_exact_owner_and_closed_guid_schema(self) -> None:
        placement = "11111111-1111-4111-8111-111111111111"
        name = "zroot/lilly/vm-" + placement + "@lilly-b"
        payload: dict[str, object] = {
            "placement_id": placement,
            "snapshots": {name: {"dataset_guid": "123", "snapshot_guid": "456"}},
        }
        context = self.ring / f"context-{os.getpid()}.json"
        context.write_text(json.dumps(payload))
        context.chmod(0o600)
        self.invoke(recorder.ARGUMENTS)
        self.assertEqual(self.sample()["readiness"], {"state": "present", **payload})
        payload["snapshots"] = {}
        context.write_text(json.dumps(payload))
        self.invoke(recorder.ARGUMENTS)
        self.assertEqual(self.sample(1)["readiness"], {"state": "present", **payload})
        payload["synthetic_token"] = "excluded-private-value"
        context.write_text(json.dumps(payload))
        self.invoke(recorder.ARGUMENTS)
        self.assertEqual(self.sample(2)["readiness"], {"state": "invalid"})
        self.assertNotIn("excluded-private-value", (self.ring / "sample-002.json").read_text())
        context.rename(self.ring / "context-0.json")
        self.invoke(recorder.ARGUMENTS)
        self.assertEqual(self.sample(3)["readiness"], {"state": "missing"})

    def test_context_change_is_not_attributed_to_readiness(self) -> None:
        context = self.ring / f"context-{os.getpid()}.json"
        context.write_text(
            json.dumps({"placement_id": "11111111-1111-4111-8111-111111111111", "snapshots": {}})
        )
        context.chmod(0o600)
        self.invoke(recorder.ARGUMENTS, environment={"FAKE_CHANGE_CONTEXT": str(context)})
        self.assertEqual(self.sample()["readiness"], {"state": "changed"})

    def test_source_instrumentation_refuses_changed_or_duplicate_seams(self) -> None:
        source = self.root / "zfs.ex"
        command = [sys.executable, str(Path(instrument.__file__)), str(source)]
        for text, status in (
            (instrument.SOURCE, 0),
            (instrument.SOURCE + instrument.SOURCE, 1),
            ("changed", 1),
        ):
            source.write_text(text)
            result = subprocess.run(command, capture_output=True, check=False, timeout=3)
            self.assertEqual(result.returncode, status)
            self.assertEqual(source.read_text(), instrument.REPLACEMENT if status == 0 else text)


if __name__ == "__main__":
    unittest.main()
