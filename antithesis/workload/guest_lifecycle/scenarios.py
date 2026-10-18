"""Drive one real provision, stop and fresh start with independent guest samples."""

import logging
import os
import time
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID, uuid4

from antithesis.assertions import always, reachable

from core.outcome import State
from guest_lifecycle.domain import (
    OperationView,
    VmView,
    lifecycle_id,
    operation_view,
    provision_id,
    vm_view,
)
from guest_lifecycle.operation import ComputeLifecycleOperator, OperationLedger, OperatorReply
from guest_lifecycle.readiness import observed_gap
from guest_lifecycle.witness import GuestIdentity, GuestSpec, GuestWitness, GuestWitnessClient

LOG = logging.getLogger(__name__)
# Uncertain final stops are resubmitted with one key before the slot is abandoned.
RELEASE_ATTEMPTS = 5
# A lost stop/start reply is resubmitted with its original key, which Marshall
# deduplicates, before the cycle is left unexercised.
LIFECYCLE_ATTEMPTS = 3
# Marshall withholds capacity whose last accepted Lilly report is older than its
# 5 s freshness window, which injected faults routinely exceed; the cycle polls
# for a usable catalog instead of judging one instant.
CATALOG_WAIT_SECONDS = 180.0
CATALOG_POLL_SECONDS = 2.0
# One read stalled behind the serial operator must not consume the window.
CATALOG_READ_SECONDS = 30.0
# Admission re-checks freshness transactionally (insufficient_capacity), and
# the operator re-reads the catalog before provisioning (image_unavailable when
# the host's image report went stale); either is retried after a fresh wait.
PROVISION_ATTEMPTS = 3
STALE_REFUSALS = frozenset({"insufficient_capacity", "image_unavailable"})


@dataclass(frozen=True)
class BootObservation:
    operation: OperationView
    vm: VmView
    guest: GuestWitness


@dataclass(frozen=True)
class ObservedMismatch:
    operation: OperationView
    vm: VmView


def _submit(operator: ComputeLifecycleOperator, vm_id: UUID, kind: str) -> OperatorReply | None:
    """Submit one stop/start, resubmitting an uncertain reply with the same key."""
    key = uuid4()
    for attempt in range(LIFECYCLE_ATTEMPTS):
        if attempt:
            time.sleep(5)
        reply = operator.lifecycle(vm_id, kind, key)
        if reply.state is State.OBSERVED and reply.value is not None:
            return reply.value
    return None


def _object(reply: OperatorReply) -> dict[str, object] | None:
    return reply.value if reply.status == "ok" and isinstance(reply.value, dict) else None


def _operation_id(reply: OperatorReply, vm_id: UUID) -> UUID:
    value = _object(reply)
    if value is None or value.get("vm_id") != str(vm_id):
        raise ValueError("provision operation identity mismatch")
    candidate = value.get("operation_id")
    if not isinstance(candidate, str):
        raise ValueError("missing provision operation ID")
    return UUID(candidate)


def _sample(
    operator: ComputeLifecycleOperator,
    witness: GuestWitnessClient,
    vm_id: UUID,
    operation_id: UUID,
    expected_kind: str,
    expected_state: str,
    timeout_seconds: float,
    boot: tuple[int, int] | None = None,
) -> BootObservation | ObservedMismatch | None:
    """Join a completed operation to the guest witness for its boot.

    A stop retains the boot it ended, whose tuple predates the stop's own
    generation bump, so the caller names that boot; otherwise the operation's
    tuple identifies the boot it produced.
    """
    deadline = time.monotonic() + timeout_seconds
    # The last unmet step, logged once on expiry so a stalled join is visible.
    stage = "not_sampled"
    while time.monotonic() < deadline:
        operation_reply = operator.operation(vm_id, operation_id)
        vm_reply = operator.get(vm_id)
        if (
            operation_reply.state is not State.OBSERVED
            or operation_reply.value is None
            or vm_reply.state is not State.OBSERVED
            or vm_reply.value is None
        ):
            stage = "compute_unavailable"
            time.sleep(1)
            continue
        try:
            operation = operation_view(operation_reply.value, vm_id, operation_id)
            vm = vm_view(vm_reply.value, vm_id)
        except (ValueError, TypeError):
            stage = "compute_invalid"
            time.sleep(1)
            continue
        if operation.status != "completed" or operation.outcome is None:
            stage = "operation_pending"
            time.sleep(1)
            continue
        # Evaluated for every completed outcome, so a healthy run records the
        # property as held rather than never reached.
        consistent = (
            operation.kind == expected_kind
            and vm.observed_state == operation.outcome.state
            and vm.placement_id == operation.placement_id
            and vm.execution_epoch == operation.execution_epoch
            and vm.generation == operation.generation
        )
        always(
            consistent,
            "Completed guest lifecycle outcome matches current VM state and execution identity",
        )
        if not consistent:
            return ObservedMismatch(operation, vm)
        if operation.outcome.state != expected_state:
            return None
        epoch, generation = boot or (operation.execution_epoch, operation.generation)
        guest_result = witness.witness(GuestSpec(vm.placement_id, epoch, generation))
        if guest_result.state is State.OBSERVED and guest_result.value is not None:
            return BootObservation(operation, vm, guest_result.value)
        stage = "witness_unavailable"
        time.sleep(1)
    LOG.info("Guest lifecycle %s sample expired: %s", expected_kind, stage)
    return None


def _running_matches(observation: BootObservation) -> bool:
    outcome = observation.operation.outcome
    guest = observation.guest
    return (
        outcome is not None
        and outcome.guest_ready
        and outcome.state == "running"
        and guest.physical_boot is not None
        and guest.placement_id == observation.operation.placement_id
        and guest.execution_epoch == observation.operation.execution_epoch
        and guest.generation == observation.operation.generation
    )


def _stopped_has_retained_overlay(observation: BootObservation) -> bool:
    outcome = observation.operation.outcome
    guest = observation.guest
    return (
        outcome is not None
        and outcome.state == "stopped"
        and outcome.disk_present
        and outcome.compute_empty
        and guest.guest_state == "stopped"
        and guest.qemu is None
        and guest.backend is None
        and guest.overlay_present
        and guest.overlay_sha256 is not None
    )


def _usable_catalog(
    operator: ComputeLifecycleOperator, witness: GuestWitnessClient
) -> tuple[GuestIdentity, str | None] | str:
    """Poll until identity and catalog are usable, else return the last gap token."""
    deadline = time.monotonic() + CATALOG_WAIT_SECONDS
    while True:
        identity_result = witness.identity()
        remaining = deadline - time.monotonic()
        catalog_result = operator.catalog(max(1.0, min(CATALOG_READ_SECONDS, remaining)))
        gap = observed_gap(identity_result, catalog_result)
        if gap is None and identity_result.value is not None and catalog_result.value is not None:
            return identity_result.value, None
        if time.monotonic() + CATALOG_POLL_SECONDS >= deadline:
            return gap or "observation_missing"
        time.sleep(CATALOG_POLL_SECONDS)


def _admit(
    operator: ComputeLifecycleOperator, witness: GuestWitnessClient
) -> tuple[UUID, UUID] | None:
    """Provision once capacity is usable; a capacity refusal waits and retries."""
    for attempt in range(PROVISION_ATTEMPTS):
        usable = _usable_catalog(operator, witness)
        if isinstance(usable, str):
            LOG.info("Guest lifecycle unexercised: %s", usable)
            return None
        image = usable[0]
        disk_bytes = ((image.minimum_disk_bytes + 4095) // 4096) * 4096
        admission = operator.provision(
            image.image_id, image.vcpu, image.memory_bytes, disk_bytes, uuid4()
        )
        if admission.state is not State.OBSERVED or admission.value is None:
            LOG.info("Guest lifecycle provision uncertain")
            return None
        if admission.value.status != "ok":
            reason = admission.value.reason or "unrecognized_reason"
            LOG.info("Guest lifecycle provision refused: %s", reason)
            if reason in STALE_REFUSALS and attempt + 1 < PROVISION_ATTEMPTS:
                continue
            return None
        try:
            vm_id = provision_id(admission.value)
            return vm_id, _operation_id(admission.value, vm_id)
        except (ValueError, TypeError):
            LOG.info("Guest lifecycle provision receipt unavailable")
            return None
    return None


def run_physical_boot_cycle() -> int:
    """@cc [owner:ghuntley,label:verification] guest-cycle-gates-physical-claims
    A completed Compute outcome MUST be joined to a separate guest witness
    before any physical assertion. Missing capacity, transport, operation or
    witness leaves the cycle unexercised, never passed or definitely refused.
    An observed completed outcome contradicting the VM's state or execution
    identity MUST reach a failing assertion rather than the unknown path.
    """
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    request_root = os.getenv("ANTITHESIS_CONTROL_REQUEST_DIR")
    if not request_root:
        LOG.info("Guest lifecycle unexercised: fixture paths unavailable")
        return 0
    ledger = OperationLedger()
    operator = ComputeLifecycleOperator(Path(request_root), ledger)
    witness = GuestWitnessClient(operator)
    admitted = _admit(operator, witness)
    if admitted is None:
        return 0
    vm_id, provision_operation = admitted
    # Every exit after admission submits a final stop, so a failed or
    # unobserved cycle cannot leave the single guest slot held.
    try:
        first = _sample(operator, witness, vm_id, provision_operation, "provision", "running", 240)
        if isinstance(first, ObservedMismatch):
            return 1
        if first is None:
            LOG.info("Guest lifecycle initial boot unexercised")
            return 0
        if first.operation.outcome is None or not first.operation.outcome.guest_ready:
            LOG.info("Guest lifecycle outcome lacks guest-ready proof")
            return 0
        always(
            _running_matches(first),
            "Guest ready outcome has current tuple and independent live QEMU guest readiness",
        )
        if not _running_matches(first):
            return 1
        reachable("Accepted provision reached a real QEMU guest boot and port 1024 readiness")

        stop_reply = _submit(operator, vm_id, "stop")
        if stop_reply is None:
            LOG.info("Guest lifecycle stop uncertain")
            return 0
        try:
            stop_id = lifecycle_id(stop_reply, vm_id, "stop")
        except (ValueError, TypeError):
            return 0
        stopped = _sample(
            operator,
            witness,
            vm_id,
            stop_id,
            "stop",
            "stopped",
            240,
            (first.operation.execution_epoch, first.operation.generation),
        )
        if isinstance(stopped, ObservedMismatch):
            return 1
        if stopped is None:
            LOG.info("Guest lifecycle completed stop unexercised")
            return 0
        always(
            _stopped_has_retained_overlay(stopped),
            "Accepted stop has no QEMU process and retains the measured guest overlay",
        )
        if not _stopped_has_retained_overlay(stopped):
            return 1
        reachable("Accepted stop has independently absent QEMU and retained qcow2 hash")

        start_reply = _submit(operator, vm_id, "start")
        if start_reply is None:
            LOG.info("Guest lifecycle fresh start uncertain")
            return 0
        try:
            start_id = lifecycle_id(start_reply, vm_id, "start")
        except (ValueError, TypeError):
            return 0
        restarted = _sample(operator, witness, vm_id, start_id, "start", "running", 240)
        if isinstance(restarted, ObservedMismatch):
            return 1
        if restarted is None:
            LOG.info("Guest lifecycle restarted boot unexercised")
            return 0
        if restarted.operation.outcome is None or not restarted.operation.outcome.guest_ready:
            LOG.info("Guest lifecycle restart outcome lacks guest-ready proof")
            return 0
        fresh = (
            _running_matches(restarted)
            and first.guest.physical_boot is not None
            and restarted.guest.physical_boot != first.guest.physical_boot
            and restarted.guest.boot_id != first.guest.boot_id
            and restarted.vm.placement_id == first.vm.placement_id
            and restarted.guest.overlay_present
        )
        always(fresh, "Fresh start reaches a new physical boot on the retained guest placement")
        if fresh:
            reachable("Stopped retained guest restarted with a new kernel boot UUID")
        return 0 if fresh else 1
    finally:
        _release_slot(operator, vm_id)


def _release_slot(operator: ComputeLifecycleOperator, vm_id: UUID) -> None:
    """Submit a final stop so a later cycle can find the single guest slot free.

    The stop is an attempt only: its outcome is not sampled and proves nothing.
    An uncertain reply is resubmitted with the same request key, which Marshall
    deduplicates, so a lost reply cannot leave the slot occupied for later cycles.
    """
    key = uuid4()
    for attempt in range(RELEASE_ATTEMPTS):
        if attempt:
            time.sleep(5)
        reply = operator.lifecycle(vm_id, "stop", key)
        if reply.state is State.OBSERVED and reply.value is not None:
            return
    LOG.info("Guest lifecycle final stop uncertain")
