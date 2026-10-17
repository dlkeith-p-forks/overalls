"""Regression cases for independent physical and disk proof boundaries."""

import unittest
from uuid import UUID

from guest_lifecycle.domain import operation_view
from guest_lifecycle.operation import OperatorReply
from guest_lifecycle.oracle import (
    PhysicalReceipt,
    StorageWitness,
    Verdict,
    WorkspaceWitness,
    continuing_boot_adoption,
    ready_matches_current_boot,
    stopped_retains_disk,
    workspace_checkout_claim,
)
from guest_lifecycle.witness import (
    GuestIdentity,
    GuestSpec,
    GuestWitness,
    ProcessIdentity,
    parse_identity,
    parse_witness,
)

PLACEMENT = UUID("11111111-1111-4111-8111-111111111111")
BOOT = UUID("22222222-2222-4222-8222-222222222222")
VM = UUID("33333333-3333-4333-8333-333333333333")
OPERATION = UUID("44444444-4444-4444-8444-444444444444")
DIGEST = "a" * 64


def guest(*, generation: int = 1, state: str = "running") -> GuestWitness:
    running = state == "running"
    return GuestWitness(
        state,
        PLACEMENT,
        7 if running else None,
        generation if running else None,
        BOOT if running else None,
        running,
        ProcessIdentity(101, 2001) if running else None,
        ProcessIdentity(102, 2002) if running else None,
        DIGEST if running else None,
        DIGEST,
        True,
        1024,
        None if running else DIGEST,
    )


def receipt() -> PhysicalReceipt:
    return PhysicalReceipt(OPERATION, VM, PLACEMENT, 7, 1, BOOT, DIGEST, True, "completed")


class OracleTest(unittest.TestCase):
    def test_readiness_requires_current_boot_and_generation(self) -> None:
        self.assertIs(
            ready_matches_current_boot(receipt(), guest(), current_generation=1), Verdict.MATCH
        )
        self.assertIs(
            ready_matches_current_boot(receipt(), None, current_generation=1), Verdict.UNEXERCISED
        )
        self.assertIs(
            ready_matches_current_boot(receipt(), guest(generation=2), current_generation=2),
            Verdict.VIOLATION,
        )

    def test_adoption_checks_pid_start_tick_and_old_delivery(self) -> None:
        first = guest()
        adopted = guest(generation=2)
        self.assertIs(
            continuing_boot_adoption(
                first,
                adopted,
                accepted_new_generation=True,
                stale_delivery_settled_new_journal=False,
            ),
            Verdict.MATCH,
        )
        reused_pid = GuestWitness(
            adopted.guest_state,
            adopted.placement_id,
            adopted.execution_epoch,
            adopted.generation,
            adopted.boot_id,
            adopted.ready,
            ProcessIdentity(101, 3001),
            adopted.backend,
            adopted.boot_challenge_sha256,
            adopted.image_manifest_sha256,
            adopted.overlay_present,
            adopted.overlay_bytes,
            adopted.overlay_sha256,
        )
        self.assertIs(
            continuing_boot_adoption(
                first,
                reused_pid,
                accepted_new_generation=True,
                stale_delivery_settled_new_journal=False,
            ),
            Verdict.VIOLATION,
        )
        self.assertIs(
            continuing_boot_adoption(
                first,
                adopted,
                accepted_new_generation=True,
                stale_delivery_settled_new_journal=True,
            ),
            Verdict.VIOLATION,
        )

    def test_stop_requires_measured_content_and_absence(self) -> None:
        first = StorageWitness(PLACEMENT, "81234", "10.0.0.8", True, DIGEST)
        stopped = StorageWitness(PLACEMENT, "81234", "10.0.0.8", False, DIGEST)
        self.assertIs(
            stopped_retains_disk(
                first,
                stopped,
                guest(state="stopped"),
                stop_completed=True,
                compute_held=False,
                disk_held=True,
            ),
            Verdict.MATCH,
        )
        self.assertIs(
            stopped_retains_disk(
                first,
                StorageWitness(PLACEMENT, "81234", "10.0.0.8", False, None),
                guest(state="stopped"),
                stop_completed=True,
                compute_held=False,
                disk_held=True,
            ),
            Verdict.UNEXERCISED,
        )
        wrong = StorageWitness(PLACEMENT, "98765", "10.0.0.8", False, DIGEST)
        self.assertIs(
            stopped_retains_disk(
                first,
                wrong,
                guest(state="stopped"),
                stop_completed=True,
                compute_held=False,
                disk_held=True,
            ),
            Verdict.VIOLATION,
        )

    def test_null_source_capability_is_unexercised(self) -> None:
        absent = GuestIdentity("sha256:" + DIGEST, 1, 1, 1, None)
        workspace = WorkspaceWitness(BOOT, DIGEST, True, "b" * 40, "b" * 40)
        self.assertIs(
            workspace_checkout_claim(absent, guest(), workspace, checkout_complete_claimed=True),
            Verdict.VIOLATION,
        )
        self.assertIs(
            workspace_checkout_claim(absent, guest(), None, checkout_complete_claimed=False),
            Verdict.UNEXERCISED,
        )
        enabled = GuestIdentity(absent.image_id, 1, 1, 1, 2)
        self.assertIs(
            workspace_checkout_claim(enabled, guest(), workspace, checkout_complete_claimed=True),
            Verdict.MATCH,
        )
        missing_marker = WorkspaceWitness(BOOT, DIGEST, False, "b" * 40, "b" * 40)
        self.assertIs(
            workspace_checkout_claim(
                enabled, guest(), missing_marker, checkout_complete_claimed=True
            ),
            Verdict.VIOLATION,
        )

    def test_witness_parser_rejects_identity_and_readiness_shortcuts(self) -> None:
        raw: dict[str, object] = {
            "state": "ok",
            "guest_state": "running",
            "placement_id": str(PLACEMENT),
            "execution_epoch": 7,
            "generation": 1,
            "boot_id": str(BOOT),
            "ready": True,
            "qemu": {"pid": 101, "start_ticks": 2001},
            "backend": {"pid": 102, "start_ticks": 2002},
            "boot_challenge_sha256": DIGEST,
            "image_manifest_sha256": DIGEST,
            "overlay_present": True,
            "overlay_bytes": 1024,
            "overlay_sha256": None,
        }
        self.assertEqual(
            parse_witness(raw, GuestSpec(PLACEMENT, 7, 1)).physical_boot,
            (ProcessIdentity(101, 2001), BOOT, DIGEST),
        )
        stopped = dict(raw)
        stopped.update(
            guest_state="stopped",
            boot_id=None,
            ready=False,
            qemu=None,
            backend=None,
            overlay_sha256=DIGEST,
        )
        self.assertEqual(parse_witness(stopped, GuestSpec(PLACEMENT, 7, 1)).overlay_sha256, DIGEST)
        raw["qemu"] = {"pid": 101}
        with self.assertRaises(ValueError):
            parse_witness(raw, GuestSpec(PLACEMENT, 7, 1))
        identity = {
            "state": "ok",
            "image_id": "sha256:" + DIGEST,
            "minimum_disk_bytes": 1,
            "memory_bytes": 1,
            "vcpu": 1,
            "workspace_source_version": None,
        }
        self.assertIsNone(parse_identity(identity).workspace_source_version)

    def test_committed_operation_needs_exact_outcome(self) -> None:
        value: dict[str, object] = {
            "operation_id": str(OPERATION),
            "vm_id": str(VM),
            "placement_id": str(PLACEMENT),
            "execution_epoch": 7,
            "generation": 1,
            "kind": "stop",
            "status": "completed",
            "completion_outcome_id": str(BOOT),
            "accepted_outcome": {
                "id": str(BOOT),
                "host_id": str(VM),
                "sequence": 3,
                "state": "stopped",
                "guest_ready": None,
                "disk_present": True,
                "compute_empty": True,
            },
        }
        result = operation_view(
            OperatorReply(OPERATION, "compute.operation", "ok", value), VM, OPERATION
        )
        self.assertIsNotNone(result.outcome)
        self.assertFalse(result.outcome.guest_ready if result.outcome else True)
        value["completion_outcome_id"] = str(PLACEMENT)
        with self.assertRaises(ValueError):
            operation_view(
                OperatorReply(OPERATION, "compute.operation", "ok", value), VM, OPERATION
            )


if __name__ == "__main__":
    unittest.main()
