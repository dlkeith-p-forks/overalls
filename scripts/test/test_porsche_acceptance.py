"""Live acceptance must not mutate unrelated resources or count transport errors as passes."""

import json
import shlex
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from porsche_acceptance import (
    GUEST_OSES,
    IMAGE_NAMES,
    SSH_LOGIN_EVENT,
    SSH_WINDOWS_PQ_WARNING,
    Acceptance,
    CommandOutcome,
    GuestOS,
    MatrixConfig,
    MatrixFixture,
)


class AcceptanceSafetyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        (self.path / "run.json").write_text(
            json.dumps(
                {
                    "run": "porsche-20260918-012013",
                    "host": "example.invalid",
                    "account": "test@example.invalid",
                }
            )
        )
        self.runner = Acceptance(self.path)
        self.receipt: CommandOutcome = {
            "request_id": "porsche-20260918-012013-create-001",
            "result": {
                "id": "a5a0aed5-e24f-4188-8c44-2c447d7f46e8",
                "name": "porsche-20260918-012013-001",
            },
        }

    def test_changed_name_or_owner_prevents_deletion(self) -> None:
        for changes in [{"owner": False}, {"name": "unrelated"}]:
            machine = dict(self.receipt["result"], owner=True) | changes
            self.runner.command = Mock(return_value={"result": machine})
            self.runner.admit = Mock()
            with self.assertRaises(AssertionError):
                self.runner.lifecycle(self.receipt, "rm", "cleanup")
            self.runner.admit.assert_not_called()

    def test_generated_name_requires_a_matching_durable_receipt(self) -> None:
        receipt: CommandOutcome = {
            "request_id": self.runner.prefix + "-generated",
            "result": {"id": self.receipt["result"]["id"], "name": "vm-generated"},
        }
        self.runner.command = Mock(return_value={"result": dict(receipt["result"], owner=True)})
        with self.assertRaises(FileNotFoundError):
            self.runner.owned(receipt)
        self.runner.save("generated.json", receipt)
        self.assertEqual(self.runner.owned(receipt)["id"], receipt["result"]["id"])

    def test_sharing_is_never_submitted(self) -> None:
        with patch("porsche_acceptance.subprocess.Popen") as popen:
            for command in ["share add vm user viewer", "share show vm", "share remove vm user"]:
                with self.assertRaises(ValueError):
                    self.runner.command(command)
            popen.assert_not_called()

    def test_transport_failure_is_not_expected_rejection(self) -> None:
        process = Mock(returncode=255)
        process.communicate.return_value = ("", "connection failed")
        with (
            patch("porsche_acceptance.subprocess.Popen", return_value=process),
            self.assertRaises(AssertionError),
        ):
            self.runner.command("show missing --json", expect=1)

    def test_approval_urls_are_not_persisted(self) -> None:
        process = Mock(returncode=3)
        process.communicate.return_value = (
            json.dumps(
                {
                    "status": "approval_required",
                    "approval_url": "https://example.invalid/ssh/approve/SECRET",
                }
            ),
            "",
        )
        with patch("porsche_acceptance.subprocess.Popen", return_value=process):
            self.runner.command("whoami --json", expect=1)
        self.assertNotIn("SECRET", (self.path / "commands.jsonl").read_text())

    def test_admission_retries_preserve_exact_command(self) -> None:
        self.runner.command = Mock(side_effect=[{"error": "conflict"}, {"status": "accepted"}])
        command = "new --name fixture --request-id stable --json"
        with patch("porsche_acceptance.time.sleep"):
            self.runner.admit(command)
        self.assertEqual(
            [call.args[0] for call in self.runner.command.call_args_list], [command, command]
        )


class MatrixSafetyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.prefix = "porsche-20261018-123456"
        self.host = "example.invalid"
        (self.path / "run.json").write_text(
            json.dumps(dict(run=self.prefix, host=self.host, account="test@example.invalid"))
        )
        self.runner = Acceptance(self.path)
        for filename in ("overalls", "ssh_config", "known_hosts", "primary"):
            path = self.path / filename
            path.write_text("isolated fixture")
            path.chmod(0o700 if filename == "overalls" else 0o600)
        self.images: dict[GuestOS, str] = {
            kind: "sha256:" + f"{number:064x}" for number, kind in enumerate(GUEST_OSES, 1)
        }
        self.runner.save(
            "matrix.json",
            dict(
                cli=str(self.path / "overalls"),
                ssh_config=str(self.path / "ssh_config"),
                known_hosts=str(self.path / "known_hosts"),
                images=self.images,
            ),
        )

    def receipt(self, kind: GuestOS = "freebsd") -> CommandOutcome:
        identifier = str(uuid.uuid4())
        name = self.prefix + "-" + kind
        label = "v-" + name[:22].rstrip("-") + "-" + identifier.replace("-", "")
        image = self.images[kind]
        assert image is not None
        return {
            "status": "succeeded",
            "request_id": name + "-create",
            "result": dict(
                id=identifier,
                name=name,
                image_id=image,
                profile="oss",
                outcome="running",
                ssh_host=label + ".apps." + self.host,
            ),
        }

    def fixture(self, receipt: object, kind: GuestOS = "freebsd") -> MatrixFixture:
        return MatrixFixture.parse(kind, receipt, self.prefix, self.host, self.images[kind])

    def catalog(self) -> CommandOutcome:
        return {
            "result": {
                "images": [
                    dict(id=self.images[kind], name=IMAGE_NAMES[kind]) for kind in GUEST_OSES
                ]
            }
        }

    def test_configuration_requires_seven_explicit_distinct_image_pins(self) -> None:
        config: dict[str, object] = json.loads((self.path / "matrix.json").read_text())
        self.assertEqual(set(MatrixConfig.parse(config).images), set(GUEST_OSES))
        for images in (
            {kind: value for kind, value in self.images.items() if kind != "omnios"},
            {**self.images, "freebsd": self.images["nixos"]},
            {**self.images, "omnios": "latest"},
        ):
            with self.assertRaises(ValueError):
                MatrixConfig.parse(dict(config, images=images))

    def test_unavailable_omnios_fails_full_preflight_before_any_create(self) -> None:
        config: dict[str, object] = json.loads((self.path / "matrix.json").read_text())
        self.runner.save("matrix.json", dict(config, images={**self.images, "omnios": None}))
        self.runner.command = Mock(
            side_effect=[{"result": {"email": "test@example.invalid"}}, self.catalog()]
        )
        self.runner.admit = Mock()
        with self.assertRaises(RuntimeError):
            self.runner.matrix_create(GUEST_OSES)
        self.runner.admit.assert_not_called()
        evidence = json.loads((self.path / "matrix-inventory.json").read_text())
        self.assertEqual(evidence["selected"], list(GUEST_OSES))
        self.assertFalse(
            next(row for row in evidence["images"] if row["os"] == "omnios")["available"]
        )
        self.assertEqual(list(self.path.glob("matrix-intent-*.json")), [])

    def test_explicit_subset_still_requires_exact_catalog_names(self) -> None:
        catalog = self.catalog()
        catalog["result"]["images"][0]["name"] = "An unrelated Linux"
        self.runner.command = Mock(
            side_effect=[{"result": {"email": "test@example.invalid"}}, catalog]
        )
        with self.assertRaises(RuntimeError):
            self.runner.matrix_inventory(("nixos",))
        self.assertEqual(
            json.loads((self.path / "matrix-inventory.json").read_text())["selected"], ["nixos"]
        )

    def test_create_resume_preserves_uuid_and_does_not_resubmit(self) -> None:
        receipt = self.receipt()
        self.runner.save("matrix-vm-freebsd.json", receipt)
        self.runner.matrix_inventory = Mock()
        self.runner.matrix_poll = Mock(return_value=receipt)
        self.runner.matrix_owned = Mock()
        self.runner.admit = Mock()
        self.runner.matrix_create(("freebsd",))
        self.runner.admit.assert_not_called()
        self.runner.matrix_poll.assert_called_once_with(receipt["request_id"])
        changed = self.receipt()
        self.runner.matrix_poll = Mock(return_value=changed)
        with self.assertRaises(ValueError):
            self.runner.matrix_create(("freebsd",))
        self.assertEqual(json.loads((self.path / "matrix-vm-freebsd.json").read_text()), receipt)

    def test_failed_create_retains_uuid_before_failure_and_allows_owned_cleanup(self) -> None:
        receipt = self.receipt()
        accepted: CommandOutcome = dict(
            status="accepted", request_id=receipt["request_id"], result=receipt["result"]
        )
        failure_result = receipt["result"].copy()
        failure_result.update(outcome="failed", reason="execution_failed")
        failed: CommandOutcome = dict(
            status="failed",
            request_id=receipt["request_id"],
            result=failure_result,
        )
        self.runner.matrix_inventory = Mock()
        self.runner.admit = Mock(return_value=accepted)
        self.runner.matrix_poll = Mock(return_value=failed)
        with self.assertRaisesRegex(
            RuntimeError, "original VM .* retained for reconciliation/cleanup"
        ):
            self.runner.matrix_create(("freebsd",))
        self.assertEqual(json.loads((self.path / "matrix-vm-freebsd.json").read_text()), failed)
        fixture = self.runner.matrix_fixture("freebsd", self.runner.matrix_config())
        self.assertEqual(fixture.id, receipt["result"]["id"])
        self.runner.admit.reset_mock()
        with self.assertRaises(RuntimeError):
            self.runner.matrix_create(("freebsd",))
        self.runner.admit.assert_not_called()
        self.runner.matrix_owned = Mock()
        request = f"{self.prefix}-matrix-cleanup-{fixture.id}"
        self.runner.matrix_poll = Mock(
            return_value=dict(
                status="succeeded",
                request_id=request,
                result=dict(id=fixture.id, name=fixture.name, outcome="deleted"),
            )
        )
        self.runner.matrix_lifecycle(("freebsd",), "rm", "cleanup")
        self.runner.matrix_owned.assert_called_once_with(fixture)
        self.assertIn(
            f"rm {fixture.id} --request-id {request}", self.runner.admit.call_args.args[0]
        )

    def test_existing_admission_without_vm_ledger_is_recovered_without_resubmission(self) -> None:
        receipt = self.receipt()
        accepted: CommandOutcome = dict(
            status="accepted", request_id=receipt["request_id"], result=receipt["result"]
        )
        failure_result = receipt["result"].copy()
        failure_result.update(outcome="failed", reason="execution_failed")
        failed: CommandOutcome = dict(
            status="failed",
            request_id=receipt["request_id"],
            result=failure_result,
        )
        self.runner.save("matrix-admission-freebsd.json", accepted)
        self.runner.matrix_inventory = Mock()
        self.runner.matrix_poll = Mock(return_value=failed)
        self.runner.admit = Mock()
        with self.assertRaises(RuntimeError):
            self.runner.matrix_create(("freebsd",))
        self.runner.admit.assert_not_called()
        self.assertEqual(json.loads((self.path / "matrix-vm-freebsd.json").read_text()), failed)

    def test_timeout_after_admission_preserves_accepted_fixture_uuid(self) -> None:
        receipt = self.receipt()
        accepted: CommandOutcome = dict(
            status="accepted", request_id=receipt["request_id"], result=receipt["result"]
        )
        self.runner.matrix_inventory = Mock()
        self.runner.admit = Mock(return_value=accepted)
        self.runner.matrix_poll = Mock(side_effect=TimeoutError("fixture deadline"))
        with self.assertRaises(TimeoutError):
            self.runner.matrix_create(("freebsd",))
        self.assertEqual(json.loads((self.path / "matrix-vm-freebsd.json").read_text()), accepted)
        self.assertEqual(
            self.runner.matrix_fixture("freebsd", self.runner.matrix_config()).id,
            receipt["result"]["id"],
        )

    def test_terminal_failure_polling_validates_exit_status_and_never_accepts_transport_failure(
        self,
    ) -> None:
        request = self.prefix + "-matrix-test"
        failed = dict(status="failed", request_id=request, result=dict(outcome="failed"))
        for status, payload, valid in (
            (1, failed, True),
            (0, failed, False),
            (255, failed, False),
            (-9, failed, False),
            (1, dict(status="succeeded", request_id=request), False),
        ):
            process = Mock(returncode=status)
            process.communicate.return_value = (json.dumps(payload), "")
            with patch("porsche_acceptance.subprocess.Popen", return_value=process):
                if valid:
                    self.assertEqual(self.runner.matrix_poll(request), failed)
                else:
                    with self.assertRaises(RuntimeError):
                        self.runner.matrix_poll(request)

    def test_fixture_ledger_rejects_foreign_or_substituted_bindings(self) -> None:
        receipt = self.receipt()
        fixture = self.fixture(receipt)
        self.assertEqual(fixture.id, receipt["result"]["id"])
        for changes in (
            dict(id="foreign"),
            dict(name="unrelated"),
            dict(image_id=self.images["nixos"]),
            dict(ssh_host="attacker.invalid"),
            dict(profile="customer"),
            dict(outcome="failed"),
        ):
            changed = dict(receipt, result=dict(receipt["result"]) | changes)
            with self.assertRaises(ValueError):
                self.fixture(changed)
        with self.assertRaises(ValueError):
            self.fixture(dict(receipt, request_id=self.prefix + "-other-create"))

    def test_current_binding_changes_refuse_before_lifecycle_submission(self) -> None:
        receipt = self.receipt()
        self.runner.save("matrix-vm-freebsd.json", receipt)
        for changes in (
            dict(owner=False),
            dict(name="unrelated"),
            dict(id=str(uuid.uuid4())),
            dict(image_id=self.images["ubuntu"]),
            dict(ssh_host="attacker.invalid"),
        ):
            self.runner.command = Mock(
                return_value={"result": dict(receipt["result"], owner=True) | changes}
            )
            self.runner.admit = Mock()
            with self.assertRaises(ValueError):
                self.runner.matrix_lifecycle(("freebsd",), "rm", "cleanup")
            self.runner.admit.assert_not_called()
            self.assertFalse((self.path / "matrix-cleanup-freebsd-intent.json").exists())

    def test_interrupted_deletion_reconciles_original_receipt_without_show_or_readmission(
        self,
    ) -> None:
        receipt = self.receipt()
        fixture = self.fixture(receipt)
        self.runner.save("matrix-vm-freebsd.json", receipt)
        request = f"{self.prefix}-matrix-cleanup-{fixture.id}"
        self.runner.save(
            "matrix-cleanup-freebsd-intent.json",
            dict(
                command=f"rm {fixture.id} --request-id {request} --no-wait --json",
                request_id=request,
            ),
        )
        self.runner.matrix_owned = Mock()
        self.runner.admit = Mock()
        self.runner.matrix_poll = Mock(
            return_value={
                "status": "succeeded",
                "request_id": request,
                "result": dict(id=fixture.id, name=fixture.name, outcome="deleted"),
            }
        )
        self.runner.matrix_lifecycle(("freebsd",), "rm", "cleanup")
        self.runner.matrix_owned.assert_not_called()
        self.runner.admit.assert_not_called()
        self.runner.matrix_poll.assert_called_once_with(request)

    def test_polling_is_bounded_and_refuses_receipt_substitution(self) -> None:
        request = self.prefix + "-matrix-test"
        self.runner.command = Mock(
            side_effect=[
                dict(request_id=request, status="accepted"),
                dict(request_id=request, status="succeeded"),
            ]
        )
        with (
            patch("porsche_acceptance.time.monotonic", side_effect=[10, 10, 10.5, 10.5, 12, 12.5]),
            patch("porsche_acceptance.time.sleep") as sleep,
        ):
            self.runner.matrix_poll(request, seconds=3)
        self.assertEqual(
            [call.kwargs["timeout"] for call in self.runner.command.call_args_list], [3, 1]
        )
        sleep.assert_called_once_with(2)
        self.runner.command = Mock(return_value=dict(request_id="foreign", status="succeeded"))
        with self.assertRaises(ValueError):
            self.runner.matrix_poll(request)
        for seconds in (0, 2401, True):
            with self.assertRaises(ValueError):
                self.runner.matrix_poll(request, seconds=seconds)

    def test_os_oracle_distinguishes_all_seven_families_and_rejects_generic_linux(self) -> None:
        outputs: dict[GuestOS, str] = {
            "nixos": "kernel=Linux\ndistribution=nixos\n",
            "ubuntu": "kernel=Linux\ndistribution=ubuntu\n",
            "arch": "kernel=Linux\ndistribution=arch\n",
            "almalinux": "kernel=Linux\ndistribution=almalinux\n",
            "freebsd": "kernel=FreeBSD\nrelease=14.3-RELEASE-p16\n",
            "omnios": "SunOS\nOmniOS r151050\n",
            "windows": json.dumps(
                dict(
                    family="Win32NT",
                    caption="Microsoft Windows Server 2025 Standard Evaluation",
                    build="26100",
                )
            ),
        }
        for kind, output in outputs.items():
            self.runner.matrix_verify_os(kind, output)
            with self.assertRaises((ValueError, json.JSONDecodeError)):
                self.runner.matrix_verify_os(kind, "Linux\n")
            for other, substituted in outputs.items():
                if other != kind:
                    with self.assertRaises((ValueError, json.JSONDecodeError)):
                        self.runner.matrix_verify_os(kind, substituted)

    def test_omnios_probe_normalizes_real_v11_release_and_refuses_other_revisions(self) -> None:
        release = self.path / "release"
        for label, accepted in (
            ("OmniOS v11 r151050 (stable)", True),
            ("OmniOS v11 r151048 (stable)", False),
            ("OmniOS v12 r151050", False),
            ("OpenIndiana v11 r151050", False),
            ("unidentified release", False),
        ):
            with self.subTest(label=label):
                release.write_text(label + "\n")
                command = shlex.split(self.runner.matrix_probe("omnios"))
                command[2] = (
                    command[2]
                    .replace("uname -s", "printf '%s\\n' SunOS")
                    .replace("/etc/release", shlex.quote(str(release)))
                )
                process = subprocess.run(command, check=True, capture_output=True, text=True)
                self.assertEqual(process.stderr, "")
                if accepted:
                    self.runner.matrix_verify_os("omnios", process.stdout)
                else:
                    with self.assertRaises(ValueError):
                        self.runner.matrix_verify_os("omnios", process.stdout)

    def test_guest_probe_uses_overalls_cli_strict_trust_and_digest_only_evidence(self) -> None:
        receipt = self.receipt()
        fixture = self.fixture(receipt)
        self.runner.save("matrix-vm-freebsd.json", receipt)
        self.runner.command = Mock(
            return_value={"result": dict(email="test@example.invalid", guest_username="u200000")}
        )
        self.runner.matrix_owned = Mock(
            return_value=dict(observed_state="running", desired_state="running")
        )
        process = Mock(returncode=0)
        process.communicate.return_value = (
            "kernel=FreeBSD\nrelease=14.3-RELEASE-p16\n",
            SSH_LOGIN_EVENT,
        )
        with patch("porsche_acceptance.subprocess.Popen", return_value=process) as popen:
            self.runner.matrix_ssh(("freebsd",))
        argv = popen.call_args.args[0]
        self.assertEqual(argv[:2], [str(self.path / "overalls"), "ssh"])
        self.assertIn("StrictHostKeyChecking=yes", argv)
        self.assertIn("u200000@" + fixture.ssh_host, argv)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        record = json.loads((self.path / "matrix-ssh-initial-freebsd.json").read_text())
        self.assertTrue(record["verified"])
        self.assertNotIn("stdout", record)
        self.assertNotIn("stderr", record)
        self.assertNotIn("argv", record)
        self.assertEqual(len(record["stdout_sha256"]), 64)

    def test_guest_transport_failure_retains_attempt_without_success_or_payload(self) -> None:
        self.runner.save("matrix-vm-freebsd.json", self.receipt())
        self.runner.command = Mock(
            return_value={"result": dict(email="test@example.invalid", guest_username="u200000")}
        )
        self.runner.matrix_owned = Mock(
            return_value=dict(observed_state="running", desired_state="running")
        )
        process = Mock(returncode=255)
        process.communicate.return_value = ("private-output-MARKER", "transport-MARKER")
        with (
            patch("porsche_acceptance.subprocess.Popen", return_value=process),
            self.assertRaises(RuntimeError),
        ):
            self.runner.matrix_ssh(("freebsd",))
        attempts = list(self.path.glob("matrix-ssh-initial-freebsd-attempt-*.json"))
        self.assertEqual(len(attempts), 1)
        self.assertNotIn("MARKER", attempts[0].read_text())
        self.assertFalse(
            json.loads((self.path / "matrix-ssh-initial-freebsd.json").read_text())["verified"]
        )

    def test_guest_timeout_kills_only_the_probe_session_and_clears_previous_success(self) -> None:
        self.runner.save("matrix-vm-freebsd.json", self.receipt())
        self.runner.save("matrix-ssh-initial-freebsd.json", dict(verified=True))
        self.runner.command = Mock(
            return_value={"result": dict(email="test@example.invalid", guest_username="u200000")}
        )
        self.runner.matrix_owned = Mock(
            return_value=dict(observed_state="running", desired_state="running")
        )
        process = Mock(returncode=-9, pid=12345)
        process.communicate.side_effect = [subprocess.TimeoutExpired("probe", 120), ("", "")]
        with (
            patch("porsche_acceptance.subprocess.Popen", return_value=process),
            patch("porsche_acceptance.os.killpg") as kill,
            self.assertRaises(RuntimeError),
        ):
            self.runner.matrix_ssh(("freebsd",))
        kill.assert_called_once_with(12345, 9)
        evidence = json.loads((self.path / "matrix-ssh-initial-freebsd.json").read_text())
        self.assertTrue(evidence["timeout"])
        self.assertFalse(evidence["verified"])

    def test_successful_exit_with_unexpected_stderr_does_not_pass(self) -> None:
        self.runner.save("matrix-vm-freebsd.json", self.receipt())
        self.runner.command = Mock(
            return_value={"result": dict(email="test@example.invalid", guest_username="u200000")}
        )
        self.runner.matrix_owned = Mock(
            return_value=dict(observed_state="running", desired_state="running")
        )
        process = Mock(returncode=0)
        process.communicate.return_value = (
            "kernel=FreeBSD\nrelease=14.3-RELEASE-p16\n",
            SSH_LOGIN_EVENT + "unexpected warning\n",
        )
        with (
            patch("porsche_acceptance.subprocess.Popen", return_value=process),
            self.assertRaises(RuntimeError),
        ):
            self.runner.matrix_ssh(("freebsd",))
        self.assertFalse(
            json.loads((self.path / "matrix-ssh-initial-freebsd.json").read_text())["verified"]
        )

    def test_windows_exact_pq_warning_accepts_only_known_line_endings(self) -> None:
        self.runner.save("matrix-vm-windows.json", self.receipt("windows"))
        self.runner.command = Mock(
            return_value={"result": dict(email="test@example.invalid", guest_username="u200000")}
        )
        self.runner.matrix_owned = Mock(
            return_value=dict(observed_state="running", desired_state="running")
        )
        output = json.dumps(
            dict(
                family="Win32NT",
                caption="Microsoft Windows Server 2025 Standard Evaluation",
                build="26100",
            )
        )
        for index, warning in enumerate(
            (SSH_WINDOWS_PQ_WARNING, SSH_WINDOWS_PQ_WARNING.replace("\n", "\r\n"))
        ):
            with self.subTest(index=index):
                process = Mock(returncode=0)
                process.communicate.return_value = (output, warning)
                with patch("porsche_acceptance.subprocess.Popen", return_value=process) as popen:
                    self.runner.matrix_ssh(("windows",), f"known-warning-{index}")
                argv = popen.call_args.args[0]
                for option in ("BatchMode=yes", "IdentitiesOnly=yes", "StrictHostKeyChecking=yes"):
                    self.assertIn(option, argv)
                self.assertFalse(
                    any("WarnWeakCrypto" in item or "KexAlgorithms" in item for item in argv)
                )
                record = json.loads(
                    (self.path / f"matrix-ssh-known-warning-{index}-windows.json").read_text()
                )
                self.assertTrue(record["verified"])
                self.assertEqual(record["stderr_classification"], "windows-openssh-pq-warning")
                self.assertNotIn("stderr", record)

    def test_windows_warning_never_accepts_changed_stderr_nonzero_or_wrong_os(self) -> None:
        self.runner.save("matrix-vm-windows.json", self.receipt("windows"))
        self.runner.command = Mock(
            return_value={"result": dict(email="test@example.invalid", guest_username="u200000")}
        )
        self.runner.matrix_owned = Mock(
            return_value=dict(observed_state="running", desired_state="running")
        )
        expected = dict(
            family="Win32NT",
            caption="Microsoft Windows Server 2025 Standard Evaluation",
            build="26100",
        )
        cases: list[tuple[int, str, str]] = [
            (0, json.dumps(expected), SSH_WINDOWS_PQ_WARNING + "unexpected warning\n"),
            (0, json.dumps(expected), "extra prefix\n" + SSH_WINDOWS_PQ_WARNING),
            (0, json.dumps(expected), SSH_WINDOWS_PQ_WARNING.replace("post-quantum", "different")),
            (0, json.dumps(expected), SSH_WINDOWS_PQ_WARNING.rstrip("\n")),
            (0, json.dumps(expected), SSH_WINDOWS_PQ_WARNING * 2),
            (255, json.dumps(expected), SSH_WINDOWS_PQ_WARNING),
            (1, json.dumps(expected), SSH_WINDOWS_PQ_WARNING),
            (0, json.dumps(dict(expected, build="26000")), SSH_WINDOWS_PQ_WARNING),
            (0, json.dumps(dict(expected, family="Unix")), SSH_WINDOWS_PQ_WARNING),
            (0, "malformed output", SSH_WINDOWS_PQ_WARNING),
        ]
        for index, (exit_status, output, warning) in enumerate(cases):
            with self.subTest(index=index):
                process = Mock(returncode=exit_status)
                process.communicate.return_value = (output, warning)
                with (
                    patch("porsche_acceptance.subprocess.Popen", return_value=process),
                    self.assertRaises((RuntimeError, ValueError)),
                ):
                    self.runner.matrix_ssh(("windows",), f"refused-warning-{index}")
                record = json.loads(
                    (self.path / f"matrix-ssh-refused-warning-{index}-windows.json").read_text()
                )
                self.assertFalse(record["verified"])
                self.assertEqual(
                    record["stderr_classification"],
                    "windows-openssh-pq-warning" if index >= 5 else "unexpected",
                )

    def test_windows_pq_warning_is_refused_for_every_other_guest_family(self) -> None:
        self.runner.command = Mock(
            return_value={"result": dict(email="test@example.invalid", guest_username="u200000")}
        )
        self.runner.matrix_owned = Mock(
            return_value=dict(observed_state="running", desired_state="running")
        )
        for kind in GUEST_OSES:
            if kind == "windows":
                continue
            with self.subTest(kind=kind):
                self.runner.save(f"matrix-vm-{kind}.json", self.receipt(kind))
                process = Mock(returncode=0)
                process.communicate.return_value = ("", SSH_WINDOWS_PQ_WARNING)
                with (
                    patch("porsche_acceptance.subprocess.Popen", return_value=process),
                    patch.object(self.runner, "matrix_verify_os") as oracle,
                    self.assertRaises(RuntimeError),
                ):
                    self.runner.matrix_ssh((kind,), "wrong-family-warning")
                oracle.assert_not_called()
                record = json.loads(
                    (self.path / f"matrix-ssh-wrong-family-warning-{kind}.json").read_text()
                )
                self.assertFalse(record["verified"])
                self.assertEqual(record["stderr_classification"], "unexpected")


if __name__ == "__main__":
    unittest.main()
