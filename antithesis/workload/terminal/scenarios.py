"""Terminal histories joined with durable SQL and guest-owned physical effects."""

import logging
import time
from dataclasses import dataclass, replace
from threading import Thread
from uuid import UUID, uuid4

from antithesis.assertions import always, reachable, sometimes

from admission.client import ComputeOperator
from core.interesting import choice
from core.outcome import State
from terminal.client import TerminalClient
from terminal.guest import GuestOracle, GuestSnapshot, marker_digest
from terminal.oracle import CreateHistory, TerminalOracle
from terminal.viewer import Viewer

LOG = logging.getLogger(__name__)
RING_TOTAL = 64 * 1024 * 1024
VIEWER_HWM = 1024 * 1024


@dataclass(frozen=True)
class TerminalCase:
    vm_id: UUID
    host_id: UUID
    operator: ComputeOperator
    client: TerminalClient
    sql: TerminalOracle
    guest: GuestOracle


def _snapshot(case: TerminalCase) -> GuestSnapshot | None:
    observed = case.guest.snapshot()
    return observed.value if observed.state is State.OBSERVED else None


def _same_daemon(first: GuestSnapshot, second: GuestSnapshot) -> bool:
    return (
        first.daemon_pid == second.daemon_pid
        and first.daemon_start_ticks == second.daemon_start_ticks
    )


def _open(case: TerminalCase, request_id: UUID, seconds: float = 30.0) -> CreateHistory | None:
    """Retry only the same ID, and settle from SQL after ambiguous replies."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        case.client.create(request_id)
        observed = case.sql.create_history(request_id)
        if observed.state is State.OBSERVED and observed.value is not None:
            history = observed.value
            if history.opening is not None and history.opening.status == "ready":
                return history
            if history.opening is not None and history.opening.status == "failed":
                return history
        time.sleep(0.2)
    return None


def run_create_replay(case: TerminalCase) -> int:
    """Drop the browser reply, retry one ID, and join SQL with guest PTY birth."""
    before = _snapshot(case)
    if before is None:
        LOG.info("terminal create replay unexercised: physical guest witness unavailable")
        return 0
    request_id = uuid4()
    if not case.client.drop_create_reply(request_id):
        return 0
    reconnected = case.client.reconnect()
    if reconnected.state is not State.OBSERVED or reconnected.value is None:
        return 0
    active = replace(case, client=reconnected.value)
    try:
        interim = _snapshot(active)
        if interim is not None and _same_daemon(before, interim) and interim.births > before.births:
            reachable("Terminal browser reply loss followed observed guest PTY birth")
        history = _open(active, request_id)
        if history is None or history.opening is None or history.opening.status != "ready":
            LOG.info("terminal create replay unexercised: no settled ready terminal")
            return 0
        for _ in range(choice((1, 2, 8))):
            active.client.create(request_id)
        settled = active.sql.create_history(request_id)
        after = _snapshot(active)
        if settled.state is not State.OBSERVED or settled.value is None or after is None:
            LOG.info("terminal create replay unexercised: receipt or guest witness unavailable")
            return 0
        current = settled.value
        guest_id = current.sessions[0].guest_session_id if len(current.sessions) == 1 else None
        live = [session for session in after.sessions if session.session_id == guest_id]
        if not _same_daemon(before, after):
            LOG.info("terminal create replay unexercised: guest daemon incarnation changed")
            return 0
        always(
            current.settled_consistent()
            and after.births == before.births + 1
            and len(live) == 1
            and live[0].alive
            and live[0].pid > 0
            and live[0].proc_start_ticks > 0,
            "Terminal create replay retains one guest PTY and one opened receipt",
        )
        if current.settled_consistent() and len(live) == 1 and after.births == before.births + 1:
            reachable("Terminal duplicate create returned original session receipt")
        if len(current.sessions) == 1:
            active.client.kill(current.sessions[0].session_id)
        return 0
    finally:
        active.client.close()


def _session(case: TerminalCase, history: CreateHistory) -> tuple[UUID, int] | None:
    if not history.settled_consistent() or len(history.sessions) != 1:
        return None
    session = history.sessions[0]
    return session.session_id, session.guest_session_id


def _marker_command(marker: bytes) -> bytes:
    """Echoed command contains halves; only actual execution emits the full marker."""
    if len(marker) != 32:
        raise ValueError("invalid synthetic marker")
    return b"printf '%s%s' '" + marker[:16] + b"' '" + marker[16:] + b"'\n"


def _wait_marker(viewer: Viewer, marker: bytes, seconds: float = 15.0) -> bool:
    deadline = time.monotonic() + seconds
    tail = b""
    while time.monotonic() < deadline:
        received = viewer.receive(timeout=min(5.0, deadline - time.monotonic()))
        if received.state is not State.OBSERVED or received.value is None:
            continue
        tail = (tail + received.value)[-128:]
        if marker in tail:
            return True
    return False


def run_input_probe(case: TerminalCase) -> int:
    """@cc [owner:ghuntley,label:verification] terminal-replay-effect-oracle
    A passing exact-once verdict MUST follow a same-channel DATA replay ACK and
    compare one stable guest terminald incarnation's fsynced marker ledger.
    Missing arm, ACK, daemon continuity or ledger observation MUST remain
    unexercised; a second marker entry MUST fail the property.
    """
    history = _open(case, uuid4())
    if history is None:
        return 0
    identity = _session(case, history)
    if identity is None:
        return 0
    session_id, guest_id = identity
    attached = Viewer.attach(case.client, session_id)
    before = _snapshot(case)
    if attached.state is not State.OBSERVED or attached.value is None or before is None:
        return 0
    viewer = attached.value
    if viewer.attachment.guest_session_id != guest_id:
        viewer.close()
        return 0
    try:
        if (
            viewer.input(
                b"stty -echo; while /run/current-system/sw/bin/overalls-terminal-probe; do :; done\n"
            ).state
            is not State.OBSERVED
        ):
            return 0
        # A first marker confirms that the persistent guest probe is reading
        # this PTY. With a one-shot probe, duplicated input could fall back to
        # the shell and escape the ledger oracle.
        calibration = uuid4().hex.encode("ascii")
        if viewer.input(calibration + b"\n").state is not State.OBSERVED:
            return 0
        calibration_digest = marker_digest(calibration)
        deadline = time.monotonic() + 15
        ready: GuestSnapshot | None = None
        while time.monotonic() < deadline:
            observed = _snapshot(case)
            if observed is None:
                return 0
            if not _same_daemon(before, observed):
                return 0
            count = observed.ledger_digests.count(calibration_digest)
            if count > 1:
                always(False, "terminal calibration marker consumed once")
                return 0
            if count == 1:
                ready = observed
                break
            time.sleep(0.2)
        if ready is None:
            LOG.info("terminal input replay unexercised: guest probe did not start")
            return 0
        connection = case.sql.host_connection(case.host_id)
        if connection.state is not State.OBSERVED or connection.value is None:
            return 0
        armed = case.guest.replay_arm(
            host_id=case.host_id,
            connection=connection.value,
            terminal_session_id=session_id,
            vm_id=case.vm_id,
            guest_session_id=guest_id,
            channel=viewer.attachment.channel,
        )
        if armed.state is not State.OBSERVED or armed.value is None:
            LOG.info("terminal input replay unexercised: current channel arm unavailable")
            return 0
        marker = uuid4().hex.encode("ascii")
        digest = marker_digest(marker)
        if viewer.input(marker + b"\n").state is not State.OBSERVED:
            return 0
        receipt_deadline = time.monotonic() + 20
        acknowledged = False
        while time.monotonic() < receipt_deadline:
            receipt = case.guest.replay_receipt(armed.value, viewer.attachment.channel)
            if receipt.state is State.OBSERVED and receipt.value is not None:
                acknowledged = True
                break
            time.sleep(0.2)
        if not acknowledged:
            LOG.info("terminal input replay unexercised: Lilly ACK receipt unavailable")
            return 0
        reachable("terminal identical DATA frames received a Lilly input ACK")
        deadline = time.monotonic() + 15
        settled_count = 0
        while time.monotonic() < deadline:
            after = _snapshot(case)
            if after is None or not _same_daemon(ready, after):
                return 0
            count = after.ledger_digests.count(digest) - ready.ledger_digests.count(digest)
            if count > 1:
                settled_count = count
                break
            if count == 1:
                # The ACK covers both identical frames; observe again after
                # the guest's next read opportunity before asserting exact once.
                time.sleep(0.5)
                settled = _snapshot(case)
                if settled is None or not _same_daemon(after, settled):
                    return 0
                settled_count = settled.ledger_digests.count(digest) - ready.ledger_digests.count(
                    digest
                )
                break
            time.sleep(0.2)
        always(settled_count == 1, "terminal same-channel DATA replay has one guest input effect")
    finally:
        viewer.close()
        case.client.kill(session_id)
    return 0


def run_ring_budget(case: TerminalCase) -> int:
    """Grow actual guest PTY scrollback, checking allocated backing each step."""
    before = _snapshot(case)
    if before is None or before.sessions:
        LOG.info("terminal ring budget unexercised: no isolated guest baseline")
        return 0
    created: list[UUID] = []
    try:
        for _ in range(8):
            history = _open(case, uuid4())
            if history is None:
                break
            identity = _session(case, history)
            if identity is None:
                break
            session_id, guest_id = identity
            created.append(session_id)
            attached = Viewer.attach(case.client, session_id)
            if attached.state is not State.OBSERVED or attached.value is None:
                break
            viewer = attached.value
            if viewer.attachment.guest_session_id != guest_id:
                viewer.close()
                break
            chunk = choice((32767, 32768, 32769))
            # Output generation is real guest shell work; no transcript is used
            # as the memory oracle. A detached viewer avoids its credit bound.
            command = f"yes x | head -c {8 * 1024 * 1024 + chunk}\n".encode("ascii")
            try:
                viewer.input(command)
            finally:
                viewer.close()
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                snapshot = _snapshot(case)
                if snapshot is None:
                    break
                if not _same_daemon(before, snapshot):
                    LOG.info("terminal ring budget unexercised: guest daemon incarnation changed")
                    return 0
                always(
                    snapshot.physical_backing_within_budget(RING_TOTAL),
                    "terminal physical scrollback backing stays within reserved aggregate budget",
                )
                current = next(
                    (item for item in snapshot.sessions if item.session_id == guest_id), None
                )
                if current is not None and current.ring_limit == 8 * 1024 * 1024:
                    break
                time.sleep(0.2)
        full = _snapshot(case)
        if full is not None and _same_daemon(before, full) and full.ring_total == RING_TOTAL:
            refused = case.client.create(uuid4())
            after = _snapshot(case)
            if (
                refused.state is State.OBSERVED
                and refused.value is not None
                and refused.value.state == "failed"
                and after is not None
                and _same_daemon(full, after)
                and after.ring_total == RING_TOTAL
                and all(session.alive for session in after.sessions)
            ):
                reachable(
                    "terminal create failed with aggregate ring budget full and survivors live"
                )
    finally:
        for session_id in created:
            case.client.kill(session_id)
    return 0


def run_neighbor_progress(case: TerminalCase) -> int:
    """A stalled real viewer retains pressure while a neighbor delivers bytes."""
    stalled_history = _open(case, uuid4())
    if stalled_history is None:
        return 0
    stalled_identity = _session(case, stalled_history)
    if stalled_identity is None:
        return 0
    stalled_id, stalled_guest_id = stalled_identity
    stalled_attach = Viewer.attach(case.client, stalled_id)
    if stalled_attach.state is not State.OBSERVED or stalled_attach.value is None:
        return 0
    stalled = stalled_attach.value
    neighbor_id: UUID | None = None
    neighbor: Viewer | None = None
    try:
        if stalled.input(b"yes x | head -c 4194304\n").state is not State.OBSERVED:
            return 0
        deadline = time.monotonic() + 20
        pressured = False
        pressure_snapshot: GuestSnapshot | None = None
        while time.monotonic() < deadline:
            snapshot = _snapshot(case)
            current = (
                next(
                    (item for item in snapshot.sessions if item.session_id == stalled_guest_id),
                    None,
                )
                if snapshot is not None
                else None
            )
            if current is not None and any(
                viewer.queue_bytes > VIEWER_HWM and viewer.blocked_write
                for viewer in current.viewers
            ):
                pressured = True
                pressure_snapshot = snapshot
                break
            time.sleep(0.2)
        if not pressured:
            LOG.info("terminal neighbor case unexercised: viewer pressure not witnessed")
            return 0
        neighbor_history = _open(case, uuid4())
        if neighbor_history is None:
            return 0
        identity = _session(case, neighbor_history)
        if identity is None:
            return 0
        neighbor_id, guest_id = identity
        attached = Viewer.attach(case.client, neighbor_id)
        if attached.state is not State.OBSERVED or attached.value is None:
            return 0
        neighbor = attached.value
        if neighbor.attachment.guest_session_id != guest_id:
            return 0
        neighbor.resize(79, 23)
        marker = uuid4().hex.encode("ascii")
        if neighbor.input(_marker_command(marker)).state is not State.OBSERVED:
            return 0
        delivered = _wait_marker(neighbor, marker)
        final = _snapshot(case)
        if final is None or pressure_snapshot is None or not _same_daemon(pressure_snapshot, final):
            LOG.info("terminal neighbor case unexercised: guest daemon witness changed")
            return 0
        stalled_still = any(
            item.session_id == stalled_guest_id
            and item.alive
            and any(viewer.queue_bytes > VIEWER_HWM for viewer in item.viewers)
            for item in final.sessions
        )
        sometimes(
            delivered and stalled_still,
            "terminal neighbor completes create attach and byte delivery while another viewer is credit stalled",
        )
    finally:
        if neighbor is not None:
            neighbor.close()
        if neighbor_id is not None:
            case.client.kill(neighbor_id)
        stalled.close()
        case.client.kill(stalled_id)
    return 0


def run_kill_under_input_stall(case: TerminalCase) -> int:
    """Require a real blocked PTY master write before testing kill retirement."""
    history = _open(case, uuid4())
    if history is None:
        return 0
    identity = _session(case, history)
    if identity is None:
        return 0
    session_id, guest_id = identity
    attached = Viewer.attach(case.client, session_id)
    if attached.state is not State.OBSERVED or attached.value is None:
        return 0
    viewer = attached.value
    if viewer.attachment.guest_session_id != guest_id:
        viewer.close()
        return 0
    try:
        initial = _snapshot(case)
        original = (
            next((item for item in initial.sessions if item.session_id == guest_id), None)
            if initial is not None
            else None
        )
        if initial is None or original is None or original.proc_start_ticks < 1:
            return 0
        if viewer.input(b"stty -echo; sleep 120\n").state is not State.OBSERVED:
            return 0
        # The independent INPUT_STALL query does not acquire SessionInner.
        # A single maximum legal viewer frame can fill a non-reading PTY.
        writer = Thread(target=viewer.input, args=(b"x" * 65_536,), daemon=True)
        writer.start()
        deadline = time.monotonic() + 10
        blocked = False
        while time.monotonic() < deadline:
            observed = case.guest.input_stall(guest_id)
            if (
                observed.state is State.OBSERVED
                and observed.value is not None
                and observed.value.pid == original.pid
                and observed.value.in_progress
                and observed.value.elapsed_ms > 100
            ):
                blocked = True
                break
            time.sleep(0.1)
        if not blocked:
            LOG.info("terminal kill case unexercised: blocked PTY input write not observed")
            return 0
        reachable("terminal guest PTY master input write stayed blocked before kill")
        submitted = case.client.kill(session_id)
        if submitted.state is not State.OBSERVED:
            LOG.info("terminal kill case unexercised: kill dispatch reply uncertain")
            return 0
        # This bounded quiet interval is only evaluated after the real stall
        # and an acknowledged current-authority kill. Guest restarts/observer
        # outages remain unavailable rather than a success claim.
        retirement_deadline = time.monotonic() + 30
        retired = False
        while time.monotonic() < retirement_deadline:
            after = _snapshot(case)
            if after is None:
                time.sleep(0.2)
                continue
            if not _same_daemon(initial, after):
                LOG.info("terminal kill case unexercised: guest daemon incarnation changed")
                return 0
            same = next((item for item in after.sessions if item.session_id == guest_id), None)
            if (
                same is None
                and after.deaths > initial.deaths
                and after.ring_total < initial.ring_total
            ):
                retired = True
                break
            time.sleep(0.2)
        if not retired:
            still_blocked = case.guest.input_stall(guest_id)
            if (
                still_blocked.state is not State.OBSERVED
                or still_blocked.value is None
                or still_blocked.value.pid != original.pid
                or not still_blocked.value.in_progress
            ):
                LOG.info("terminal kill case unexercised: final guest stall state unavailable")
                return 0
        sometimes(
            retired,
            "terminal kill retires blocked PTY child and releases capacity",
        )
    finally:
        viewer.close()
        case.client.kill(session_id)
    return 0
