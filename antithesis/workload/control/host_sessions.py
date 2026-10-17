"""Committed host-session fences over two real Marshall Control listeners."""

import logging
import os
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from uuid import UUID

from antithesis.assertions import always, reachable

from control.client import ControlSession, ControlWire, RequestResult, WireState
from control.credential import LillyCredential, find_current_credential
from control.identifiers import session_id
from control.oracle import ControlOracle
from control.rotation import RotationCoordinator
from core.config import Config, read_fixture
from core.outcome import Observation, State
from core.sql import SqlOracle

LOG = logging.getLogger(__name__)
_DIGEST = re.compile(r"[0-9a-f]{32}\Z")


@dataclass(frozen=True)
class HostSnapshot:
    session_id: UUID | None
    epoch: int
    report_sequence: int
    reported_at: datetime | None
    session_count: int
    operation_digest: str
    outcome_digest: str
    reservation_digest: str


@dataclass(frozen=True)
class Fixture:
    config: Config
    host_id: UUID
    machine_id: str
    credential: LillyCredential
    credential_path: Path
    sql: SqlOracle
    oracle: ControlOracle


def _fixture() -> Fixture | None:
    config = Config.from_environment()
    manifest = read_fixture(config.fixture_manifest)
    if len(manifest.host_ids) != 1 or len(config.marshall_urls) < 2:
        raise ValueError("host fence needs one host and two Marshall listeners")
    host_id = manifest.host_ids[0]
    path = Path(os.environ["ANTITHESIS_CONTROL_CREDENTIAL_FILE"])
    sql = SqlOracle(config)
    oracle = ControlOracle(sql)
    machine = oracle.machine_id(host_id)
    active = oracle.active_credential_id(host_id)
    if (
        machine.state is not State.OBSERVED
        or machine.value is None
        or active.state is not State.OBSERVED
        or active.value is None
    ):
        return None
    credential = find_current_credential(path, host_id, active.value)
    if credential is None:
        return None
    return Fixture(config, host_id, machine.value, credential, path, sql, oracle)


def _snapshot(sql: SqlOracle, host_id: UUID) -> Observation[HostSnapshot]:
    """@cc [owner:ghuntley,label:verification] host-fence-committed-snapshot
    Fence verdicts MUST compare one fresh read-only SQL statement before and
    after a settled request. Missing or malformed rows MUST remain unavailable.
    The digest covers full operation, outcome and reservation rows, without
    exposing their contents to diagnostics.
    """
    rows = sql.select(
        "SELECT h.connection_session_id, h.connection_epoch, h.report_sequence, "
        "h.reported_at, "
        "(SELECT count(*) FROM compute_host_sessions s WHERE s.host_id = h.id), "
        "(SELECT md5(coalesce(string_agg(row_to_json(o)::text, ',' ORDER BY o.id), '')) "
        "FROM compute_operations o JOIN compute_workload_placements p "
        "ON p.id = o.placement_id WHERE p.host_id = h.id), "
        "(SELECT md5(coalesce(string_agg(row_to_json(x)::text, ',' ORDER BY x.id), '')) "
        "FROM compute_physical_outcomes x WHERE x.host_id = h.id), "
        "(SELECT md5(coalesce(string_agg(row_to_json(r)::text, ',' ORDER BY r.id), '')) "
        "FROM compute_reservations r WHERE r.host_id = h.id) "
        "FROM compute_hosts h WHERE h.id = %s::uuid",
        (str(host_id),),
        maximum_rows=1,
    )
    if rows.state is not State.OBSERVED or rows.value is None or len(rows.value) != 1:
        return Observation.unavailable()
    row = rows.value[0]
    if len(row) != 8:
        return Observation.unavailable()
    current, epoch, sequence, reported, sessions, operations, outcomes, reservations = row
    if (
        (current is not None and not isinstance(current, UUID))
        or type(epoch) is not int
        or epoch < 0
        or type(sequence) is not int
        or sequence < 0
        or (reported is not None and not isinstance(reported, datetime))
        or type(sessions) is not int
        or sessions < 0
        or not isinstance(operations, str)
        or _DIGEST.fullmatch(operations) is None
        or not isinstance(outcomes, str)
        or _DIGEST.fullmatch(outcomes) is None
        or not isinstance(reservations, str)
        or _DIGEST.fullmatch(reservations) is None
    ):
        return Observation.unavailable()
    return Observation.observed(
        HostSnapshot(
            current, epoch, sequence, reported, sessions, operations, outcomes, reservations
        )
    )


def _open(fixture: Fixture, origin: str, credential: LillyCredential) -> ControlSession | None:
    opened = ControlWire(origin, fixture.config.ca_file, credential).open()
    if opened.session is None:
        return None
    session = opened.session
    welcome = session.bind_lilly(str(fixture.host_id))
    if welcome.state is not WireState.MESSAGE or not session.welcomed:
        session.close()
        return None
    return session


def _session_body(fixture: Fixture, nonce: UUID) -> dict[str, object]:
    return {"version": 4, "session_id": str(nonce), "machine_id": fixture.machine_id}


def _exchange_body(nonce: UUID, epoch: int) -> dict[str, object]:
    # The controlled pool is unavailable. No synthetic capacity or physical
    # outcome is fabricated to make a report appear current.
    return {
        "version": 4,
        "session_id": str(nonce),
        "epoch": epoch,
        "report": None,
        "acknowledgements": [],
        "outcomes": [],
    }


def _opened(result: RequestResult, nonce: UUID) -> int | None:
    response = result.response
    if not result.acknowledged or response is None or response.get("ok") is not True:
        return None
    body = response.get("body")
    if (
        not isinstance(body, dict)
        or body.get("session_id") != str(nonce)
        or body.get("version") != 4
        or type(body.get("epoch")) is not int
        or body["epoch"] < 1
    ):
        return None
    return body["epoch"]


def _exchange_accepted(result: RequestResult, nonce: UUID, epoch: int) -> bool:
    body = result.response.get("body") if result.response else None
    return bool(
        result.acknowledged
        and result.response is not None
        and result.response.get("ok") is True
        and isinstance(body, dict)
        and body.get("session_id") == str(nonce)
        and body.get("epoch") == epoch
        and isinstance(body.get("commands"), list)
    )


def _stale_verdict(
    before: HostSnapshot,
    after: Observation[HostSnapshot],
    request: RequestResult,
) -> bool | None:
    """@cc [owner:ghuntley,label:verification] host-fence-no-side-effects
    A stale request MUST have a definite refusal and unchanged committed
    host/session, report, operation, outcome and reservation witness to pass.
    Lost replies or unavailable SQL MUST remain unknown unless a forbidden
    committed change was observed.
    """
    if after.state is not State.OBSERVED or after.value is None:
        return None
    if before != after.value:
        return False
    if not request.acknowledged:
        return None
    return request.response is not None and request.response.get("ok") is False


def run_session_successor() -> int:
    fixture = _fixture()
    if fixture is None:
        LOG.info("Host successor property unexercised: fixture unavailable")
        return 0
    first, second = fixture.config.marshall_urls[:2]
    a = _open(fixture, first, fixture.credential)
    if a is None:
        return 0
    try:
        a_nonce = session_id()
        a_epoch = _opened(a.exchange(1, "lilly.sessions", _session_body(fixture, a_nonce)), a_nonce)
        if a_epoch is None:
            return 0
        if not _exchange_accepted(
            a.exchange(2, "lilly.exchange", _exchange_body(a_nonce, a_epoch)), a_nonce, a_epoch
        ):
            return 0
        b = _open(fixture, second, fixture.credential)
        if b is None:
            return 0
        try:
            b_nonce = session_id()
            b_epoch = _opened(
                b.exchange(1, "lilly.sessions", _session_body(fixture, b_nonce)), b_nonce
            )
            if b_epoch is None:
                return 0
            successor = _snapshot(fixture.sql, fixture.host_id)
            if (
                successor.state is not State.OBSERVED
                or successor.value is None
                or successor.value.session_id != b_nonce
                or successor.value.epoch != b_epoch
                or b_epoch <= a_epoch
            ):
                return 0
            # An exact replay of the consumed nonce cannot replace B.
            replay = a.exchange(3, "lilly.sessions", _session_body(fixture, a_nonce))
            after_replay = _snapshot(fixture.sql, fixture.host_id)
            replay_verdict: bool | None = None
            if (
                after_replay.state is State.OBSERVED
                and after_replay.value is not None
                and after_replay.value.session_id in {a_nonce, b_nonce}
            ):
                replay_verdict = _stale_verdict(successor.value, after_replay, replay)
            before_stale = _snapshot(fixture.sql, fixture.host_id)
            stale_verdict: bool | None = None
            if (
                before_stale.state is State.OBSERVED
                and before_stale.value is not None
                and before_stale.value.session_id == b_nonce
            ):
                stale = a.exchange(4, "lilly.exchange", _exchange_body(a_nonce, a_epoch))
                after_stale = _snapshot(fixture.sql, fixture.host_id)
                if (
                    after_stale.state is State.OBSERVED
                    and after_stale.value is not None
                    and after_stale.value.session_id in {a_nonce, b_nonce}
                ):
                    stale_verdict = _stale_verdict(before_stale.value, after_stale, stale)
                if stale.acknowledged and _exchange_accepted(
                    b.exchange(2, "lilly.exchange", _exchange_body(b_nonce, b_epoch)),
                    b_nonce,
                    b_epoch,
                ):
                    reachable("Successor host session made progress after old nonce replay")
            if stale_verdict is not None or replay_verdict is False:
                always(
                    replay_verdict is not False and stale_verdict is not False,
                    "Superseded Lilly host session cannot change exchange state or dispatch work",
                )
            return 0
        finally:
            b.close()
    finally:
        a.close()


def run_credential_rotation() -> int:
    """Rotate once; this is a terminal singleton timeline operation."""
    fixture = _fixture()
    if fixture is None:
        LOG.info("Host rotation property unexercised: fixture unavailable")
        return 0
    first, second = fixture.config.marshall_urls[:2]
    old = _open(fixture, second, fixture.credential)
    if old is None:
        return 0
    try:
        old_nonce = session_id()
        old_epoch = _opened(
            old.exchange(1, "lilly.sessions", _session_body(fixture, old_nonce)), old_nonce
        )
        if old_epoch is None:
            return 0
        if not _exchange_accepted(
            old.exchange(2, "lilly.exchange", _exchange_body(old_nonce, old_epoch)),
            old_nonce,
            old_epoch,
        ):
            return 0
        coordinator = RotationCoordinator(
            Path(os.environ["ANTITHESIS_CONTROL_REQUEST_DIR"]), fixture.credential_path.parent
        )
        receipt = coordinator.rotate(session_id(), fixture.host_id)
        if receipt is None or receipt.credential.credential_id == fixture.credential.credential_id:
            return 0
        authority = fixture.oracle.credential_authority(
            fixture.host_id, fixture.credential.credential_id
        )
        baseline = _snapshot(fixture.sql, fixture.host_id)
        if (
            authority.state is not State.OBSERVED
            or authority.value is None
            or not authority.value.old_archived
            or authority.value.active_id != receipt.credential.credential_id
            or baseline.state is not State.OBSERVED
            or baseline.value is None
            or baseline.value.session_id is not None
            or baseline.value.epoch <= old_epoch
        ):
            return 0
        stale = old.exchange(3, "lilly.exchange", _exchange_body(old_nonce, old_epoch))
        after = _snapshot(fixture.sql, fixture.host_id)
        exchange_verdict = _stale_verdict(baseline.value, after, stale)
        # A stale credential must also be unable to create a fresh session
        # through its already-welcomed socket.
        stale_nonce = session_id()
        before_open = _snapshot(fixture.sql, fixture.host_id)
        replay = old.exchange(4, "lilly.sessions", _session_body(fixture, stale_nonce))
        after_open = _snapshot(fixture.sql, fixture.host_id)
        open_verdict: bool | None = None
        if before_open.state is State.OBSERVED and before_open.value is not None:
            open_verdict = _stale_verdict(before_open.value, after_open, replay)
        # An old token must also fail at a fresh transport upgrade.
        rejected = ControlWire(first, fixture.config.ca_file, fixture.credential).open()
        reconnect_verdict: bool | None = None
        if rejected.session is not None:
            rejected.session.close()
            reconnect_verdict = False
        elif rejected.http_status == 401:
            reconnect_verdict = True
        if exchange_verdict is not None or open_verdict is not None or reconnect_verdict is False:
            always(
                all(
                    verdict is not False
                    for verdict in (exchange_verdict, open_verdict, reconnect_verdict)
                ),
                "Committed host credential rotation fences old Control request authority",
            )
        if stale.acknowledged and rejected.http_status == 401:
            reachable("Archived host credential refused on old socket and fresh upgrade")
        fresh = _open(fixture, first, receipt.credential)
        if fresh is None:
            return 0
        try:
            nonce = session_id()
            epoch = _opened(
                fresh.exchange(1, "lilly.sessions", _session_body(fixture, nonce)), nonce
            )
            if epoch is None:
                return 0
            current = _snapshot(fixture.sql, fixture.host_id)
            if (
                current.state is State.OBSERVED
                and current.value is not None
                and current.value.session_id == nonce
                and current.value.epoch == epoch
                and _exchange_accepted(
                    fresh.exchange(2, "lilly.exchange", _exchange_body(nonce, epoch)),
                    nonce,
                    epoch,
                )
            ):
                reachable("New host credential opened a successor session after rotation")
            return 0
        finally:
            fresh.close()
    finally:
        old.close()


def main_successor() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        return run_session_successor()
    except (OSError, ValueError, KeyError):
        LOG.exception("Invalid host successor fixture")
        return 1


def main_rotation() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        return run_credential_rotation()
    except (OSError, ValueError, KeyError):
        LOG.exception("Invalid host rotation fixture")
        return 1
