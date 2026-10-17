"""Independent read-only snapshot of committed Galileo attachment authority."""

from uuid import UUID

from core.outcome import Observation, State
from core.sql import SqlOracle


class IntegrationAuthority:
    def __init__(self, sql: SqlOracle) -> None:
        self._sql = sql

    def attached(self, integration_id: UUID, vm_id: UUID) -> Observation[bool]:
        """@cc [owner:ghuntley,label:verification] attachment-commit-witness
        An operator receipt MUST be corroborated by a read-only current-pair
        snapshot before it is used as the revocation ordering boundary. Failed
        SQL or an impossible duplicate pair MUST remain unavailable.
        """
        rows = self._sql.select(
            "SELECT id FROM galileo_attachments "
            "WHERE integration_id = %s::uuid AND vm_id = %s::uuid AND archived_at IS NULL",
            (str(integration_id), str(vm_id)),
            maximum_rows=2,
        )
        if rows.state is not State.OBSERVED or rows.value is None or len(rows.value) > 1:
            return Observation.unavailable()
        if rows.value and (len(rows.value[0]) != 1 or not isinstance(rows.value[0][0], UUID)):
            return Observation.unavailable()
        return Observation.observed(bool(rows.value))
