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
from guest_lifecycle.witness import GuestIdentity, GuestSpec, GuestWitness, GuestWitnessClient

LOG = logging.getLogger(__name__)


@dataclass(frozen=True)
class BootObservation:
    operation: OperationView
    vm: VmView
    guest: GuestWitness


@dataclass(frozen=True)
class ObservedMismatch:
    operation: OperationView
    vm: VmView


def _reject_mismatch() -> None:
    always(
        False,
        "Completed guest lifecycle outcome matches current VM state and execution identity",
    )


def _object(reply: OperatorReply) -> dict[str, object] | None:
    return reply.value if reply.status == "ok" and isinstance(reply.value, dict) else None


def _capacity_ready(reply: OperatorReply, identity: GuestIdentity) -> bool:
    value = _object(reply)
    if value is None or value.get("capacity_known") is not True:
        return False
    images = value.get("images")
    available = value.get("available")
    if not isinstance(images, list) or not isinstance(available, dict):
        return False
    if not any(
        isinstance(image, dict) and image.get("id") == identity.image_id for image in images
    ):
        return False
    vcpu = available.get("vcpu")
    memory = available.get("memory_bytes")
    disk = available.get("disk_bytes")
    return (
        type(vcpu) is int
        and vcpu >= identity.vcpu
        and type(memory) is int
        and memory >= identity.memory_bytes
        and type(disk) is int
        and disk >= identity.minimum_disk_bytes
    )


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
) -> BootObservation | ObservedMismatch | None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        operation_reply = operator.operation(vm_id, operation_id)
        vm_reply = operator.get(vm_id)
        if (
            operation_reply.state is not State.OBSERVED
            or operation_reply.value is None
            or vm_reply.state is not State.OBSERVED
            or vm_reply.value is None
        ):
            time.sleep(1)
            continue
        try:
            operation = operation_view(operation_reply.value, vm_id, operation_id)
            vm = vm_view(vm_reply.value, vm_id)
        except (ValueError, TypeError):
            time.sleep(1)
            continue
        if operation.status != "completed" or operation.outcome is None:
            time.sleep(1)
            continue
        if (
            operation.kind != expected_kind
            or vm.observed_state != operation.outcome.state
            or vm.placement_id != operation.placement_id
            or vm.execution_epoch != operation.execution_epoch
            or vm.generation != operation.generation
        ):
            return ObservedMismatch(operation, vm)
        if operation.outcome.state != expected_state:
            return None
        guest_result = witness.witness(
            GuestSpec(vm.placement_id, operation.execution_epoch, operation.generation)
        )
        if guest_result.state is State.OBSERVED and guest_result.value is not None:
            return BootObservation(operation, vm, guest_result.value)
        time.sleep(1)
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
    identity_result = witness.identity()
    catalog_result = operator.catalog()
    if (
        identity_result.state is not State.OBSERVED
        or identity_result.value is None
        or catalog_result.state is not State.OBSERVED
        or catalog_result.value is None
        or not _capacity_ready(catalog_result.value, identity_result.value)
    ):
        LOG.info("Guest lifecycle unexercised: image or measured capacity unavailable")
        return 0
    image = identity_result.value
    disk_bytes = ((image.minimum_disk_bytes + 4095) // 4096) * 4096
    admission = operator.provision(
        image.image_id, image.vcpu, image.memory_bytes, disk_bytes, uuid4()
    )
    if admission.state is not State.OBSERVED or admission.value is None:
        LOG.info("Guest lifecycle provision uncertain")
        return 0
    try:
        vm_id = provision_id(admission.value)
        provision_operation = _operation_id(admission.value, vm_id)
    except (ValueError, TypeError):
        LOG.info("Guest lifecycle provision receipt unavailable")
        return 0
    first = _sample(operator, witness, vm_id, provision_operation, "provision", "running", 240)
    if isinstance(first, ObservedMismatch):
        _reject_mismatch()
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

    stop_reply = operator.lifecycle(vm_id, "stop", uuid4())
    if stop_reply.state is not State.OBSERVED or stop_reply.value is None:
        LOG.info("Guest lifecycle stop uncertain")
        return 0
    try:
        stop_id = lifecycle_id(stop_reply.value, vm_id, "stop")
    except (ValueError, TypeError):
        return 0
    stopped = _sample(operator, witness, vm_id, stop_id, "stop", "stopped", 240)
    if isinstance(stopped, ObservedMismatch):
        _reject_mismatch()
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

    start_reply = operator.lifecycle(vm_id, "start", uuid4())
    if start_reply.state is not State.OBSERVED or start_reply.value is None:
        LOG.info("Guest lifecycle fresh start uncertain")
        return 0
    try:
        start_id = lifecycle_id(start_reply.value, vm_id, "start")
    except (ValueError, TypeError):
        return 0
    restarted = _sample(operator, witness, vm_id, start_id, "start", "running", 240)
    if isinstance(restarted, ObservedMismatch):
        _reject_mismatch()
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
