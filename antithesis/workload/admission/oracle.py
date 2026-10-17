"""Consistent, bounded PostgreSQL witnesses for durable admission identity."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import TYPE_CHECKING, TypeGuard
from uuid import UUID

from core.outcome import Observation, State

if TYPE_CHECKING:
    from core.sql import SqlOracle


@dataclass(frozen=True)
class Allocation:
    vm_id: UUID
    owner_id: UUID
    key: str
    archived: bool
    generation: int
    placement_id: UUID
    host_id: UUID
    pool_id: UUID
    placements: int
    matching_reservations: int
    addresses: int
    provision_operations: int
    dispatch_jobs: int
    version_rows: int

    def joined_at_admission(self) -> bool:
        """Check the immutable first allocation before job retention or archive cleanup."""
        return (
            self.placements == 1
            and self.matching_reservations == 1
            and self.addresses == 1
            and self.provision_operations == 1
            and self.dispatch_jobs == 1
        )


@dataclass(frozen=True)
class Recovery:
    vm_id: UUID
    generation: int
    observed_state: str
    failure_reason: str | None
    archived: bool
    crash_restart_times: tuple[datetime, ...]
    compute_held: bool
    disk_held: bool
    recovery_starts: int
    pending_operations: int


class AdmissionOracle:
    def __init__(self, sql: SqlOracle) -> None:
        self._sql = sql

    def archived(self, vm_id: UUID) -> Observation[bool | None]:
        """Observe VM history without requiring cleanup-retired child rows."""
        rows = self._sql.select(
            "SELECT archived_at IS NOT NULL FROM compute_virtual_machines WHERE id = %s::uuid",
            (str(vm_id),),
            maximum_rows=1,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        if not rows.value:
            return Observation.observed(None)
        if (
            len(rows.value) != 1
            or len(rows.value[0]) != 1
            or not isinstance(rows.value[0][0], bool)
        ):
            return Observation.unavailable()
        return Observation.observed(rows.value[0][0])

    def allocation(self, owner_id: UUID, key: str) -> Observation[tuple[Allocation, ...]]:
        """@cc [owner:ghuntley,label:verification] admission-key-snapshot
        A successful one-statement SELECT MUST include archived VM history and
        correlated placement, reservation, address, operation, job and version
        rows. Missing SQL access MUST remain unknown; an empty result is a
        definite absent owner/key only after a successful query.
        """
        if not key or len(key) > 128:
            raise ValueError("invalid admission key")
        rows = self._sql.select(
            "SELECT vm.id, vm.owner_id, vm.idempotency_key, vm.archived_at IS NOT NULL, "
            "vm.generation, vm.current_placement_id, pl.host_id, pl.pool_id, "
            "(SELECT count(*) FROM compute_workload_placements p WHERE p.vm_id = vm.id "
            "AND p.id = vm.current_placement_id), "
            "(SELECT count(*) FROM compute_reservations r WHERE r.vm_id = vm.id "
            "AND r.placement_id = vm.current_placement_id AND r.host_id = pl.host_id "
            "AND r.pool_id = pl.pool_id), "
            "(SELECT count(*) FROM compute_network_addresses a WHERE a.vm_id = vm.id), "
            "(SELECT count(*) FROM compute_operations o WHERE o.vm_id = vm.id "
            "AND o.kind = 'provision' AND o.generation = 1 "
            "AND o.placement_id = vm.current_placement_id), "
            "(SELECT count(*) FROM oban_jobs j JOIN compute_operations o "
            "ON j.args->'primary_key'->>'id' = o.id::text "
            "WHERE o.vm_id = vm.id AND o.kind = 'provision' AND o.generation = 1 "
            "AND o.placement_id = vm.current_placement_id "
            "AND j.queue = 'provisioning' "
            "AND j.worker = 'Marshall.Compute.Workers.Dispatch'), "
            "(SELECT count(*) FROM compute_virtual_machines_versions v "
            "WHERE v.version_source_id = vm.id) "
            "FROM compute_virtual_machines vm "
            # Host and pool moved to the placement row; VirtualMachine only calculates them.
            "LEFT JOIN compute_workload_placements pl ON pl.id = vm.current_placement_id "
            "AND pl.vm_id = vm.id WHERE vm.owner_id = %s::uuid "
            "AND vm.idempotency_key = %s ORDER BY vm.id",
            (str(owner_id), key),
            maximum_rows=8,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        allocations: list[Allocation] = []
        for row in rows.value:
            if len(row) != 14:
                return Observation.unavailable()
            (
                vm_id,
                owner,
                row_key,
                archived,
                generation,
                placement,
                host,
                pool,
                placements,
                reservations,
                addresses,
                operations,
                jobs,
                versions,
            ) = row
            if (
                not isinstance(vm_id, UUID)
                or owner != owner_id
                or not isinstance(owner, UUID)
                or row_key != key
                or not isinstance(row_key, str)
                or not isinstance(archived, bool)
                or not isinstance(placement, UUID)
                or not isinstance(host, UUID)
                or not isinstance(pool, UUID)
            ):
                return Observation.unavailable()
            if not (
                _nonnegative_int(generation)
                and _nonnegative_int(placements)
                and _nonnegative_int(reservations)
                and _nonnegative_int(addresses)
                and _nonnegative_int(operations)
                and _nonnegative_int(jobs)
                and _nonnegative_int(versions)
            ):
                return Observation.unavailable()
            allocations.append(
                Allocation(
                    vm_id,
                    owner,
                    row_key,
                    archived,
                    generation,
                    placement,
                    host,
                    pool,
                    placements,
                    reservations,
                    addresses,
                    operations,
                    jobs,
                    versions,
                )
            )
        return Observation.observed(tuple(allocations))

    def recovery(self, vm_id: UUID) -> Observation[Recovery | None]:
        """Read retained budget and authorized recovery starts in one SQL snapshot."""
        rows = self._sql.select(
            "SELECT vm.id, vm.generation, vm.observed_state, vm.failure_reason, "
            "vm.archived_at IS NOT NULL, vm.crash_restart_times, "
            "r.compute_held, r.disk_held, "
            "(SELECT count(*) FROM compute_operations o WHERE o.vm_id = vm.id "
            "AND o.kind = 'start' AND o.initiator = 'recovery'), "
            "(SELECT count(*) FROM compute_operations o WHERE o.vm_id = vm.id "
            "AND o.status IN ('pending', 'acknowledged')) "
            "FROM compute_virtual_machines vm LEFT JOIN compute_reservations r "
            "ON r.vm_id = vm.id AND r.placement_id = vm.current_placement_id "
            "WHERE vm.id = %s::uuid",
            (str(vm_id),),
            maximum_rows=1,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        if not rows.value:
            return Observation.observed(None)
        row = rows.value[0]
        if (
            len(row) != 10
            or row[0] != vm_id
            or type(row[1]) is not int
            or not isinstance(row[2], str)
            or (row[3] is not None and not isinstance(row[3], str))
            or not isinstance(row[4], bool)
            or not isinstance(row[5], list)
            or not all(isinstance(item, datetime) for item in row[5])
            or not isinstance(row[6], bool)
            or not isinstance(row[7], bool)
            or type(row[8]) is not int
            or type(row[9]) is not int
        ):
            return Observation.unavailable()
        return Observation.observed(
            Recovery(
                vm_id, row[1], row[2], row[3], row[4], tuple(row[5]), row[6], row[7], row[8], row[9]
            )
        )


def _nonnegative_int(value: object) -> TypeGuard[int]:
    return type(value) is int and value >= 0
