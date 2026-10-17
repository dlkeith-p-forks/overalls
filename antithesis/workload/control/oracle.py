"""Read-only durable witnesses for Lilly Control session and credential effects."""

import re
from dataclasses import dataclass
from uuid import UUID

from core.outcome import Observation, State
from core.sql import SqlOracle

_MACHINE = re.compile(r"sha256:[0-9a-f]{64}\Z")


@dataclass(frozen=True)
class CredentialAuthority:
    active_id: UUID | None
    old_archived: bool


@dataclass(frozen=True)
class HostSession:
    session_id: UUID
    epoch: int


class ControlOracle:
    def __init__(self, sql: SqlOracle) -> None:
        self._sql = sql

    def machine_id(self, host_id: UUID) -> Observation[str]:
        rows = self._sql.select(
            "SELECT machine_id FROM compute_hosts WHERE id = %s::uuid",
            (str(host_id),),
            maximum_rows=1,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        if len(rows.value) != 1 or len(rows.value[0]) != 1:
            return Observation.unavailable()
        value = rows.value[0][0]
        if not isinstance(value, str) or not _MACHINE.fullmatch(value):
            return Observation.unavailable()
        return Observation.observed(value)

    def session_exists(self, host_id: UUID, session_id: UUID) -> Observation[bool]:
        """@cc [owner:ghuntley,label:verification] control-session-durable-witness
        A successful bounded SELECT of the specific fresh session ID is the
        effect witness. Oracle unavailability MUST remain unknown and MUST NOT
        be converted to absence, including after a lost response.
        """
        rows = self._sql.select(
            "SELECT id FROM compute_host_sessions WHERE id = %s::uuid AND host_id = %s::uuid",
            (str(session_id), str(host_id)),
            maximum_rows=1,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        if not rows.value:
            return Observation.observed(False)
        if len(rows.value) != 1 or len(rows.value[0]) != 1:
            return Observation.unavailable()
        value = rows.value[0][0]
        if not isinstance(value, UUID) or value != session_id:
            return Observation.unavailable()
        return Observation.observed(True)

    def current_host_session(self, host_id: UUID) -> Observation[HostSession | None]:
        rows = self._sql.select(
            "SELECT connection_session_id, connection_epoch FROM compute_hosts WHERE id = %s::uuid",
            (str(host_id),),
            maximum_rows=1,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        if len(rows.value) != 1 or len(rows.value[0]) != 2:
            return Observation.unavailable()
        session, epoch = rows.value[0]
        if session is None:
            return Observation.observed(None)
        if not isinstance(session, UUID) or type(epoch) is not int or epoch < 1:
            return Observation.unavailable()
        return Observation.observed(HostSession(session, epoch))

    def credential_authority(
        self, host_id: UUID, old_credential_id: UUID
    ) -> Observation[CredentialAuthority]:
        rows = self._sql.select(
            "SELECT id, archived_at IS NULL, expires_at > now() "
            "FROM compute_host_credentials WHERE host_id = %s::uuid "
            "AND (id = %s::uuid OR archived_at IS NULL)",
            (str(host_id), str(old_credential_id)),
            maximum_rows=2,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        old_archived = False
        active: UUID | None = None
        for row in rows.value:
            identifier = row[0] if len(row) == 3 else None
            current = row[1] if len(row) == 3 else None
            unexpired = row[2] if len(row) == 3 else None
            if (
                len(row) != 3
                or not isinstance(identifier, UUID)
                or not isinstance(current, bool)
                or not isinstance(unexpired, bool)
            ):
                return Observation.unavailable()
            if identifier == old_credential_id:
                old_archived = not current
            if current and unexpired:
                if active is not None:
                    return Observation.unavailable()
                active = identifier
        return Observation.observed(CredentialAuthority(active, old_archived))

    def active_credential_id(self, host_id: UUID) -> Observation[UUID | None]:
        rows = self._sql.select(
            "SELECT id FROM compute_host_credentials WHERE host_id = %s::uuid "
            "AND archived_at IS NULL AND expires_at > now()",
            (str(host_id),),
            maximum_rows=1,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        if not rows.value:
            return Observation.observed(None)
        if len(rows.value) != 1 or len(rows.value[0]) != 1:
            return Observation.unavailable()
        value = rows.value[0][0]
        if not isinstance(value, UUID):
            return Observation.unavailable()
        return Observation.observed(value)
