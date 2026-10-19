"""Refuse unsafe optional API lifetimes without granting native runtime evidence."""

from __future__ import annotations

import io
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import native_control as control
import native_service_runner as runner
import native_services as services


class NativePhaseDiagnosticsTest(unittest.TestCase):
    """Closed host diagnostics do not establish native execution evidence."""

    def test_operation_results_and_error_payloads_do_not_enter_diagnostics(self) -> None:
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(
                runner.run_phase("receipt-image-digest", lambda: "private-result"), "private-result"
            )

            def fail() -> None:
                raise subprocess.TimeoutExpired(
                    ["private-command"], 20, output=b"private-stdout", stderr=b"private-stderr"
                )

            with self.assertRaises(runner.PhaseFailure) as captured:
                runner.run_phase("shutdown-send", fail)
        self.assertEqual(captured.exception.phase, "shutdown-send")
        self.assertEqual(captured.exception.category, "subprocess-timeout")
        self.assertEqual(str(captured.exception), "native service phase failed")
        self.assertEqual(
            output.getvalue(),
            "native service phase=receipt-image-digest state=started\n"
            "native service phase=receipt-image-digest state=complete\n"
            "native service phase=shutdown-send state=started\n",
        )

    def test_successful_cleanup_preserves_the_failed_operation_phase(self) -> None:
        def fail() -> None:
            raise services.ProtocolError("private-protocol-payload")

        with redirect_stdout(io.StringIO()), self.assertRaises(runner.PhaseFailure) as captured:
            try:
                runner.run_phase("shutdown-vmm-wait", fail)
            finally:
                runner.run_phase("authority-server-stop", lambda: None)
        self.assertEqual(captured.exception.phase, "shutdown-vmm-wait")
        self.assertEqual(captured.exception.category, "protocol")

    def test_failed_cleanup_reports_its_own_closed_phase(self) -> None:
        def fail() -> None:
            raise OSError("private-filesystem-path")

        with redirect_stdout(io.StringIO()), self.assertRaises(runner.PhaseFailure) as captured:
            runner.run_phase("authority-server-close", fail)
        self.assertEqual(captured.exception.phase, "authority-server-close")
        self.assertEqual(captured.exception.category, "io")

    def test_shutdown_ssh_stages_never_disclose_debug_bytes(self) -> None:
        output = io.StringIO()
        with redirect_stdout(output):
            runner.shutdown_ssh_stage(
                b"debug1: Connection established.\n"
                b"Authenticated to private-peer using private-credential\n"
                b"debug1: Sending command: private-command\nprivate-payload\n"
            )
            runner.shutdown_ssh_stage(None)
        self.assertEqual(
            output.getvalue(),
            "native service shutdown ssh_stage=command-sent\n"
            "native service shutdown ssh_stage=unobserved\n",
        )

    def test_shutdown_ssh_timeout_keeps_original_bound_and_closed_diagnostics(self) -> None:
        output = io.StringIO()
        timeout = subprocess.TimeoutExpired(
            ["private-command"],
            20,
            stderr=b"debug1: Connection established.\nprivate-credential\n",
        )
        with (
            patch.object(runner.subprocess, "run", side_effect=timeout) as invoked,
            redirect_stdout(output),
            self.assertRaises(subprocess.TimeoutExpired),
        ):
            runner.ssh(
                Path("/private-fixture"),
                Path("/private-known-hosts"),
                "private-command",
                shutdown_diagnostics=True,
            )
        self.assertEqual(invoked.call_args.kwargs["timeout"], 20)
        self.assertEqual(invoked.call_args.args[0][-1], "private-command")
        self.assertEqual(output.getvalue(), "native service shutdown ssh_stage=connected\n")

    def test_actual_shutdown_flow_distinguishes_send_and_vmm_wait_timeouts(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            subprocess.Popen(
                [sys.executable, "-c", "pass"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ) as process,
        ):
            root = Path(temporary)
            binding = services.Binding("dddddddd-dddd-4ddd-8ddd-000000000201", 7, "a" * 64)
            context = runner.BootContext(
                root / "uds",
                services.Boot(binding, "dddddddd-dddd-4ddd-8ddd-000000000202"),
                root,
                root,
                runner.DEFAULT_NETWORK,
                runner.Platform("illumos"),
                process,
                control.Authority(
                    control.Config(root / "ca", "native.fixture.test", frozenset({"127.0.0.1"}))
                ),
            )
            with (
                patch.object(runner, "ssh", side_effect=subprocess.TimeoutExpired("private", 20)),
                patch.object(runner, "wait_clean_shutdown") as wait,
                redirect_stdout(io.StringIO()),
                self.assertRaises(runner.PhaseFailure) as sent,
            ):
                runner.clean_shutdown(context)
            self.assertEqual(sent.exception.phase, "shutdown-send")
            wait.assert_not_called()
            accepted = subprocess.CompletedProcess[bytes](["synthetic-shutdown"], 255, b"", b"")
            with (
                patch.object(runner, "ssh", return_value=accepted),
                patch.object(
                    runner,
                    "wait_clean_shutdown",
                    side_effect=subprocess.TimeoutExpired("private", 60),
                ),
                redirect_stdout(io.StringIO()),
                self.assertRaises(runner.PhaseFailure) as waited,
            ):
                runner.clean_shutdown(context)
            self.assertEqual(waited.exception.phase, "shutdown-vmm-wait")
            self.assertEqual(waited.exception.category, "subprocess-timeout")


class NativeLeaseOracleTest(unittest.TestCase):
    def test_live_parent_and_descendant_must_share_the_parent_led_group(self) -> None:
        observed = runner.process_group(b"700 701\n700 700 S\n701 700 S\ngroup-present\n")
        self.assertTrue(observed.live)
        self.assertFalse(observed.absent)
        gone = runner.process_group(b"700 701\ngroup-absent\n", (700, 701))
        self.assertTrue(gone.absent)
        self.assertFalse(gone.live)
        for payload in (
            b"700 701\n700 700 Z\n701 700 S\ngroup-present\n",
            b"700 701\n700 700 S\ngroup-present\n",
            b"700 701\ngroup-present\n",
        ):
            with self.subTest(payload_kind="not-live"):
                observed = runner.process_group(payload)
                self.assertFalse(observed.live)
                self.assertFalse(observed.absent)

    def test_malformed_reused_or_escaped_process_identity_refuses(self) -> None:
        for payload in (
            b"",
            b"700\ngroup-absent\n",
            b"700 701\ngroup-absent",
            b"0 701\ngroup-absent\n",
            b"1 701\ngroup-absent\n",
            b"700 700\ngroup-absent\n",
            b"0700 701\ngroup-absent\n",
            b"2147483648 701\ngroup-absent\n",
            b"700 701 extra\ngroup-absent\n",
            b"700 701\n700 999 S\n701 700 S\ngroup-present\n",
            b"700 701\n700 700 S\n702 700 S\ngroup-present\n",
            b"700 701\n700 700 S\n700 700 S\ngroup-present\n",
            b"700 701\n700 700 S command-bytes\ngroup-present\n",
            b"700 701\n700 700 Q\n701 700 S\ngroup-present\n",
            b"700 701\ngroup-unknown\n",
            b"700 701\n" + b"a" * 256 + b"\ngroup-present\n",
        ):
            with self.subTest(payload_kind="closed-refusal"), self.assertRaises(ValueError):
                runner.process_group(payload)
        with self.assertRaises(ValueError):
            runner.process_group(b"702 703\ngroup-absent\n", (700, 701))

    def test_withdrawal_budget_is_anchored_to_accepted_start_and_result_attempts(self) -> None:
        snapshot = control.Snapshot(True, control.WithdrawalPhase.REJECTED, 100.0, 0, 1, None)
        self.assertEqual(runner.withdrawal_deadline(snapshot, 114.999), 115.0)
        for now in (99.0, 115.0, 119.0, 120.0):
            with self.assertRaises(RuntimeError):
                runner.withdrawal_deadline(snapshot, now)
        attempted = control.Snapshot(True, control.WithdrawalPhase.REJECTED, 100.0, 1, 1, None)
        with self.assertRaises(RuntimeError):
            runner.withdrawal_deadline(attempted, 101.0)

    def test_a_successful_ssh_observation_returning_at_the_boundary_is_late(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(5)"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ) as process,
        ):
            root = Path(temporary)
            binding = services.Binding("dddddddd-dddd-4ddd-8ddd-000000000201", 7, "a" * 64)
            context = runner.BootContext(
                root / "uds",
                services.Boot(binding, "dddddddd-dddd-4ddd-8ddd-000000000202"),
                root,
                root,
                runner.DEFAULT_NETWORK,
                runner.Platform("illumos"),
                process,
                control.Authority(
                    control.Config(root / "ca", "native.fixture.test", frozenset({"127.0.0.1"}))
                ),
            )
            absent = subprocess.CompletedProcess[bytes](
                ["synthetic-observation"], 0, b"700 701\ngroup-absent\n", b""
            )
            with (
                patch.object(runner, "ssh", return_value=absent),
                patch.object(runner.time, "monotonic", side_effect=[114.0, 115.0]),
                self.assertRaisesRegex(RuntimeError, "observation was late"),
            ):
                runner.observe_group(context, 115.0, (700, 701))

    def test_process_observation_accepts_only_the_fixed_login_event(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            subprocess.Popen(
                [sys.executable, "-c", "pass"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ) as process,
        ):
            root = Path(temporary)
            binding = services.Binding("dddddddd-dddd-4ddd-8ddd-000000000201", 7, "a" * 64)
            context = runner.BootContext(
                root / "uds",
                services.Boot(binding, "dddddddd-dddd-4ddd-8ddd-000000000202"),
                root,
                root,
                runner.DEFAULT_NETWORK,
                runner.Platform("illumos"),
                process,
                control.Authority(
                    control.Config(root / "ca", "native.fixture.test", frozenset({"127.0.0.1"}))
                ),
            )
            observed = subprocess.CompletedProcess[bytes](
                ["synthetic-observation"],
                0,
                b"700 701\n700 700 S\n701 700 S\ngroup-present\n",
                runner.SSH_LOGIN_EVENT,
            )
            with patch.object(runner, "ssh", return_value=observed):
                group = runner.observe_group(context, time.monotonic() + 5.0, (700, 701))
                if group is None:
                    raise AssertionError("synthetic group observation was missing")
                self.assertTrue(group.live)
            refused = subprocess.CompletedProcess[bytes](
                observed.args,
                observed.returncode,
                observed.stdout,
                runner.SSH_LOGIN_EVENT + b"unexpected",
            )
            with (
                patch.object(runner, "ssh", return_value=refused),
                self.assertRaisesRegex(RuntimeError, "process observation failed"),
            ):
                runner.observe_group(context, time.monotonic() + 5.0, (700, 701))

    def test_clean_shutdown_requires_zero_status_and_omnios_sync_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            serial = Path(temporary) / "serial.log"
            serial.write_bytes(runner.ILLUMOS_SYNC_MARKER)
            with subprocess.Popen(
                [sys.executable, "-c", "pass"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ) as process:
                runner.wait_clean_shutdown(process, runner.Platform("illumos"), serial)
            with (
                subprocess.Popen(
                    [sys.executable, "-c", "raise SystemExit(2)"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                ) as process,
                self.assertRaisesRegex(RuntimeError, "did not exit cleanly"),
            ):
                runner.wait_clean_shutdown(process, runner.Platform("illumos"), serial)
            serial.write_bytes(b"")
            with (
                subprocess.Popen(
                    [sys.executable, "-c", "pass"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                ) as process,
                self.assertRaisesRegex(RuntimeError, "evidence was incomplete"),
            ):
                runner.wait_clean_shutdown(process, runner.Platform("illumos"), serial)

    def test_clean_shutdown_binds_omnios_evidence_to_the_bounded_serial_log(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            serial = Path(temporary) / "serial.log"
            serial.write_bytes(b"x" * (runner.MAX_SERIAL_VERIFICATION + 1))
            with (
                subprocess.Popen(
                    [sys.executable, "-c", "pass"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                ) as process,
                self.assertRaisesRegex(RuntimeError, "serial log exceeded its bound"),
            ):
                runner.wait_clean_shutdown(process, runner.Platform("illumos"), serial)

    def test_clean_shutdown_does_not_require_omnios_serial_evidence_for_freebsd(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            serial = Path(temporary) / "serial.log"
            serial.write_bytes(b"")
            with subprocess.Popen(
                [sys.executable, "-c", "pass"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ) as process:
                runner.wait_clean_shutdown(process, runner.Platform("freebsd"), serial)

    def test_git_refusal_requires_actual_ownership_error_and_no_success_output(self) -> None:
        ownership = b"fatal: detected dubious ownership in repository at '/synthetic'\n"
        runner.git_ownership_refused(
            subprocess.CompletedProcess[bytes](["git"], 128, b"", ownership)
        )
        for status, stdout, stderr in (
            (0, b"", ownership),
            (128, b"unexpected", ownership),
            (128, b"", b"fatal: unrelated error"),
            (255, b"", b"Permission denied"),
        ):
            with self.assertRaises(RuntimeError):
                runner.git_ownership_refused(
                    subprocess.CompletedProcess[bytes](["git"], status, stdout, stderr)
                )


class NativeServiceApiTest(unittest.TestCase):
    def test_api_mode_is_explicit_and_unix_only(self) -> None:
        vmm, metadata, config = (Path(name) for name in ("vmm", "metadata", "config"))
        self.assertEqual(
            runner.firecracker_arguments(vmm, metadata, config, None),
            [
                "vmm",
                "--enable-pci",
                "--log-path",
                "vmm.log",
                "--no-api",
                "--metadata",
                "metadata",
                "--config-file",
                "config",
            ],
        )
        self.assertEqual(
            runner.firecracker_arguments(vmm, metadata, config, Path("work/api.sock")),
            [
                "vmm",
                "--enable-pci",
                "--log-path",
                "vmm.log",
                "--api-sock",
                "work/api.sock",
                "--metadata",
                "metadata",
                "--config-file",
                "config",
            ],
        )

    def test_cleanup_refuses_regular_files_links_and_directories(self) -> None:
        for kind in ("file", "link", "directory"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "api.sock"
                if kind == "file":
                    path.write_bytes(b"must-survive")
                elif kind == "link":
                    path.symlink_to("missing-target")
                else:
                    path.mkdir()
                with self.assertRaisesRegex(ValueError, "owned Unix socket"):
                    runner.prepare_api_socket(path, None)
                self.assertTrue(path.exists() or path.is_symlink())

    def test_only_stopped_vm_socket_can_be_removed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, socket.socket(socket.AF_UNIX) as stream:
            path = Path(temporary) / "api.sock"
            stream.bind(str(path))
            with subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ) as process:
                try:
                    with self.assertRaisesRegex(RuntimeError, "live native VM"):
                        runner.prepare_api_socket(path, process)
                    self.assertTrue(path.exists())
                    runner.prepare_api_socket(None, process)
                    self.assertTrue(path.exists())
                finally:
                    process.terminate()
                    process.wait(timeout=10)
                runner.prepare_api_socket(path, process)
                self.assertFalse(path.exists())
            runner.prepare_api_socket(path, None)


if __name__ == "__main__":
    unittest.main()
