"""A committed outcome/VM contradiction must reach the Antithesis assertion."""

import unittest
from unittest.mock import patch
from uuid import UUID

from core.outcome import Observation
from guest_lifecycle.operation import ComputeLifecycleOperator, OperatorReply
from guest_lifecycle.scenarios import ObservedMismatch, _reject_mismatch, _sample
from guest_lifecycle.witness import GuestWitnessClient

PLACEMENT = UUID("11111111-1111-4111-8111-111111111111")
VM = UUID("22222222-2222-4222-8222-222222222222")
OPERATION = UUID("33333333-3333-4333-8333-333333333333")
OUTCOME = UUID("44444444-4444-4444-8444-444444444444")
HOST = UUID("55555555-5555-4555-8555-555555555555")


class FixedOperator(ComputeLifecycleOperator):
    def __init__(self, *, state: str, generation: int) -> None:
        self.state = state
        self.generation = generation

    def operation(self, vm_id: UUID, operation_id: UUID) -> Observation[OperatorReply]:
        return Observation.observed(
            OperatorReply(
                OPERATION,
                "compute.operation",
                "ok",
                {
                    "operation_id": str(operation_id),
                    "vm_id": str(vm_id),
                    "placement_id": str(PLACEMENT),
                    "execution_epoch": 7,
                    "generation": 1,
                    "kind": "provision",
                    "status": "completed",
                    "completion_outcome_id": str(OUTCOME),
                    "accepted_outcome": {
                        "id": str(OUTCOME),
                        "host_id": str(HOST),
                        "sequence": 1,
                        "state": "running",
                        "guest_ready": True,
                        "disk_present": True,
                        "compute_empty": False,
                    },
                },
            )
        )

    def get(self, vm_id: UUID) -> Observation[OperatorReply]:
        return Observation.observed(
            OperatorReply(
                OPERATION,
                "compute.get",
                "ok",
                {
                    "vm_id": str(vm_id),
                    "current_placement_id": str(PLACEMENT),
                    "execution_epoch": 7,
                    "generation": self.generation,
                    "observed_state": self.state,
                    "desired_state": "running",
                    "image_id": "sha256:" + "a" * 64,
                },
            )
        )


class UnavailableOperator(FixedOperator):
    def operation(self, vm_id: UUID, operation_id: UUID) -> Observation[OperatorReply]:
        return Observation.unavailable()


class SampleTest(unittest.TestCase):
    def test_completed_outcome_disagreement_fails_assertion(self) -> None:
        for state, generation in (("stopped", 1), ("running", 2)):
            with self.subTest(state=state, generation=generation):
                operator = FixedOperator(state=state, generation=generation)
                sample = _sample(
                    operator,
                    GuestWitnessClient(operator),
                    VM,
                    OPERATION,
                    "provision",
                    "running",
                    1,
                )
                self.assertIsInstance(sample, ObservedMismatch)
                with patch("guest_lifecycle.scenarios.always") as assertion:
                    _reject_mismatch()
                assertion.assert_called_once_with(
                    False,
                    "Completed guest lifecycle outcome matches current VM state and execution identity",
                )

    def test_unavailable_operation_remains_unknown(self) -> None:
        operator = UnavailableOperator(state="running", generation=1)
        with (
            patch("guest_lifecycle.scenarios.time.monotonic", side_effect=(0.0, 0.5, 2.0)),
            patch("guest_lifecycle.scenarios.time.sleep"),
            patch("guest_lifecycle.scenarios.always") as assertion,
        ):
            sample = _sample(
                operator,
                GuestWitnessClient(operator),
                VM,
                OPERATION,
                "provision",
                "running",
                1,
            )
        self.assertIsNone(sample)
        assertion.assert_not_called()


if __name__ == "__main__":
    unittest.main()
