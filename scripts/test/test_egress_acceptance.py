"""The opt-in live runner must fence fixture mutations and retain failed evidence."""

import json
import subprocess
import sys
import tempfile
import time
import unittest
from dataclasses import asdict
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from egress_acceptance import Acceptance, Fixture, PublicReferenceUnavailable


class EgressAcceptanceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name)
        key = self.path / "identity"
        key.write_text("fixture-not-a-real-key")
        key.chmod(0o600)
        (self.path / "known_hosts").write_text("fixture")
        (self.path / "run.json").write_text(
            json.dumps(
                dict(
                    run="egress-20261002",
                    host="example.invalid",
                    admin_alias="fixture-admin",
                    identity=str(key),
                )
            )
        )
        self.runner = Acceptance(self.path, "test")
        self.fixture = Fixture.parse(
            "nixos",
            dict(
                id="a5a0aed5-e24f-4188-8c44-2c447d7f46e8",
                name="egress-20261002-nixos",
                image_id="sha256:" + "a" * 64,
                profile="oss",
                ssh_host="v-egress-20261002-nixos-a5a0aed5e24f41888c442c447d7f46e8.apps.example.invalid",
                request_id="egress-20261002-nixos-create",
            ),
            self.runner.prefix,
            self.runner.host,
        )
        self.runner.save("vm-nixos.json", asdict(self.fixture))
        self.runner.save(
            "create-nixos.json",
            dict(request_id=self.fixture.request_id, result=asdict(self.fixture)),
        )

    def test_public_get_retries_transient_failure_but_certificate_refusal_fails(self) -> None:
        self.runner.run = Mock(
            side_effect=[
                subprocess.CompletedProcess([], 22, "", "unavailable"),
                subprocess.CompletedProcess([], 0, "validated bytes", ""),
            ]
        )
        with patch("egress_acceptance.time.sleep"):
            self.assertEqual(self.runner.public("https://example.invalid/trust"), "validated bytes")
        self.assertEqual(self.runner.run.call_count, 2)
        self.runner.run = Mock(
            return_value=subprocess.CompletedProcess([], 60, "", "certificate refusal")
        )
        with self.assertRaises(RuntimeError):
            self.runner.public("https://example.invalid/trust")
        self.assertEqual(self.runner.run.call_count, 1)

    def test_pending_job_waits_for_original_receipt_after_route_unavailability(self) -> None:
        self.runner.owned = Mock()
        self.runner.guest = Mock(
            side_effect=[
                subprocess.CompletedProcess([], 0, "acceptance-job-started\n", ""),
                PublicReferenceUnavailable("bounded route refusal"),
                subprocess.CompletedProcess([], 0, "job-exit:0\nverified\n", ""),
                subprocess.CompletedProcess([], 0, "", ""),
            ]
        )
        with patch("egress_acceptance.time.sleep"):
            result = self.runner.guest_job(self.fixture, "echo bounded-test", "receipt")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.runner.owned.call_count, 3)
        self.assertEqual(self.runner.guest.call_count, 4)
        self.assertEqual(self.runner.guest.call_args_list[1], self.runner.guest.call_args_list[2])

    def test_channel_exit_254_cannot_replace_an_atomic_failed_job_receipt(self) -> None:
        self.runner.owned = Mock()
        self.runner.guest = Mock(
            side_effect=[
                subprocess.CompletedProcess([], 0, "acceptance-job-started\n", ""),
                subprocess.CompletedProcess([], 254, "unconfirmed channel", ""),
                subprocess.CompletedProcess([], 0, "job-exit:254\nclosed failure\n", ""),
                subprocess.CompletedProcess([], 0, "", ""),
            ]
        )
        with patch("egress_acceptance.time.sleep"):
            result = self.runner.guest_job(self.fixture, "echo bounded-test", "receipt")
        self.assertEqual(result.returncode, 254)
        self.assertEqual(self.runner.owned.call_count, 3)
        self.assertEqual(self.runner.guest.call_args_list[1], self.runner.guest.call_args_list[2])

    def test_cleanup_retry_reuses_completed_receipt_without_relaunch(self) -> None:
        self.runner.owned = Mock()
        self.runner.guest = Mock(
            side_effect=[
                subprocess.CompletedProcess([], 0, "acceptance-job-started\n", ""),
                subprocess.CompletedProcess([], 0, "job-exit:0\nverified\n", ""),
                subprocess.CompletedProcess([], 255, "", "closed channel"),
                subprocess.CompletedProcess([], 0, "", ""),
            ]
        )
        with patch("egress_acceptance.time.sleep"):
            self.assertEqual(
                self.runner.guest_job(self.fixture, "echo bounded-test", "receipt").returncode, 0
            )
        self.assertEqual(self.runner.guest.call_args_list[2], self.runner.guest.call_args_list[3])
        self.runner.guest = Mock(return_value=subprocess.CompletedProcess([], 0, "", ""))
        self.assertEqual(
            self.runner.guest_job(self.fixture, "echo bounded-test", "receipt").returncode, 0
        )
        self.assertEqual(self.runner.guest.call_count, 1)
        self.assertTrue(self.runner.guest.call_args.args[1].startswith("rm -rf -- "))
        with self.assertRaises(ValueError):
            self.runner.guest_job(self.fixture, "echo changed-script", "receipt")

    def test_artifact_reference_streams_and_rejects_size_or_deadline_overflow(self) -> None:
        for minimum, maximum, clock, rejected in (
            (3, 4, [0, 1, 2], False),
            (5, 8, [0, 1, 2], True),
            (1, 3, [0, 1, 2], True),
            (1, 8, [0, 1201], True),
        ):
            response = Mock()
            response.geturl.return_value = "https://example.invalid/public"
            response.read.side_effect = [b"ab", b"cd", b""]
            context = Mock()
            context.__enter__ = Mock(return_value=response)
            context.__exit__ = Mock(return_value=False)
            with (
                patch("egress_acceptance.urllib.request.urlopen", return_value=context),
                patch("egress_acceptance.time.monotonic", side_effect=clock),
            ):
                if rejected:
                    with self.assertRaises(ValueError):
                        Acceptance.artifact_reference(
                            "https://example.invalid/public", minimum, maximum
                        )
                else:
                    record = Acceptance.artifact_reference(
                        "https://example.invalid/public", minimum, maximum
                    )
                    self.assertEqual(record["bytes"], 4)
                    self.assertEqual(
                        record["sha256"],
                        "88d4266fd4e6338d13b845fcf289579d209c897823b9217da3e161936f031589",
                    )
            self.assertTrue(all(call.args == (65536,) for call in response.read.call_args_list))

    def test_large_reference_change_fails_before_guest_access(self) -> None:
        self.runner.save(
            "test-large-reference.json",
            dict(url="https://example.invalid/old", bytes=4, sha256="a" * 64),
        )
        self.runner.artifact_reference = Mock(
            return_value=dict(url="https://example.invalid/new", bytes=4, sha256="b" * 64)
        )
        self.runner.owned = Mock()
        with self.assertRaises(ValueError):
            self.runner.large_artifact("https://example.invalid/new", 1, 8, 300, 900)
        self.runner.owned.assert_not_called()

    def test_guest_job_refuses_unbounded_timeout_before_guest_access(self) -> None:
        self.runner.owned = Mock()
        for timeout in (0, 59, 3601, True):
            with self.assertRaises(ValueError):
                self.runner.guest_job(self.fixture, "echo bounded-test", "receipt", timeout)
        self.runner.owned.assert_not_called()

    def test_guest_job_rejects_malformed_or_out_of_range_receipt_without_cleanup(self) -> None:
        for receipt in ("job-exit:256\n", "job-exit:garbage\n", "untrusted completion\n"):
            self.runner.owned = Mock()
            guest = Mock(
                side_effect=[
                    subprocess.CompletedProcess([], 0, "acceptance-job-started\n", ""),
                    subprocess.CompletedProcess([], 0, receipt, ""),
                ]
            )
            self.runner.guest = guest
            with self.assertRaises(ValueError):
                self.runner.guest_job(self.fixture, "echo bounded-test", "receipt")
            self.runner.owned.assert_called_once_with(self.fixture)
            self.assertEqual(guest.call_count, 2)

    def test_guest_job_retains_failed_exit_and_output_before_own_path_cleanup(self) -> None:
        self.runner.owned = Mock()
        guest = Mock(
            side_effect=[
                subprocess.CompletedProcess([], 0, "acceptance-job-started\n", ""),
                subprocess.CompletedProcess([], 0, "job-exit:23\nclosed fixture failure\n", ""),
                subprocess.CompletedProcess([], 0, "", ""),
            ]
        )
        self.runner.guest = guest
        result = self.runner.guest_job(self.fixture, "echo bounded-test", "receipt")
        self.assertEqual(result.returncode, 23)
        record = json.loads((self.path / "test-nixos-receipt-job.json").read_text())
        self.assertEqual(record["exit"], 23)
        self.assertEqual(record["output"], "closed fixture failure")
        self.assertTrue(guest.call_args.args[1].startswith("rm -rf -- /tmp/overalls-egress-job-"))

    def test_guest_job_replays_exact_launch_after_retained_transport_failure(self) -> None:
        self.runner.owned = Mock()
        guest = Mock(
            side_effect=[
                subprocess.CompletedProcess([], 255, "", "closed transport"),
                subprocess.CompletedProcess([], 0, "acceptance-job-started\n", ""),
                subprocess.CompletedProcess([], 0, "job-exit:0\nverified\n", ""),
                subprocess.CompletedProcess([], 0, "", ""),
            ]
        )
        self.runner.guest = guest
        with patch("egress_acceptance.time.sleep"):
            result = self.runner.guest_job(self.fixture, "echo bounded-test", "receipt")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(guest.call_args_list[0], guest.call_args_list[1])
        self.assertEqual(self.runner.owned.call_count, 3)

    def test_archive_reuse_requires_current_attributed_exact_size_request_window(self) -> None:
        owner = "c8691877-0a73-4a27-b811-3a3b39f4d0ea"
        self.runner.save("account.json", dict(id=owner))
        self.runner.command = Mock(return_value=dict(result=dict(generation=3)))
        row = dict(
            vm_id=self.fixture.id,
            owner_id=owner,
            generation=3,
            attribution="resolved",
            protocol="https",
            reason="ok",
            status=200,
            bytes_sent=4096,
            cache="hit",
        )
        for change in (
            dict(owner_id="foreign"),
            dict(generation=2),
            dict(bytes_sent=2048),
            dict(attribution="unresolved"),
            dict(cache="bypass"),
        ):
            rows = [row | change, row | change]
            self.runner.run = Mock(
                return_value=subprocess.CompletedProcess(
                    [], 0, "\n".join(json.dumps(value) for value in rows), ""
                )
            )
            with self.assertRaises(RuntimeError):
                self.runner.archive_rows(self.fixture, "2026-10-02T00:00:00Z", 4096)
        rows = [row | dict(cache="miss"), row]
        self.runner.run = Mock(
            return_value=subprocess.CompletedProcess(
                [], 0, "\n".join(json.dumps(value) for value in rows), ""
            )
        )
        self.assertEqual(self.runner.archive_rows(self.fixture, "2026-10-02T00:00:00Z", 4096), rows)
        self.assertIn("--since 2026-10-02T00:00:00Z", self.runner.run.call_args.args[1][-1])

    def test_changed_ownership_identity_or_shape_prevents_mutation(self) -> None:
        for changed in [
            dict(owner=False),
            dict(name="unrelated"),
            dict(image_id="sha256:" + "b" * 64),
            dict(profile="customer"),
        ]:
            command = Mock(
                return_value=dict(result=asdict(self.fixture) | dict(owner=True) | changed)
            )
            self.runner.command = command
            with self.assertRaises(ValueError):
                self.runner.lifecycle("rm", "nixos")
            self.assertEqual(command.call_count, 1)
            self.assertTrue(command.call_args.args[0].startswith("show "))
            self.assertFalse((self.path / "test-nixos-rm-intent.json").exists())

    def test_fixture_prefix_alone_does_not_authorize_deletion(self) -> None:
        self.runner.save(
            "create-nixos.json", dict(request_id="foreign", result=asdict(self.fixture))
        )
        command = Mock()
        self.runner.command = command
        with self.assertRaises(ValueError):
            self.runner.lifecycle("rm", "nixos")
        command.assert_not_called()

    def test_cleanup_resume_reads_admitted_request_without_new_mutation(self) -> None:
        request = self.runner.prefix + "-nixos-test-rm"
        self.runner.save(
            "test-nixos-rm.json", dict(request_id=request, result=dict(id=self.fixture.id))
        )
        command = Mock(
            return_value=dict(
                status="succeeded",
                request_id=request,
                result=dict(id=self.fixture.id, outcome="deleted"),
            )
        )
        self.runner.command = command
        self.runner.lifecycle("rm", "nixos")
        self.runner.lifecycle("rm", "nixos")
        command.assert_called_once_with("request show " + request + " --json")

    def test_foreign_completed_receipt_is_not_a_success(self) -> None:
        self.runner.save(
            "test-nixos-rm-completed.json",
            dict(status="succeeded", request_id="foreign", result=dict(id=self.fixture.id)),
        )
        with self.assertRaises(ValueError):
            self.runner.lifecycle("rm", "nixos")

    def test_transport_error_and_empty_json_never_pass(self) -> None:
        for code, output in [(255, ""), (0, ""), (0, '{"status":"failed"}')]:
            self.runner.run = Mock(return_value=subprocess.CompletedProcess([], code, output, ""))
            with self.assertRaises((RuntimeError, ValueError, IndexError)):
                self.runner.command("whoami --json")

    def test_both_approval_streams_are_redacted_and_failure_retained(self) -> None:
        outcome = self.runner.run(
            "redaction",
            [
                sys.executable,
                "-c",
                "import sys; print('https://example.invalid/ssh/approve/SECRET'); print('https://example.invalid/approve/SECRET', file=sys.stderr); sys.exit(1)",
            ],
        )
        self.assertEqual(outcome.returncode, 1)
        self.assertNotIn("SECRET", outcome.stdout + outcome.stderr)
        # Arguments are fixed probe definitions, never secrets. The synthetic
        # test argument remains in argv; neither captured stream contains it.
        evidence = json.loads((self.path / "commands.jsonl").read_text())
        self.assertNotIn("SECRET", evidence["stdout"] + evidence["stderr"])
        self.assertEqual(evidence["exit"], 1)

    def test_timeout_closes_descendant_pipes_and_retains_attempt(self) -> None:
        started = time.monotonic()
        command = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)']); print('started',flush=True); time.sleep(30)"
        with self.assertRaises(TimeoutError):
            self.runner.run("timeout", [sys.executable, "-c", command], timeout=1)
        self.assertLess(time.monotonic() - started, 5)
        evidence = json.loads((self.path / "commands.jsonl").read_text())
        self.assertTrue(evidence["timeout"])
        self.assertNotEqual(evidence["exit"], 0)
        self.assertIn("started", evidence["stdout"])


if __name__ == "__main__":
    unittest.main()
