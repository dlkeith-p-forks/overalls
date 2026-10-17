"""Live acceptance must not mutate unrelated resources or count transport errors as passes."""

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from porsche_acceptance import Acceptance, CommandOutcome


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


if __name__ == "__main__":
    unittest.main()
