"""Independent read-only PostgreSQL observation of migration and host authority."""

import logging
from collections.abc import Sequence
from dataclasses import dataclass
from typing import LiteralString
from uuid import UUID

import psycopg

from core.config import Config
from core.outcome import Observation

LOGGER = logging.getLogger(__name__)
_REPORTED_SQLSTATES: set[str] = set()


@dataclass(frozen=True)
class HostAuthority:
    host_id: UUID
    report_sequence: int
    connected: bool
    report_fresh: bool


class SqlOracle:
    def __init__(self, config: Config) -> None:
        self._config = config

    def _connect(self) -> psycopg.Connection[tuple[object, ...]]:
        password = self._config.db_password_file.read_text(encoding="utf-8").strip()
        if not password:
            raise ValueError("empty database password file")
        return psycopg.connect(
            host=self._config.db_host,
            port=self._config.db_port,
            user=self._config.db_user,
            dbname=self._config.db_name,
            password=password,
            sslmode="verify-full",
            sslrootcert=str(self._config.ca_file),
            connect_timeout=5,
            options="-c default_transaction_read_only=on -c statement_timeout=5000",
        )

    def select(
        self,
        statement: LiteralString,
        parameters: Sequence[object] = (),
        *,
        maximum_rows: int = 4096,
    ) -> Observation[tuple[tuple[object, ...], ...]]:
        """@cc [owner:ghuntley,label:security;verification] oracle-select-only
        Oracle queries MUST use a fresh read-only transaction, bind parameters,
        and refuse non-SELECT statements. Query errors and oversized results
        MUST remain UNAVAILABLE rather than being treated as empty results.
        """
        if not statement.lstrip().upper().startswith("SELECT ") or maximum_rows < 1:
            raise ValueError("oracle accepts bounded SELECT queries only")
        try:
            with self._connect() as connection, connection.cursor() as cursor:
                cursor.execute(statement, tuple(parameters))
                rows = cursor.fetchmany(maximum_rows + 1)
                if len(rows) > maximum_rows:
                    return Observation.unavailable()
                return Observation.observed(tuple(rows))
        except psycopg.Error as error:
            # Name only the SQLSTATE class, once per state, so schema drift is visible.
            state = error.sqlstate or "unknown"
            if state not in _REPORTED_SQLSTATES:
                _REPORTED_SQLSTATES.add(state)
                LOGGER.warning("oracle select failed: sqlstate=%s", state)
            return Observation.unavailable()
        except (OSError, ValueError):
            return Observation.unavailable()

    def migrated_primary(self, version: int) -> Observation[bool]:
        """@cc [owner:ghuntley,label:verification] oracle-missing-is-unknown
        Failed SQL access MUST return UNAVAILABLE. A successful query with a
        missing/mismatching row is a definite observation, never silently skipped.
        """
        try:
            with self._connect() as connection, connection.cursor() as cursor:
                cursor.execute(
                    "SELECT NOT pg_is_in_recovery() AND "
                    "COALESCE((SELECT max(version) FROM schema_migrations) = %s, false)",
                    (version,),
                )
                row = cursor.fetchone()
                if row is None or len(row) != 1 or not isinstance(row[0], bool):
                    return Observation.unavailable()
                return Observation.observed(row[0])
        except (OSError, psycopg.Error, ValueError):
            return Observation.unavailable()

    def host_authority(self, host_id: UUID) -> Observation[HostAuthority | None]:
        """@cc [owner:ghuntley,label:verification] bootstrap-host-session-witness
        A ready host MUST have a bounded-fresh ordered report and a current session whose
        durable host and epoch binding matches the compute host row. A missing
        host MUST NOT establish readiness; malformed rows and query errors
        MUST remain unavailable.
        """
        try:
            with self._connect() as connection, connection.cursor() as cursor:
                cursor.execute(
                    "SELECT h.report_sequence, "
                    "EXISTS (SELECT 1 FROM compute_host_sessions s "
                    "WHERE s.id = h.connection_session_id AND s.host_id = h.id "
                    "AND s.epoch = h.connection_epoch), "
                    "h.reported_at IS NOT NULL AND "
                    "h.reported_at > now() - interval '60 seconds' AND "
                    "h.reported_at <= now() "
                    "FROM compute_hosts h WHERE h.id = %s::uuid",
                    (str(host_id),),
                )
                row = cursor.fetchone()
                if row is None:
                    return Observation.observed(None)
                if (
                    len(row) != 3
                    or type(row[0]) is not int
                    or not isinstance(row[1], bool)
                    or not isinstance(row[2], bool)
                ):
                    return Observation.unavailable()
                return Observation.observed(HostAuthority(host_id, row[0], row[1], row[2]))
        except (OSError, psycopg.Error, ValueError):
            return Observation.unavailable()
