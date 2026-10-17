"""Validate untrusted process snapshots before privileged failure injection."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import native_control as control
import native_recovery as recovery
import native_service_runner as runner
import native_services as services


class SnapshotTest(unittest.TestCase):
    def test_ssh_command_requires_exact_production_login_event(self) -> None:
        result = subprocess.CompletedProcess(
            ["ssh"], 0, stdout=b"fixed-output", stderr=recovery.SSH_LOGIN_EVENT
        )
        self.assertEqual(recovery.command_output(result), b"fixed-output")
        for stderr in (
            b"",
            recovery.SSH_LOGIN_EVENT * 2,
            recovery.SSH_LOGIN_EVENT.replace(b"\n", b"\r\n"),
            recovery.SSH_LOGIN_EVENT.replace(b"login_recorded", b"login_denied"),
            recovery.SSH_LOGIN_EVENT + b"unexpected diagnostic\n",
        ):
            with self.subTest(stderr=stderr), self.assertRaises(services.ProtocolError):
                recovery.command_output(subprocess.CompletedProcess(["ssh"], 0, b"", stderr))
        with self.assertRaises(services.ProtocolError):
            recovery.command_output(
                subprocess.CompletedProcess(["ssh"], 1, b"", recovery.SSH_LOGIN_EVENT)
            )

    def test_only_exact_published_executable_modes_enter_root_commands(self) -> None:
        for mode in ("0555", "0755"):
            with self.subTest(mode=mode):
                parsed = recovery.snapshot(f"{mode}\n123\n{'a' * 64}\n".encode("ascii"))
                self.assertEqual(parsed.pid, 123)
                self.assertEqual(parsed.mode, mode)
                self.assertEqual(parsed.digest, "a" * 64)

    def test_malformed_or_coercible_process_data_refuses(self) -> None:
        for mode, pid, digest in (
            ("4755", "123", "a" * 64),
            ("755", "123", "a" * 64),
            ("0755", "01", "a" * 64),
            ("0755", "1", "a" * 64),
            ("0755", "-2", "a" * 64),
            ("0755", "2147483648", "a" * 64),
            ("0755", "123;id", "a" * 64),
            ("0755", "123", "A" * 64),
            ("0755", "123", "a" * 63),
        ):
            with self.subTest(mode=mode, pid=pid), self.assertRaises(services.ProtocolError):
                recovery.snapshot(f"{mode}\n{pid}\n{digest}\n".encode("ascii"))
        for body in (
            b"",
            b"x" * 129,
            b"\xff",
            b"0755\n123\n" + b"a" * 64,
            b"0755\r\n123\r\n" + b"a" * 64 + b"\r\n",
        ):
            with self.subTest(body=body), self.assertRaises(services.ProtocolError):
                recovery.snapshot(body)

    def test_failed_observation_restores_saved_mode_and_publishes_no_receipt(self) -> None:
        """Exercise host cleanup only; mocked channels establish no native evidence."""
        boot = services.Boot(
            services.Binding("11111111-1111-4111-8111-111111111111", 1, "a" * 64),
            "22222222-2222-4222-8222-222222222222",
        )
        for mode in ("0555", "0755"):
            for failure in ("injection", "observation"):
                before = recovery.snapshot(f"{mode}\n123\n{'b' * 64}\n".encode("ascii"))
                with (
                    self.subTest(mode=mode, failure=failure),
                    tempfile.TemporaryDirectory() as temporary,
                    subprocess.Popen(
                        [sys.executable, "-c", "pass"], stdout=subprocess.PIPE
                    ) as process,
                ):
                    work = Path(temporary)
                    context = runner.BootContext(
                        work / "vsock.sock",
                        boot,
                        work / "fixture",
                        work,
                        runner.DEFAULT_NETWORK,
                        runner.Platform("freebsd"),
                        process,
                        control.Authority(
                            control.Config(
                                work / "ca", "recovery.fixture.test", frozenset({"127.0.0.1"})
                            )
                        ),
                    )
                    injection = (
                        services.ProtocolError("injected failure")
                        if failure == "injection"
                        else None
                    )
                    observation = (
                        services.ProtocolError("observation failure")
                        if failure == "observation"
                        else None
                    )
                    with (
                        patch.object(runner, "alive"),
                        patch.object(services, "readiness", return_value=boot),
                        patch.object(services, "flush"),
                        patch.object(recovery, "process_snapshot", return_value=before),
                        patch.object(recovery, "fail_daemon", side_effect=injection),
                        patch.object(services, "readiness_withheld", side_effect=observation),
                        patch.object(recovery, "restore") as restored,
                        patch.object(runner, "wait_readiness") as waited,
                        self.assertRaises(services.ProtocolError),
                    ):
                        recovery.verify(context)
                    restored.assert_called_once_with(context, before)
                    waited.assert_not_called()
                    self.assertEqual(list(work.glob("recovery-*/receipt.json")), [])


if __name__ == "__main__":
    unittest.main()
