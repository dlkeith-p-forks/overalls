"""Independent SQL and fixed native Git observations for Enrico properties."""

import logging
import os
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from uuid import UUID

from core.outcome import Observation, State
from core.sql import SqlOracle

LOG = logging.getLogger(__name__)
SHA = re.compile(r"[0-9a-f]{40,64}\Z")
# The workload image links Git here; it is not on PATH (run 30a420d501d5d6d22527e679a7f00005-65-0).
GIT = Path("/opt/overalls/git/bin/git")


@dataclass(frozen=True)
class Published:
    repository_id: UUID
    phase: str
    head: str | None
    attempt_id: UUID | None


class RepositoryOracle:
    def __init__(self, sql: SqlOracle, mirror_root: Path) -> None:
        self._sql = sql
        self._mirror_root = mirror_root

    def published(self, repository_id: UUID) -> Observation[Published | None]:
        rows = self._sql.select(
            "SELECT phase, head, attempt_id FROM enrico_repositories WHERE id = %s::uuid",
            (str(repository_id),),
            maximum_rows=1,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        if not rows.value:
            return Observation.observed(None)
        phase, head, attempt = rows.value[0]
        if (
            not isinstance(phase, str)
            or phase not in ("pending", "refreshing", "ready", "failed", "removing")
            or (head is not None and (not isinstance(head, str) or SHA.fullmatch(head) is None))
            or (attempt is not None and not isinstance(attempt, UUID))
        ):
            return Observation.unavailable()
        return Observation.observed(Published(repository_id, phase, head, attempt))

    def marshall_refresh_marker(self) -> Observation[tuple[int, datetime | None]]:
        """@cc [owner:ghuntley,label:verification] enrico-foreign-fetch-fence
        Origin receipts carry no requester identity, so a window MAY be
        attributed to one Enrico attempt only if Marshall started no refresh of
        its own in it: no repository is refreshing and the latest committed
        begin_refresh time is unchanged across the window.
        """
        rows = self._sql.select(
            "SELECT count(*) FILTER (WHERE phase = 'refreshing'), max(last_attempt_at) "
            "FROM enrico_repositories",
            (),
            maximum_rows=1,
        )
        if rows.state is not State.OBSERVED or rows.value is None or len(rows.value) != 1:
            return Observation.unavailable()
        refreshing, latest = rows.value[0]
        if type(refreshing) is not int or (latest is not None and not isinstance(latest, datetime)):
            return Observation.unavailable()
        return Observation.observed((refreshing, latest))

    def failure_audit(self, repository_id: UUID, attempt_id: UUID) -> Observation[bool]:
        rows = self._sql.select(
            "SELECT kind FROM enrico_audit_events WHERE repository_id = %s::uuid "
            "AND attempt_id = %s::uuid AND kind = 'refresh_failed' LIMIT 1",
            (str(repository_id), str(attempt_id)),
            maximum_rows=1,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        return Observation.observed(bool(rows.value))

    def blob(self, repository_id: UUID, head: str) -> Observation[bytes]:
        """@cc [owner:ghuntley,label:verification] enrico-native-object-witness
        Only the validated fixture SHA and fixed README blob may be read from the
        service-owned bare mirror. A missing mirror, failed Git read or timeout
        MUST remain unknown unless the mirror path is confirmed mounted and ready.
        """
        if SHA.fullmatch(head) is None:
            raise ValueError("invalid commit SHA")
        root = self._mirror_root / f"{repository_id}.git"
        if not root.is_dir():
            return Observation.unavailable()
        environment = os.environ.copy()
        environment.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"})
        try:
            healthy = subprocess.run(
                [str(GIT), f"--git-dir={root}", "rev-parse", "--is-bare-repository"],
                capture_output=True,
                check=False,
                timeout=5,
                env=environment,
            )
            if healthy.returncode != 0 or healthy.stdout.strip() != b"true":
                return Observation.unavailable()
            result = subprocess.run(
                [str(GIT), f"--git-dir={root}", "cat-file", "blob", f"{head}:README.md"],
                capture_output=True,
                check=False,
                timeout=5,
                env=environment,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            LOG.info("Enrico native Git read unavailable: %s", type(error).__name__)
            return Observation.unavailable()
        if result.returncode != 0:
            return Observation.refused(404)
        if len(result.stdout) > 1024:
            return Observation.unavailable()
        return Observation.observed(result.stdout)
