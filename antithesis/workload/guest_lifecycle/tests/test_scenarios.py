"""A committed outcome/VM contradiction must reach the Antithesis assertion."""

import unittest
from unittest.mock import MagicMock, patch
from uuid import UUID

from core.outcome import Observation
from guest_lifecycle.operation import ComputeLifecycleOperator, OperatorReply
from guest_lifecycle.scenarios import (
    ObservedMismatch,
    _admit,
    _reject_mismatch,
    _sample,
    _usable_catalog,
)
from guest_lifecycle.witness import GuestIdentity, GuestSpec, GuestWitnessClient

PLACEMENT = UUID("11111111-1111-4111-8111-111111111111")
VM = UUID("22222222-2222-4222-8222-222222222222")
OPERATION = UUID("33333333-3333-4333-8333-333333333333")
OUTCOME = UUID("44444444-4444-4444-8444-444444444444")
HOST = UUID("55555555-5555-4555-8555-555555555555")
IMAGE = "sha256:" + "a" * 64
IDENTITY = GuestIdentity(IMAGE, 4_294_967_296, 2_147_483_648, 1, None)


def catalog_reply(known: bool) -> Observation[OperatorReply]:
    return Observation.observed(
        OperatorReply(
            OPERATION,
            "compute.catalog",
            "ok",
            {
                "capacity_known": known,
                "images": [{"id": IMAGE}],
                "available": {
                    "vcpu": 1,
                    "memory_bytes": 4_294_967_296,
                    "disk_bytes": 8_589_934_592,
                },
            },
        )
    )


def refused(reason: str) -> Observation[OperatorReply]:
    return Observation.observed(
        OperatorReply(OPERATION, "compute.provision", "refused", None, reason)
    )


def admitted() -> Observation[OperatorReply]:
    return Observation.observed(
        OperatorReply(
            OPERATION,
            "compute.provision",
            "ok",
            {"vm_id": str(VM), "operation_id": str(OPERATION)},
        )
    )


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

    def test_stop_sample_requests_the_retained_boot(self) -> None:
        operator = FixedOperator(state="running", generation=1)
        witness = MagicMock(spec=GuestWitnessClient)
        witness.witness.return_value = Observation.unavailable()
        with (
            patch("guest_lifecycle.scenarios.time.monotonic", side_effect=(0.0, 0.5, 2.0)),
            patch("guest_lifecycle.scenarios.time.sleep"),
        ):
            _sample(operator, witness, VM, OPERATION, "provision", "running", 1, (6, 4))
        witness.witness.assert_called_once_with(GuestSpec(PLACEMENT, 6, 4))

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


class AdmissionTest(unittest.TestCase):
    def operator(self) -> MagicMock:
        operator = MagicMock(spec=ComputeLifecycleOperator)
        operator.catalog.return_value = catalog_reply(True)
        return operator

    def witness(self) -> MagicMock:
        witness = MagicMock(spec=GuestWitnessClient)
        witness.identity.return_value = Observation.observed(IDENTITY)
        return witness

    def test_stale_capacity_is_polled_until_usable(self) -> None:
        operator = self.operator()
        operator.catalog.side_effect = (catalog_reply(False), catalog_reply(True))
        with (
            patch("guest_lifecycle.scenarios.time.monotonic", return_value=0.0),
            patch("guest_lifecycle.scenarios.time.sleep") as sleep,
        ):
            self.assertEqual(_usable_catalog(operator, self.witness()), (IDENTITY, None))
        sleep.assert_called_once()

    def test_persistent_gap_returns_the_last_token(self) -> None:
        operator = self.operator()
        operator.catalog.return_value = catalog_reply(False)
        with (
            patch("guest_lifecycle.scenarios.time.monotonic", side_effect=(0.0, 0.0, 195.0)),
            patch("guest_lifecycle.scenarios.time.sleep"),
        ):
            self.assertEqual(_usable_catalog(operator, self.witness()), "capacity_unknown")

    def test_stale_refusals_retry_with_a_fresh_key(self) -> None:
        for reason in ("insufficient_capacity", "image_unavailable"):
            with self.subTest(reason=reason):
                operator = self.operator()
                operator.provision.side_effect = (refused(reason), admitted())
                with patch("guest_lifecycle.scenarios.time.monotonic", return_value=0.0):
                    self.assertEqual(_admit(operator, self.witness()), (VM, OPERATION))
                keys = {call.args[4] for call in operator.provision.call_args_list}
                self.assertEqual(len(keys), 2)

    def test_catalog_reads_are_bounded_by_the_poll_window(self) -> None:
        operator = self.operator()
        with patch("guest_lifecycle.scenarios.time.monotonic", side_effect=(0.0, 170.0)):
            _usable_catalog(operator, self.witness())
        operator.catalog.assert_called_once_with(10.0)

    def test_other_refusals_are_not_retried(self) -> None:
        operator = self.operator()
        operator.provision.return_value = refused("invalid_request")
        with (
            patch("guest_lifecycle.scenarios.time.monotonic", return_value=0.0),
            self.assertLogs("guest_lifecycle.scenarios", "INFO") as logs,
        ):
            self.assertIsNone(_admit(operator, self.witness()))
        operator.provision.assert_called_once()
        self.assertIn("provision refused: invalid_request", logs.output[0])


if __name__ == "__main__":
    unittest.main()
