"""Measured report and retained-hold budget reconstructed from one SQL snapshot."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import TYPE_CHECKING, TypeGuard
from uuid import UUID

from core.outcome import Observation, State

if TYPE_CHECKING:
    from core.sql import SqlOracle


@dataclass(frozen=True)
class Hold:
    reservation_id: UUID
    placement_id: UUID
    pool_id: UUID
    vcpu: int
    memory_bytes: int
    disk_bytes: int
    compute_held: bool
    disk_held: bool
    startup_compute_held: bool
    startup_disk_held: bool
    temporary_disk_bytes: int
    pending_disk_bytes: int


@dataclass(frozen=True)
class CapacityFrame:
    host_id: UUID
    pool_id: UUID
    observed_at: datetime
    report_sequence: int
    host_reported_at: datetime | None
    pool_reported_at: datetime | None
    capacity: dict[str, object] | None
    overhead_cores: int
    overhead_memory_bytes: int
    free_bytes: int
    overhead_bytes: int
    allocations: dict[str, object]
    holds: tuple[Hold, ...]
    zpool_guid: str = ""
    dataset_guid: str = ""
    dataset: str = ""

    def same_measurement(self, other: CapacityFrame, *, new_placement: UUID) -> bool:
        """Demand unchanged reports and all preexisting holds around one admission."""
        return (
            self.host_id == other.host_id
            and self.pool_id == other.pool_id
            and self.report_sequence == other.report_sequence
            and self.host_reported_at == other.host_reported_at
            and self.pool_reported_at == other.pool_reported_at
            and self.pool_reported_at == other.pool_reported_at
            and self.capacity == other.capacity
            and self.overhead_cores == other.overhead_cores
            and self.overhead_memory_bytes == other.overhead_memory_bytes
            and self.free_bytes == other.free_bytes
            and self.overhead_bytes == other.overhead_bytes
            and self.allocations == other.allocations
            and self.zpool_guid == other.zpool_guid
            and self.dataset_guid == other.dataset_guid
            and self.dataset == other.dataset
            and self.holds
            == tuple(hold for hold in other.holds if hold.placement_id != new_placement)
        )

    def available(self) -> tuple[int, int, int] | None:
        """@cc [owner:ghuntley,label:capacity] admission-budget-independent-arithmetic
        The oracle MUST use measured v1 CPU/memory headroom and actual pool free
        bytes, subtract host overhead and retained startup/temporary/resize
        holds, and grant no credit from settled virtual disk sizes. Missing or
        malformed usage MUST leave the budget unknown.
        """
        usage = self.capacity
        if usage is None or usage.get("version") != 1:
            return None
        cpu = usage.get("cpu_headroom_millicores")
        memory = usage.get("memory_headroom_bytes")
        if not _nonnegative_int(cpu) or not _nonnegative_int(memory):
            return None
        compute = [hold for hold in self.holds if hold.compute_held and hold.startup_compute_held]
        cpu_available = max(
            0, cpu // 1000 - self.overhead_cores - sum(hold.vcpu for hold in compute)
        )
        memory_available = max(
            0, memory - self.overhead_memory_bytes - sum(hold.memory_bytes for hold in compute)
        )
        pending = 0
        for hold in self.holds:
            if hold.pool_id != self.pool_id:
                continue
            creation = hold.disk_bytes if hold.disk_held and hold.startup_disk_held else 0
            raw_credit = self.allocations.get(str(hold.placement_id), 0)
            if not _nonnegative_int(raw_credit):
                return None
            pending += (
                creation
                - min(creation, raw_credit)
                + hold.temporary_disk_bytes
                + hold.pending_disk_bytes
            )
        disk_available = max(0, self.free_bytes - self.overhead_bytes - pending)
        return cpu_available, memory_available, disk_available

    def fresh(self, freshness_ms: int = 5000) -> bool:
        if self.host_reported_at is None or self.pool_reported_at is None:
            return False
        for sampled_at in (self.host_reported_at, self.pool_reported_at):
            age_ms = (self.observed_at - sampled_at).total_seconds() * 1000
            if not 0 <= age_ms <= freshness_ms:
                return False
        return True


class CapacityOracle:
    def __init__(self, sql: SqlOracle) -> None:
        self._sql = sql

    def pool_ids(self, host_id: UUID) -> Observation[tuple[UUID, ...]]:
        rows = self._sql.select(
            "SELECT id FROM compute_storage_pools WHERE host_id = %s::uuid ORDER BY id",
            (str(host_id),),
            maximum_rows=8,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        pools: list[UUID] = []
        for row in rows.value:
            if len(row) != 1 or not isinstance(row[0], UUID):
                return Observation.unavailable()
            pools.append(row[0])
        return Observation.observed(tuple(pools))

    def frame(self, host_id: UUID, pool_id: UUID) -> Observation[CapacityFrame | None]:
        """One PostgreSQL statement reads the report and all host holds consistently."""
        rows = self._sql.select(
            "SELECT h.id, p.id, clock_timestamp() AT TIME ZONE 'UTC', h.report_sequence, h.reported_at, "
            "p.reported_at, h.capacity, h.overhead_cores, h.overhead_memory_bytes, "
            "p.free_bytes, p.overhead_bytes, p.allocations, "
            "COALESCE((SELECT jsonb_agg(jsonb_build_object("
            "'id', r.id, 'placement_id', r.placement_id, 'pool_id', r.pool_id, "
            "'vcpu', r.vcpu, 'memory_bytes', r.memory_bytes, 'disk_bytes', r.disk_bytes, "
            "'compute_held', r.compute_held, 'disk_held', r.disk_held, "
            "'startup_compute_held', r.startup_compute_held, "
            "'startup_disk_held', r.startup_disk_held, "
            "'temporary_disk_bytes', r.temporary_disk_bytes, "
            "'pending_disk_bytes', r.pending_disk_bytes) ORDER BY r.id) "
            "FROM compute_reservations r WHERE r.host_id = h.id), '[]'::jsonb), "
            "p.zpool_guid, p.dataset_guid, p.dataset "
            "FROM compute_hosts h JOIN compute_storage_pools p ON p.host_id = h.id "
            "WHERE h.id = %s::uuid AND p.id = %s::uuid",
            (str(host_id), str(pool_id)),
            maximum_rows=1,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        if not rows.value:
            return Observation.observed(None)
        row = rows.value[0]
        if len(row) != 16:
            return Observation.unavailable()
        (
            host,
            pool,
            observed_at,
            sequence,
            host_at,
            pool_at,
            capacity,
            overhead_cores,
            overhead_memory,
            free_bytes,
            overhead_bytes,
            allocations,
            raw_holds,
            zpool_guid,
            dataset_guid,
            dataset,
        ) = row
        if (
            host != host_id
            or pool != pool_id
            or not isinstance(observed_at, datetime)
            or not _nonnegative_int(sequence)
            or (host_at is not None and not isinstance(host_at, datetime))
            or (pool_at is not None and not isinstance(pool_at, datetime))
            or (capacity is not None and not isinstance(capacity, dict))
            or not _nonnegative_int(overhead_cores)
            or not _nonnegative_int(overhead_memory)
            or not _nonnegative_int(free_bytes)
            or not _nonnegative_int(overhead_bytes)
            or not isinstance(allocations, dict)
            or not isinstance(raw_holds, list)
            or not isinstance(zpool_guid, str)
            or not isinstance(dataset_guid, str)
            or not isinstance(dataset, str)
        ):
            return Observation.unavailable()
        holds: list[Hold] = []
        for raw in raw_holds:
            parsed = _hold(raw)
            if parsed is None:
                return Observation.unavailable()
            holds.append(parsed)
        return Observation.observed(
            CapacityFrame(
                host_id,
                pool_id,
                observed_at,
                sequence,
                host_at,
                pool_at,
                capacity,
                overhead_cores,
                overhead_memory,
                free_bytes,
                overhead_bytes,
                allocations,
                tuple(holds),
                zpool_guid,
                dataset_guid,
                dataset,
            )
        )


def _nonnegative_int(value: object) -> TypeGuard[int]:
    return type(value) is int and value >= 0


def _hold(raw: object) -> Hold | None:
    if not isinstance(raw, dict):
        return None
    identifiers = (raw.get("id"), raw.get("placement_id"), raw.get("pool_id"))
    if not all(isinstance(item, str) for item in identifiers):
        return None
    try:
        reservation_id, placement_id, pool_id = (UUID(item) for item in identifiers)
    except (TypeError, ValueError):
        return None
    vcpu = raw.get("vcpu")
    memory = raw.get("memory_bytes")
    disk = raw.get("disk_bytes")
    temporary = raw.get("temporary_disk_bytes")
    pending = raw.get("pending_disk_bytes")
    compute_held = raw.get("compute_held")
    disk_held = raw.get("disk_held")
    startup_compute = raw.get("startup_compute_held")
    startup_disk = raw.get("startup_disk_held")
    if (
        not _nonnegative_int(vcpu)
        or not _nonnegative_int(memory)
        or not _nonnegative_int(disk)
        or not _nonnegative_int(temporary)
        or not _nonnegative_int(pending)
        or not isinstance(compute_held, bool)
        or not isinstance(disk_held, bool)
        or not isinstance(startup_compute, bool)
        or not isinstance(startup_disk, bool)
    ):
        return None
    return Hold(
        reservation_id,
        placement_id,
        pool_id,
        vcpu,
        memory,
        disk,
        compute_held,
        disk_held,
        startup_compute,
        startup_disk,
        temporary,
        pending,
    )
