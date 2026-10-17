"""Validate the small, authorized Compute values used by guest lifecycle tests."""

from dataclasses import dataclass
from uuid import UUID

from guest_lifecycle.operation import OperatorReply


@dataclass(frozen=True)
class VmView:
    vm_id: UUID
    placement_id: UUID
    execution_epoch: int
    generation: int
    observed_state: str
    desired_state: str
    image_id: str


@dataclass(frozen=True)
class OutcomeView:
    id: UUID
    host_id: UUID
    sequence: int
    state: str
    guest_ready: bool
    disk_present: bool
    compute_empty: bool


@dataclass(frozen=True)
class OperationView:
    id: UUID
    vm_id: UUID
    placement_id: UUID
    execution_epoch: int
    generation: int
    kind: str
    status: str
    outcome: OutcomeView | None


def _uuid(value: object) -> UUID:
    if not isinstance(value, str):
        raise ValueError("invalid UUID")
    return UUID(value)


def _positive(value: object) -> int:
    if type(value) is not int or value < 1:
        raise ValueError("invalid positive integer")
    return value


def provision_id(reply: OperatorReply) -> UUID:
    if (
        reply.operation != "compute.provision"
        or reply.status != "ok"
        or not isinstance(reply.value, dict)
    ):
        raise ValueError("invalid provision reply")
    return _uuid(reply.value.get("vm_id"))


def lifecycle_id(reply: OperatorReply, vm_id: UUID, kind: str) -> UUID:
    if (
        reply.operation != "compute.lifecycle"
        or reply.status != "ok"
        or not isinstance(reply.value, dict)
    ):
        raise ValueError("invalid lifecycle reply")
    if reply.value.get("vm_id") != str(vm_id) or reply.value.get("kind") != kind:
        raise ValueError("lifecycle reply identity mismatch")
    return _uuid(reply.value.get("operation_id"))


def vm_view(reply: OperatorReply, vm_id: UUID) -> VmView:
    if (
        reply.operation != "compute.get"
        or reply.status != "ok"
        or not isinstance(reply.value, dict)
    ):
        raise ValueError("invalid VM reply")
    raw = reply.value
    if _uuid(raw.get("vm_id")) != vm_id:
        raise ValueError("VM identity mismatch")
    desired, observed, image_id = (
        raw.get("desired_state"),
        raw.get("observed_state"),
        raw.get("image_id"),
    )
    if (
        not isinstance(desired, str)
        or not isinstance(observed, str)
        or not isinstance(image_id, str)
    ):
        raise ValueError("invalid VM state")
    return VmView(
        vm_id,
        _uuid(raw.get("current_placement_id")),
        _positive(raw.get("execution_epoch")),
        _positive(raw.get("generation")),
        observed,
        desired,
        image_id,
    )


def operation_view(reply: OperatorReply, vm_id: UUID, operation_id: UUID) -> OperationView:
    """@cc [owner:ghuntley,label:verification] accepted-outcome-only-after-commit
    Only a completed operation with its exact committed PhysicalOutcome may
    establish an accepted result. Pending, absent or malformed outcomes remain
    unexercised even when Compute initially acknowledged the request.
    """
    if (
        reply.operation != "compute.operation"
        or reply.status != "ok"
        or not isinstance(reply.value, dict)
    ):
        raise ValueError("invalid operation reply")
    raw = reply.value
    if _uuid(raw.get("vm_id")) != vm_id or _uuid(raw.get("operation_id")) != operation_id:
        raise ValueError("operation identity mismatch")
    kind, status = raw.get("kind"), raw.get("status")
    if kind not in ("provision", "start", "stop") or status not in (
        "pending",
        "acknowledged",
        "completed",
        "cancelled",
    ):
        raise ValueError("invalid operation state")
    raw_outcome = raw.get("accepted_outcome")
    outcome: OutcomeView | None = None
    if raw_outcome is not None:
        if not isinstance(raw_outcome, dict):
            raise ValueError("invalid accepted outcome")
        state = raw_outcome.get("state")
        guest_ready = raw_outcome.get("guest_ready")
        disk_present = raw_outcome.get("disk_present")
        compute_empty = raw_outcome.get("compute_empty")
        if (
            state not in ("running", "stopped", "deleted", "failed", "unknown")
            or (guest_ready is not True and guest_ready is not None)
            or type(disk_present) is not bool
            or type(compute_empty) is not bool
        ):
            raise ValueError("invalid accepted outcome fields")
        outcome = OutcomeView(
            _uuid(raw_outcome.get("id")),
            _uuid(raw_outcome.get("host_id")),
            _positive(raw_outcome.get("sequence")),
            state,
            guest_ready is True,
            disk_present,
            compute_empty,
        )
    completion = raw.get("completion_outcome_id")
    if status == "completed":
        if outcome is None or _uuid(completion) != outcome.id:
            raise ValueError("completed operation has no matching accepted outcome")
    elif completion is not None or outcome is not None:
        raise ValueError("pending operation has a completion outcome")
    return OperationView(
        operation_id,
        vm_id,
        _uuid(raw.get("placement_id")),
        _positive(raw.get("execution_epoch")),
        _positive(raw.get("generation")),
        kind,
        status,
        outcome,
    )
