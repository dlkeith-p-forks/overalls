"""Read-only terminal create receipts from Marshall's durable registry."""

from dataclasses import dataclass
from uuid import UUID

from core.outcome import Observation, State
from core.sql import SqlOracle


@dataclass(frozen=True)
class Opening:
    request_id: UUID
    vm_id: UUID
    actor_id: UUID
    placement_id: UUID
    execution_epoch: int
    status: str
    session_id: UUID | None


@dataclass(frozen=True)
class Session:
    session_id: UUID
    vm_id: UUID
    owner_id: UUID
    placement_id: UUID
    execution_epoch: int
    guest_session_id: int
    live: bool


@dataclass(frozen=True)
class OpenedReceipt:
    event_id: UUID
    vm_id: UUID
    actor_id: UUID | None
    session_id: UUID
    guest_session_id: int


@dataclass(frozen=True)
class HostConnection:
    session_id: UUID
    epoch: int


@dataclass(frozen=True)
class CreateHistory:
    opening: Opening | None
    sessions: tuple[Session, ...]
    opened: tuple[OpenedReceipt, ...]

    def settled_consistent(self) -> bool:
        """Check durable identities only; this says nothing about PTY births."""
        if self.opening is None:
            return not self.sessions and not self.opened
        opening = self.opening
        if opening.status == "ready":
            if opening.session_id is None or len(self.sessions) != 1 or len(self.opened) != 1:
                return False
            session, receipt = self.sessions[0], self.opened[0]
            return (
                session.session_id == opening.session_id == receipt.session_id
                and session.vm_id == opening.vm_id == receipt.vm_id
                and session.owner_id == opening.actor_id == receipt.actor_id
                and session.placement_id == opening.placement_id
                and session.execution_epoch == opening.execution_epoch
                and session.guest_session_id == receipt.guest_session_id
            )
        if opening.status in ("pending", "cancelling", "failed"):
            return opening.session_id is None and not self.sessions and not self.opened
        return False


class TerminalOracle:
    def __init__(self, sql: SqlOracle) -> None:
        self._sql = sql

    def vm_for_provision_key(self, owner_id: UUID, key: UUID) -> Observation[UUID | None]:
        """Reconcile a lost provision reply before attempting VM cleanup."""
        rows = self._sql.select(
            "SELECT id FROM compute_virtual_machines "
            "WHERE owner_id = %s::uuid AND idempotency_key = %s",
            (str(owner_id), str(key)),
            maximum_rows=2,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        if not rows.value:
            return Observation.observed(None)
        if (
            len(rows.value) != 1
            or len(rows.value[0]) != 1
            or not isinstance(rows.value[0][0], UUID)
        ):
            return Observation.unavailable()
        return Observation.observed(rows.value[0][0])

    def host_connection(self, host_id: UUID) -> Observation[HostConnection]:
        """Read the current host socket identity immediately before replay arm."""
        rows = self._sql.select(
            "SELECT connection_session_id, connection_epoch FROM compute_hosts WHERE id = %s::uuid",
            (str(host_id),),
            maximum_rows=1,
        )
        if rows.state is not State.OBSERVED or rows.value is None or len(rows.value) != 1:
            return Observation.unavailable()
        row = rows.value[0]
        if len(row) != 2 or not isinstance(row[0], UUID) or type(row[1]) is not int or row[1] < 1:
            return Observation.unavailable()
        return Observation.observed(HostConnection(row[0], row[1]))

    def vm_archived(self, vm_id: UUID) -> Observation[bool]:
        """Read committed VM retirement; archival follows physical reclaim."""
        rows = self._sql.select(
            "SELECT archived_at IS NOT NULL FROM compute_virtual_machines WHERE id = %s::uuid",
            (str(vm_id),),
            maximum_rows=1,
        )
        if (
            rows.state is not State.OBSERVED
            or rows.value is None
            or len(rows.value) != 1
            or len(rows.value[0]) != 1
            or type(rows.value[0][0]) is not bool
        ):
            return Observation.unavailable()
        return Observation.observed(rows.value[0][0])

    def create_history(self, request_id: UUID) -> Observation[CreateHistory]:
        """@cc [owner:ghuntley,label:verification] terminal-receipt-is-not-pty-proof
        A complete SQL snapshot MUST bind one opening, registry session and
        opened receipt by the immutable request ID. SQL alone MUST NOT claim a
        guest PTY birth, consumed terminal input or physical ring allocation.
        Missing/failed SQL reads MUST remain unavailable.
        """
        rows = self._sql.select(
            "SELECT o.id, o.vm_id, o.actor_id, o.placement_id, o.execution_epoch, "
            "o.status, o.session_id, s.id, s.vm_id, s.owner_id, s.placement_id, "
            "s.execution_epoch, s.guest_session_id, s.archived_at IS NULL, "
            "e.id, e.vm_id, e.actor_id, e.session_id, e.guest_session_id "
            "FROM terminal_openings o "
            "LEFT JOIN terminal_sessions s ON s.id = o.session_id "
            "LEFT JOIN terminal_events e ON e.request_id = o.id::text AND e.kind = 'opened' "
            "WHERE o.id = %s::uuid",
            (str(request_id),),
            maximum_rows=16,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        if not rows.value:
            return Observation.observed(CreateHistory(None, (), ()))
        first = rows.value[0]
        if len(first) != 19 or any(len(row) != 19 or row[:7] != first[:7] for row in rows.value):
            return Observation.unavailable()
        request, vm, actor, placement, epoch, status, session_id = first[:7]
        if not (
            isinstance(request, UUID)
            and isinstance(vm, UUID)
            and isinstance(actor, UUID)
            and isinstance(placement, UUID)
            and type(epoch) is int
            and epoch > 0
            and isinstance(status, str)
            and (session_id is None or isinstance(session_id, UUID))
        ):
            return Observation.unavailable()
        opening = Opening(request, vm, actor, placement, epoch, status, session_id)
        sessions: dict[UUID, Session] = {}
        opened: dict[UUID, OpenedReceipt] = {}
        for row in rows.value:
            if row[7] is not None:
                sid, vm_id, owner, place, session_epoch, guest_id, live = row[7:14]
                if not (
                    isinstance(sid, UUID)
                    and isinstance(vm_id, UUID)
                    and isinstance(owner, UUID)
                    and isinstance(place, UUID)
                    and type(session_epoch) is int
                    and session_epoch > 0
                    and type(guest_id) is int
                    and guest_id > 0
                    and type(live) is bool
                ):
                    return Observation.unavailable()
                session = Session(sid, vm_id, owner, place, session_epoch, guest_id, live)
                sessions[session.session_id] = session
            if row[14] is not None:
                event_id, event_vm, event_actor, event_session, event_guest = row[14:19]
                if not (
                    isinstance(event_id, UUID)
                    and isinstance(event_vm, UUID)
                    and (event_actor is None or isinstance(event_actor, UUID))
                    and isinstance(event_session, UUID)
                    and type(event_guest) is int
                    and event_guest > 0
                ):
                    return Observation.unavailable()
                receipt = OpenedReceipt(event_id, event_vm, event_actor, event_session, event_guest)
                opened[receipt.event_id] = receipt
        return Observation.observed(
            CreateHistory(opening, tuple(sessions.values()), tuple(opened.values()))
        )
