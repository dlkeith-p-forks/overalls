"""Independent terminald snapshot through the actual QEMU guest-vmm control socket."""

import json
import os
import re
import stat
import time
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID, uuid4

from core.outcome import Observation
from terminal.oracle import HostConnection

MAX_REQUEST = 4096
MAX_RESPONSE = 16384
MAX_SESSIONS = 64
MAX_VIEWERS = 128
HEX_128 = re.compile(r"[0-9a-f]{32}\Z")
FNV_128_OFFSET = 0x6C62272E07BB014262B821756295C58D
FNV_128_PRIME = 0x0000000001000000000000000000013B


def marker_digest(marker: bytes) -> str:
    """Hash a bounded synthetic marker exactly as the guest fsync probe does."""
    if len(marker) != 32 or any(byte not in b"0123456789abcdef" for byte in marker):
        raise ValueError("marker must be 32 lower-case hex bytes")
    value = FNV_128_OFFSET
    for byte in marker:
        value = ((value ^ byte) * FNV_128_PRIME) & ((1 << 128) - 1)
    return f"{value:032x}"


@dataclass(frozen=True)
class GuestIdentity:
    placement_id: UUID
    execution_epoch: int
    generation: int

    def __post_init__(self) -> None:
        if self.execution_epoch < 1 or self.generation < 1:
            raise ValueError("invalid guest witness identity")

    def request(self, operation: str, session_id: int | None = None) -> dict[str, object]:
        if operation not in (
            "guest.terminal_witness",
            "guest.terminal_input_stall",
            "terminal.replay_arm",
        ):
            raise ValueError("invalid terminal witness operation")
        return {
            "operation": operation,
            "placement_id": str(self.placement_id),
            "execution_epoch": self.execution_epoch,
            "generation": self.generation,
        } | ({"session_id": str(session_id)} if session_id is not None else {})


@dataclass(frozen=True)
class ViewerQueue:
    queue_bytes: int
    blocked_write: bool


@dataclass(frozen=True)
class GuestSession:
    session_id: int
    pid: int
    proc_start_ticks: int
    alive: bool
    ring_base: int
    ring_tail: int
    ring_limit: int
    deque_allocated: int
    viewers: tuple[ViewerQueue, ...]


@dataclass(frozen=True)
class GuestSnapshot:
    daemon_pid: int
    daemon_start_ticks: int
    births: int
    deaths: int
    ring_total: int
    viewer_total: int
    sessions: tuple[GuestSession, ...]
    ledger_digests: tuple[str, ...] = ()

    def physical_backing_within_budget(self, configured_total: int) -> bool:
        """@cc [owner:ghuntley,label:verification] terminal-backing-bounds
        Every observed session's ring reservation MUST remain within 8 MiB and
        its allocated backing MUST remain within that reservation. The aggregate
        MUST remain within the daemon's reserved and configured budgets. An
        oversized numeric observation MUST reach this verdict instead of being
        discarded during parsing.
        """
        return (
            all(
                0 < session.ring_limit <= 8_388_608
                and session.deque_allocated <= session.ring_limit
                for session in self.sessions
            )
            and sum(session.deque_allocated for session in self.sessions) <= self.ring_total
            and self.ring_total <= configured_total
        )


@dataclass(frozen=True)
class InputStall:
    session_id: int
    pid: int
    in_progress: bool
    elapsed_ms: int


@dataclass(frozen=True)
class ReplayReceipt:
    channel: int
    sequence: int
    acknowledged_frames: int


def _nonnegative(value: object, *, maximum: int = 9_223_372_036_854_775_807) -> int | None:
    if type(value) is int and 0 <= value <= maximum:
        return value
    return None


def _snapshot(raw: object) -> GuestSnapshot | None:
    if not isinstance(raw, dict) or raw.get("state") != "ok" or raw.get("version") != 1:
        return None
    births = _nonnegative(raw.get("births"))
    deaths = _nonnegative(raw.get("deaths"))
    daemon_pid = _nonnegative(raw.get("daemon_pid"))
    daemon_start_ticks = _nonnegative(raw.get("daemon_start_ticks"))
    ring_total = _nonnegative(raw.get("ring_total"), maximum=1_073_741_824)
    viewer_total = _nonnegative(raw.get("viewer_total"), maximum=MAX_VIEWERS)
    candidates = raw.get("sessions")
    if (
        births is None
        or deaths is None
        or daemon_pid is None
        or daemon_pid < 1
        or daemon_start_ticks is None
        or daemon_start_ticks < 1
        or ring_total is None
        or viewer_total is None
        or not isinstance(candidates, list)
        or len(candidates) > MAX_SESSIONS
    ):
        return None
    sessions: list[GuestSession] = []
    for candidate in candidates:
        if not isinstance(candidate, dict):
            return None
        session_id = _nonnegative(candidate.get("session_id"))
        pid = _nonnegative(candidate.get("pid"))
        ticks = _nonnegative(candidate.get("proc_start_ticks"))
        base = _nonnegative(candidate.get("ring_base"))
        tail = _nonnegative(candidate.get("ring_tail"))
        ring_limit = _nonnegative(candidate.get("ring_limit"), maximum=4_294_967_295)
        # A bad allocation is still a valid observation for the ring-budget
        # property. The guest observer accepts up to the global 64 MiB budget.
        allocated = _nonnegative(candidate.get("deque_allocated"), maximum=67_108_864)
        viewers = candidate.get("viewers")
        if (
            session_id is None
            or session_id < 1
            or pid is None
            or ticks is None
            or type(candidate.get("alive")) is not bool
            or base is None
            or tail is None
            or ring_limit is None
            or allocated is None
            or not isinstance(viewers, list)
            or len(viewers) > 8
            or base > tail
        ):
            return None
        queues: list[ViewerQueue] = []
        for viewer in viewers:
            if not isinstance(viewer, dict):
                return None
            queue_bytes = _nonnegative(viewer.get("queue_bytes"), maximum=8_388_608)
            blocked = viewer.get("blocked_write")
            if queue_bytes is None or type(blocked) is not bool:
                return None
            queues.append(ViewerQueue(queue_bytes, blocked))
        sessions.append(
            GuestSession(
                session_id,
                pid,
                ticks,
                candidate["alive"],
                base,
                tail,
                ring_limit,
                allocated,
                tuple(queues),
            )
        )
    if len({session.session_id for session in sessions}) != len(sessions):
        return None
    if sum(len(session.viewers) for session in sessions) != viewer_total:
        return None
    ledger_digests = raw.get("ledger_digests")
    if (
        not isinstance(ledger_digests, list)
        or len(ledger_digests) > 128
        or not all(isinstance(item, str) and HEX_128.fullmatch(item) for item in ledger_digests)
    ):
        return None
    return GuestSnapshot(
        daemon_pid,
        daemon_start_ticks,
        births,
        deaths,
        ring_total,
        viewer_total,
        tuple(sessions),
        tuple(ledger_digests),
    )


class GuestOracle:
    def __init__(self, request_root: Path, identity: GuestIdentity) -> None:
        if not request_root.is_absolute():
            raise ValueError("guest observer request root must be absolute")
        self._requests = request_root / "requests"
        self._results = request_root / "results"
        self._identity = identity

    def snapshot(self) -> Observation[GuestSnapshot]:
        """@cc [owner:ghuntley,label:verification;security] guest-terminal-physical-witness
        A success observation MUST decode a current authenticated terminald
        snapshot from the real guest through the trusted operator bridge. A
        missing result, malformed fields, stale boot or missing service MUST
        remain unavailable. No terminal
        payload, command or token may enter diagnostics from this client.
        """
        parsed = self._call(self._identity.request("guest.terminal_witness"))
        snapshot = _snapshot(parsed)
        return Observation.observed(snapshot) if snapshot is not None else Observation.unavailable()

    def input_stall(self, session_id: int) -> Observation[InputStall]:
        if session_id < 1:
            raise ValueError("invalid guest terminal session")
        parsed = self._call(self._identity.request("guest.terminal_input_stall", session_id))
        if (
            not isinstance(parsed, dict)
            or parsed.get("state") != "ok"
            or parsed.get("version") != 1
        ):
            return Observation.unavailable()
        witnessed_session = _nonnegative(parsed.get("session_id"))
        pid = _nonnegative(parsed.get("pid"))
        elapsed = _nonnegative(parsed.get("elapsed_ms"), maximum=3_600_000)
        in_progress = parsed.get("in_progress")
        if (
            witnessed_session != session_id
            or pid is None
            or pid < 1
            or elapsed is None
            or type(in_progress) is not bool
        ):
            return Observation.unavailable()
        return Observation.observed(InputStall(session_id, pid, in_progress, elapsed))

    def replay_arm(
        self,
        *,
        host_id: UUID,
        connection: HostConnection,
        terminal_session_id: UUID,
        vm_id: UUID,
        guest_session_id: int,
        channel: int,
    ) -> Observation[UUID]:
        """@cc [owner:ghuntley,label:security;verification] terminal-replay-arm-binding
        Arm only the current authenticated host connection, terminal session,
        placement, guest session and viewer channel. Publication alone MUST NOT
        count as replay delivery or guest execution.
        """
        if not 1 <= guest_session_id <= 9_223_372_036_854_775_807 or channel < 1:
            raise ValueError("invalid replay channel or guest session")
        arm_id = uuid4()
        request: dict[str, object] = self._identity.request("terminal.replay_arm") | {
            "host_id": str(host_id),
            "connection_session_id": str(connection.session_id),
            "connection_epoch": connection.epoch,
            "terminal_session_id": str(terminal_session_id),
            "vm_id": str(vm_id),
            "guest_session_id": str(guest_session_id),
            "channel": channel,
        }
        value = self._call(request, request_id=arm_id)
        if (
            not isinstance(value, dict)
            or set(value) != {"state", "request_id"}
            or value.get("state") != "armed"
            or value.get("request_id") != str(arm_id)
        ):
            return Observation.unavailable()
        return Observation.observed(arm_id)

    def replay_receipt(self, arm_id: UUID, channel: int) -> Observation[ReplayReceipt]:
        """@cc [owner:ghuntley,label:verification] terminal-replay-ack-scope
        A success observation MUST match the arm ID and channel and carry a
        cumulative Lilly ACK covering the injected sequence. It establishes
        delivery through Lilly, not guest consumption.
        """
        value = self._call({"operation": "terminal.replay_receipt", "arm_request_id": str(arm_id)})
        if not isinstance(value, dict) or set(value) != {
            "version",
            "state",
            "request_id",
            "channel",
            "sequence",
            "acknowledged_frames",
        }:
            return Observation.unavailable()
        sequence = _nonnegative(value.get("sequence"))
        frames = _nonnegative(value.get("acknowledged_frames"))
        if (
            value.get("version") != 1
            or value.get("state") != "acknowledged"
            or value.get("request_id") != str(arm_id)
            or value.get("channel") != channel
            or sequence is None
            or sequence < 1
            or frames is None
            or frames < sequence
        ):
            return Observation.unavailable()
        return Observation.observed(ReplayReceipt(channel, sequence, frames))

    def _call(self, request: dict[str, object], *, request_id: UUID | None = None) -> object | None:
        request_id = request_id or uuid4()
        body: dict[str, object] = {"version": 1, "request_id": str(request_id)} | request
        encoded = (json.dumps(body, separators=(",", ":")) + "\n").encode()
        if len(encoded) > MAX_REQUEST:
            raise ValueError("guest observer request too large")
        temporary = self._requests / f".{request_id}.tmp"
        final = self._requests / f"{request_id}.json"
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as destination:
                destination.write(encoded)
                destination.flush()
                os.fsync(destination.fileno())
            os.link(temporary, final)
            temporary.unlink()
        except OSError:
            temporary.unlink(missing_ok=True)
            return None
        result = self._results / f"{request_id}.json"
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            try:
                metadata = result.lstat()
            except FileNotFoundError:
                time.sleep(0.1)
                continue
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_mode & 0o077
                or metadata.st_size > MAX_RESPONSE
            ):
                return None
            try:
                parsed: object = json.loads(result.read_text(encoding="utf-8"))
            except (OSError, ValueError, UnicodeError):
                return None
            if (
                not isinstance(parsed, dict)
                or parsed.get("version") != 1
                or parsed.get("request_id") != str(request_id)
                or parsed.get("operation") != request["operation"]
                or parsed.get("status") != "ok"
            ):
                return None
            return parsed.get("value")
        return None
