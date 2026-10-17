"""Tri-state capacity verdict: contradiction, proof, or unavailable evidence."""

import time
from datetime import UTC

from admission.capacity import CapacityFrame
from admission.client import CatalogImage, Provisioned
from admission.oracle import Allocation
from admission.physical import PhysicalSample
from core.outcome import Observation, State


def measured_capacity_verdict(
    receipt: Provisioned | None,
    rows: tuple[Allocation, ...],
    before: CapacityFrame,
    after: Observation[CapacityFrame | None],
    physical: PhysicalSample,
    image: CatalogImage,
) -> bool | None:
    """@cc [owner:ghuntley,label:verification] capacity-known-contradiction-fails
    An acknowledged admission and observed zero, multiple, or mismatching
    allocation rows, or an observed absent selected pool, MUST return false.
    Unavailable reads and concurrent report/old-hold changes MUST return None,
    not a passing assertion or a false safety violation.
    """
    if len(rows) != 1:
        return False
    if receipt is None:
        return None
    allocation = rows[0]
    if (
        allocation.vm_id != receipt.vm_id
        or allocation.owner_id != receipt.owner_id
        or allocation.placement_id != receipt.placement_id
        or allocation.host_id != receipt.host_id
        or allocation.host_id != before.host_id
        or allocation.pool_id != before.pool_id
    ):
        return False
    if after.state is not State.OBSERVED:
        return None
    if after.value is None:
        return False
    current = after.value
    if not before.same_measurement(current, new_placement=receipt.placement_id):
        return None
    # Both sides must be fresh to bracket the unknown instant of commit.
    if not before.fresh() or not current.fresh():
        return None
    if not physical.identifies(before):
        return None
    # The host observer updates asynchronously. An older sample cannot
    # corroborate the SQL frame, even if both happen to name the same pool.
    frame_at_ns = int(before.observed_at.replace(tzinfo=UTC).timestamp() * 1_000_000_000)
    if physical.sampled_at_ns < frame_at_ns:
        return None
    if not 0 <= time.time_ns() - physical.sampled_at_ns <= 10_000_000_000:
        return None
    # Later physical I/O can legitimately lower free bytes after the report.
    # Without a commit-correlated sample, this disagreement is unknown.
    if not physical.matches(before):
        return None
    own = [hold for hold in current.holds if hold.placement_id == receipt.placement_id]
    available = before.available()
    expected_vcpu, guest_memory, root_disk = image.request_shape()
    expected_memory = guest_memory + 67_108_864
    expected_disk = root_disk + 1_073_741_824
    return (
        available is not None
        and available[0] >= expected_vcpu
        and available[1] >= expected_memory
        and available[2] >= expected_disk
        and len(own) == 1
        and own[0].vcpu == expected_vcpu
        and own[0].memory_bytes == expected_memory
        and own[0].disk_bytes == expected_disk
    )
