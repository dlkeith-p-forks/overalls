"""Read-only guest substrate readiness shared by bootstrap and the lifecycle command."""

from pathlib import Path

from core.outcome import Observation, State
from guest_lifecycle.operation import ComputeLifecycleOperator, OperationLedger, OperatorReply
from guest_lifecycle.witness import GuestIdentity, GuestWitnessClient

# Admission reserves guest memory plus the fixed VMM overhead
# (OverallsProtocol.VMShape.host_memory/1); headroom must cover both.
VMM_OVERHEAD_BYTES = 67_108_864


def _object(reply: OperatorReply) -> dict[str, object] | None:
    return reply.value if reply.status == "ok" and isinstance(reply.value, dict) else None


def capacity_gap(reply: OperatorReply, identity: GuestIdentity) -> str | None:
    """@cc [owner:ghuntley,label:capacity;verification] guest-catalog-capacity-explicit
    A catalog is usable only when Marshall reports known capacity, offers the
    guest-vmm's exact image ID, and every available dimension covers the image
    shape. Each unmet condition MUST return a fixed reason token, never a value.
    """
    value = _object(reply)
    if value is None:
        return "catalog_not_ok"
    if value.get("capacity_known") is not True:
        return "capacity_unknown"
    images = value.get("images")
    available = value.get("available")
    if not isinstance(images, list) or not isinstance(available, dict):
        return "catalog_invalid"
    if not any(
        isinstance(image, dict) and image.get("id") == identity.image_id for image in images
    ):
        return "image_not_offered"
    vcpu = available.get("vcpu")
    memory = available.get("memory_bytes")
    disk = available.get("disk_bytes")
    if not (type(vcpu) is int and vcpu >= identity.vcpu):
        return "capacity_insufficient_vcpu"
    if not (type(memory) is int and memory >= identity.memory_bytes + VMM_OVERHEAD_BYTES):
        return "capacity_insufficient_memory"
    if not (type(disk) is int and disk >= identity.minimum_disk_bytes):
        return "capacity_insufficient_disk"
    return None


def capacity_ready(reply: OperatorReply, identity: GuestIdentity) -> bool:
    return capacity_gap(reply, identity) is None


def observed_gap(
    identity: Observation[GuestIdentity], catalog: Observation[OperatorReply]
) -> str | None:
    """Fixed reason token for an unusable identity or catalog observation."""
    if identity.state is not State.OBSERVED or identity.value is None:
        return f"guest_identity_{identity.state.value}"
    if catalog.state is not State.OBSERVED or catalog.value is None:
        return f"compute_catalog_{catalog.state.value}"
    return capacity_gap(catalog.value, identity.value)


def substrate_gap(request_root: Path) -> str | None:
    """@cc [owner:ghuntley,label:verification] guest-substrate-readiness-observed
    Guest-lifecycle setup MUST observe the guest-vmm image identity through the
    operator's read-only witness bridge and a Marshall catalog that offers that
    image with enough known capacity. An unavailable or refused observation MUST
    leave setup incomplete with a fixed reason; it issues no mutation.
    """
    operator = ComputeLifecycleOperator(request_root, OperationLedger())
    identity = GuestWitnessClient(operator).identity()
    if identity.state is not State.OBSERVED or identity.value is None:
        return f"guest_identity_{identity.state.value}"
    return observed_gap(identity, operator.catalog())
