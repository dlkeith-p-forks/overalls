"""Recorder capacity/recovery and retained trace custody properties."""

import logging
import sqlite3
import time

from antithesis.assertions import always, always_or_unreachable, reachable

from recorder.client import (
    Client,
    Config,
    Reply,
    read_filesystem,
    read_identity,
    read_spool_identity,
    read_status,
)
from recorder.oracle import (
    Batch,
    RecorderState,
    read_archive,
    read_effects,
    read_recorder,
)

LOG = logging.getLogger(__name__)
PRESSURE_BUDGET_SECONDS = 20.0
ENOSPC_WRITE_ATTEMPTS = 32
REOPEN_ANSWER_ATTEMPTS = 60
MAX_PENDING = 4096


def _state(config: Config) -> RecorderState | None:
    try:
        return read_recorder(config.checkpoint)
    except (OSError, ValueError):
        return None


def _archive(config: Config) -> dict[str, Batch] | None:
    try:
        return read_archive(config.archive)
    except (OSError, ValueError, sqlite3.Error):
        return None


def _conserved(state: RecorderState) -> bool:
    return (
        state.requests == state.successes + state.failures
        and sum(state.bucket_counts) == state.duration_count
        and len(state.pending) <= MAX_PENDING
    )


def _ready(config: Config) -> bool:
    """Require fresh real service, identity, checkpoint and bounded-device evidence."""
    status = read_status(config)
    producer = read_identity(config)
    spool = read_spool_identity(config)
    filesystem = read_filesystem(config)
    return (
        status is not None
        and status.producer
        and status.recorder
        and status.spool
        and status.archive
        and producer is not None
        and producer.cgroup == "0::/fixture.slice/recorder-peer.service"
        and spool is not None
        and spool.cgroup == "0::/system.slice/overalls-trace-recorder.service"
        and filesystem is not None
        and filesystem.archive_device != filesystem.root_device
        and 32 * 1024 * 1024 <= filesystem.total_bytes <= 64 * 1024 * 1024
        and _state(config) is not None
        and _archive(config) is not None
    )


def _admit(client: Client, count: int) -> Reply | None:
    if count < 1 or count > 128:
        raise ValueError("admission batch outside reviewed range")
    return client.call({"op": "admit", "count": count})


def run_capacity() -> int:
    """Exercise the exact 4096/4097 live BEAM-worker boundary without faults."""
    config = Config.from_environment()
    client = Client(config)
    if not _ready(config):
        LOG.error("recorder VM physical readiness prerequisite missing")
        return 1
    baseline = _state(config)
    if baseline is None:
        LOG.error("request recorder checkpoint prerequisite missing")
        return 1
    if baseline.pending:
        LOG.error("capacity fixture requires a fresh pending set")
        return 1
    identity = read_identity(config)
    if identity is None or identity.cgroup != "0::/fixture.slice/recorder-peer.service":
        LOG.error("real producer kernel identity prerequisite missing")
        return 1
    identities: list[int] = []
    for _ in range(MAX_PENDING // 128):
        result = _admit(client, 128)
        if result is None or result.status != "ok":
            LOG.error("request producer admission prerequisite unavailable")
            return 1
        identities.extend(result.admitted)
        if len(result.admitted) != 128:
            LOG.error("request producer could not reach exact-capacity prerequisite")
            return 1
    full = _state(config)
    if full is None:
        LOG.error("request checkpoint unavailable at capacity")
        return 1
    current_identity = read_identity(config)
    at_capacity = (
        current_identity == identity
        and len(full.pending) == MAX_PENDING
        and full.next_id - baseline.next_id == MAX_PENDING
        and all(
            producer.pid == identity.pid and producer.start_ticks == identity.start_ticks
            for producer in full.producers.values()
        )
    )
    always(
        at_capacity,
        "Request recorder exact capacity holds 4096 real worker admissions",
    )
    if at_capacity:
        reachable("Request recorder reached 4096 live authenticated producer workers")
    effects_before = read_effects(config.effects)
    refused = _admit(client, 1)
    after = _state(config)
    effects_after = read_effects(config.effects)
    quality = config.quality.read_bytes() if config.quality.is_file() else b""
    if refused is not None and after is not None:
        refused_cleanly = (
            refused.status == "ok"
            and refused.admitted == ()
            and after.pending == full.pending
            and after.next_id == full.next_id
            and len(effects_after) == len(effects_before) + 1
            # The SDK fsyncs v1:gap, and its next heartbeat may already have
            # recovered the marker to running; then the durable gap is the
            # checkpoint's advanced coverage start.
            and (
                quality == b"v1:gap\n"
                or (
                    quality == b"v1:running\n"
                    and after.coverage_started_at_ns > full.coverage_started_at_ns
                )
            )
            and _conserved(after)
        )
        always(
            refused_cleanly,
            "request recorder saturation cannot fabricate admitted tickets or a clean quality interval",
        )
        if refused_cleanly:
            reachable("Request recorder refused 4097th measurement after fixture effect")
    client.call({"op": "finish", "id": identities[0], "outcome": "success"})
    client.call({"op": "kill_worker", "id": identities[1]})
    for _ in range(20):
        settled = _state(config)
        if settled is not None and len(settled.pending) <= MAX_PENDING - 2:
            break
        time.sleep(0.1)
    renewed = _admit(client, 1)
    if renewed is not None and settled is not None and len(settled.pending) <= MAX_PENDING - 2:
        always_or_unreachable(
            renewed.status == "ok" and len(renewed.admitted) == 1,
            "Request recorder freed capacity admits one new measured worker",
        )
        identities.extend(renewed.admitted)
    remaining = identities[2:]
    for offset in range(0, len(remaining), 128):
        client.call({"op": "finish_many", "ids": remaining[offset : offset + 128]})
    return 0


def run_recovery() -> int:
    """Audit actual checkpoint identity through recorder process replacement."""
    config = Config.from_environment()
    client = Client(config)
    if not _ready(config):
        LOG.error("recorder VM physical readiness prerequisite missing")
        return 1
    before = _state(config)
    if before is None:
        LOG.error("request recorder checkpoint prerequisite missing")
        return 1
    identity = read_identity(config)
    if identity is None:
        LOG.error("real producer kernel identity prerequisite missing")
        return 1
    admission = _admit(client, 1)
    observed = _state(config)
    if observed is None:
        return 0
    if admission is not None and admission.admitted:
        always(
            observed.next_id > before.next_id and len(observed.pending) >= 1,
            "Request recorder acknowledged admission has durable checkpoint custody",
        )
    uncertain_before = observed
    uncertain_attempts, _ = client.counts("recorder_uncertain_admit")
    uncertain = client.call({"op": "recorder_uncertain_admit"}) if uncertain_attempts < 8 else None
    after_uncertain = _state(config)
    if uncertain is not None and uncertain.status == "uncertain" and after_uncertain is not None:
        change = after_uncertain.next_id - uncertain_before.next_id
        always_or_unreachable(
            change in (0, 1) and _conserved(after_uncertain),
            "Request recorder lost Admit reply changes durable admission at most once",
        )
        if change == 1 and len(after_uncertain.pending - uncertain_before.pending) == 1:
            reachable("Request recorder committed admission before caller discarded reply")
        observed = after_uncertain
    restarted = client.control({"op": "service", "target": "recorder", "action": "restart"})
    if restarted is None or restarted.status != "ok":
        LOG.error("independent request recorder restart unavailable")
        return 1
    # The closed fixture actuator restarts only the recorder's real systemd unit.
    # Kernel evidence must show the original producer survives that replacement.
    for _ in range(4):
        time.sleep(0.25)
        current = _state(config)
        if current is None:
            continue
        always(
            current.incarnation == before.incarnation
            and current.next_id >= before.next_id
            and current.requests >= before.requests
            and _conserved(current),
            "Request recorder recovery conserves admissions without inventing producer death",
        )
        current_identity = read_identity(config)
        new_ids = observed.pending - before.pending
        live_ids = {
            admission_id
            for admission_id in new_ids
            if observed.deadline_ns[admission_id] > time.time_ns()
            and current_identity == identity
            and observed.producers[admission_id].pid == identity.pid
            and observed.producers[admission_id].start_ticks == identity.start_ticks
        }
        if live_ids:
            retained = live_ids.issubset(current.pending)
            always_or_unreachable(
                retained,
                "Request recorder restart retains live unexpired admissions",
            )
            if retained:
                reachable(
                    "Request recorder reopened pending work while its original producer remained alive"
                )
            break
    if admission is not None:
        for identity in admission.admitted:
            client.call({"op": "finish", "id": identity, "outcome": "success"})
    return 0


def _retained(before: dict[str, Batch], after: dict[str, Batch], now_ns: int) -> bool:
    return all(
        old.expires_ns <= now_ns
        or (
            digest in after
            and after[digest].body_sha256 == old.body_sha256
            and after[digest].accepted_ns == old.accepted_ns
            and after[digest].expires_ns == old.expires_ns
        )
        for digest, old in before.items()
    )


def _audit_archive(client: Client, current: dict[str, Batch]) -> None:
    known = client.known_archive()
    if known:
        always(
            _retained(known, current, time.time_ns()),
            "Trace archive recovery preserves accepted immutable custody through acknowledgment loss",
        )
    client.remember_archive(current)


def _try_replay(
    client: Client, config: Config, before: dict[str, Batch]
) -> dict[str, Batch] | None:
    """Stop the real spool and request its fixed production replay under its owner UID."""
    stopped = client.control({"op": "service", "target": "spool", "action": "stop"})
    if stopped is None or stopped.status != "ok":
        return None
    try:
        replayed = client.control({"op": "replay"})
        if replayed is None or replayed.status != "ok":
            return None
        after = _archive(config)
    finally:
        started = client.control({"op": "service", "target": "spool", "action": "start"})
        if started is None or started.status != "ok":
            LOG.error("trace spool did not restart after replay")
    if after is not None:
        always_or_unreachable(
            _retained(before, after, time.time_ns())
            and all(batch.pending for batch in after.values() if batch.expires_ns > time.time_ns()),
            "Trace archive replay restores pending index without rewriting accepted bytes",
        )
        reachable("Trace spool replayed immutable archive through production replay mode")
    return after


def _physical_pressure(
    client: Client, config: Config, prior: dict[str, Batch], sequence: int
) -> None:
    """Fill only the VM's dedicated bounded archive block device."""
    filesystem = read_filesystem(config)
    if filesystem is None or filesystem.archive_device == filesystem.root_device:
        return
    if not 32 * 1024 * 1024 <= filesystem.total_bytes <= 64 * 1024 * 1024:
        return
    pressure = client.control({"op": "pressure_fill"})
    if pressure is None or pressure.status != "ok" or not pressure.enospc:
        LOG.error("physical archive ENOSPC prerequisite unavailable")
        return
    under_pressure = read_filesystem(config)
    if under_pressure is None or under_pressure.free_bytes != 0:
        LOG.error("archive free-space witness did not confirm ENOSPC")
        client.control({"op": "pressure_clear"})
        return
    reachable("Trace spool faced real ENOSPC on dedicated archive backing")
    poisoned_same_owner = False
    spool_before = read_spool_identity(config)
    try:
        result = client.call({"op": "trace", "sequence": sequence, "size": "large"})
        writes = 0
        while result is not None and result.status == "200" and writes < ENOSPC_WRITE_ATTEMPTS:
            # Existing allocated SQLite pages may commit without new blocks; keep
            # writing until the exhausted backing must refuse.
            reachable("Trace spool reused allocated archive pages during backing pressure")
            writes += 1
            result = client.call(
                {
                    "op": "trace",
                    "sequence": ((sequence + 10 + writes) % 999_999) + 1,
                    "size": "large",
                }
            )
        if result is not None and result.status == "503":
            reachable("Trace spool refused an archive write during real ENOSPC")
            again = client.call({"op": "trace", "sequence": sequence + 1, "size": "small"})
            spool_after = read_spool_identity(config)
            same_spool = (
                spool_before is not None
                and spool_after is not None
                and (spool_after.pid, spool_after.start_ticks)
                == (spool_before.pid, spool_before.start_ticks)
            )
            if same_spool and again is not None:
                poisoned_same_owner = again.status == "503"
                always_or_unreachable(
                    again.status != "200",
                    "Trace spool poisoned storage refuses fresh ACKs until reopen",
                )
    finally:
        cleared = client.control({"op": "pressure_clear"})
        if cleared is None or cleared.status != "ok":
            LOG.error("physical archive pressure cleanup unavailable")
    after = _archive(config)
    if after is not None:
        always_or_unreachable(
            _retained(prior, after, time.time_ns()),
            "Trace spool retains accepted bodies after physical space restoration",
        )
        _audit_archive(client, after)
    if (
        not poisoned_same_owner
        or cleared is None
        or cleared.status != "ok"
        or spool_before is None
        or after is None
    ):
        return
    reopened = client.control({"op": "service", "target": "spool", "action": "restart"})
    if reopened is None or reopened.status != "ok":
        return
    spool_reopened = read_spool_identity(config)
    replaced = (
        spool_reopened is not None
        and spool_reopened.cgroup == "0::/system.slice/overalls-trace-recorder.service"
        and (spool_reopened.pid, spool_reopened.start_ticks)
        != (spool_before.pid, spool_before.start_ticks)
    )
    always_or_unreachable(replaced, "Trace spool reopen replaces the poisoned process identity")
    if not replaced:
        return
    reopened_archive = _archive(config)
    retained = reopened_archive is not None and _retained(after, reopened_archive, time.time_ns())
    always_or_unreachable(retained, "Trace spool reopen retains previously accepted archive bytes")
    if not retained or reopened_archive is None:
        return
    # systemctl restart returns at exec, before the reopened spool has verified
    # its archive and bound ingest, so a transport-level "unavailable" is not
    # yet a spool decision. Retry the same batch until it answers.
    fresh = client.call({"op": "trace", "sequence": sequence + 2, "size": "small"})
    for _ in range(REOPEN_ANSWER_ATTEMPTS):
        if fresh is not None and fresh.status != "unavailable":
            break
        time.sleep(0.25)
        fresh = client.call({"op": "trace", "sequence": sequence + 2, "size": "small"})
    if fresh is None or fresh.status == "unavailable":
        LOG.info("Trace spool reopen intake unexercised: reopened spool never answered")
        return
    fresh_archive = _archive(config)
    fresh_custody = (
        fresh is not None
        and fresh.status == "200"
        and fresh_archive is not None
        and len(set(fresh_archive) - set(reopened_archive)) == 1
        and _retained(reopened_archive, fresh_archive, time.time_ns())
    )
    always_or_unreachable(
        fresh_custody,
        "Trace spool reopen admits one fresh reviewed batch without losing prior custody",
    )
    if fresh_custody:
        reachable("Trace spool accepted fresh batch after poisoned process reopen")
    if fresh_archive is not None:
        _audit_archive(client, fresh_archive)


def run_traces() -> int:
    """Send real reviewed OTLP batches and compare SQLite bytes after ACK/refusal."""
    config = Config.from_environment()
    client = Client(config)
    if not _ready(config):
        LOG.error("recorder VM physical readiness prerequisite missing")
        return 1
    initial = _archive(config)
    if initial is None:
        LOG.error("trace archive snapshot prerequisite missing")
        return 1
    filesystem = read_filesystem(config)
    if filesystem is None or filesystem.archive_device == filesystem.root_device:
        LOG.error("dedicated trace archive filesystem prerequisite missing")
        return 1
    _audit_archive(client, initial)
    prior = initial
    attempts, _acknowledged = client.counts("trace")
    sequence = (attempts % 999_999) + 1
    first = client.call({"op": "trace", "sequence": sequence, "size": "small"})
    after = _archive(config)
    if after is None:
        return 0
    if first is not None and first.status == "200":
        has_new_custody = len(set(after) - set(prior)) == 1
        always(
            has_new_custody and _retained(prior, after, time.time_ns()),
            "Trace spool successful intake has immutable SQLite custody",
        )
        if has_new_custody:
            reachable("Trace spool accepted a reviewed producer batch into SQLite custody")
    _audit_archive(client, after)
    prior = after
    synchronized = False
    lost_sequence = ((attempts + 1) % 999_999) + 1
    lost = client.call(
        {"op": "trace", "sequence": lost_sequence, "size": "small", "lose_ack": True}
    )
    after_loss = _archive(config)
    if lost is not None and lost.status == "uncertain":
        for _ in range(10):
            if after_loss is not None and set(after_loss) - set(prior):
                break
            time.sleep(0.1)
            after_loss = _archive(config)
    if lost is not None and lost.status == "uncertain" and after_loss is not None:
        _audit_archive(client, after_loss)
        new_digests = set(after_loss) - set(prior)
        if len(new_digests) == 1:
            synchronized = True
            reachable("Trace spool committed a batch despite discarded intake ACK")
            duplicate = client.call({"op": "trace", "sequence": lost_sequence, "size": "small"})
            after_retry = _archive(config)
            if duplicate is not None and duplicate.status == "200" and after_retry is not None:
                always_or_unreachable(
                    set(after_retry) == set(after_loss)
                    and _retained(after_loss, after_retry, time.time_ns()),
                    "Trace spool duplicate after lost intake ACK keeps one immutable batch",
                )
                _audit_archive(client, after_retry)
                after_loss = after_retry
        prior = after_loss
    replayed = _try_replay(client, config, prior)
    if replayed is not None:
        _audit_archive(client, replayed)
        prior = replayed
        synchronized = True
    # Each pressure iteration costs about half a second hosted; bound the loop so
    # the physical-pressure paths below run inside the command window.
    deadline = time.monotonic() + PRESSURE_BUDGET_SECONDS
    for index in range(1, 257):
        if time.monotonic() > deadline:
            break
        sequence = ((attempts + index + 1) % 999_999) + 1
        before_filesystem = read_filesystem(config)
        reply = client.call({"op": "trace", "sequence": sequence, "size": "large"})
        current = _archive(config)
        if current is None:
            synchronized = False
            continue
        _audit_archive(client, current)
        current_filesystem = read_filesystem(config)
        LOG.info(
            "trace archive free_bytes=%d total_bytes=%d",
            current_filesystem.free_bytes if current_filesystem else -1,
            current_filesystem.total_bytes if current_filesystem else -1,
        )
        always(
            _retained(prior, current, time.time_ns()),
            "Trace spool pressure retains previously witnessed archive bytes",
        )
        if reply is not None and reply.status == "200" and synchronized:
            always_or_unreachable(
                len(set(current) - set(prior)) == 1,
                "Trace spool acknowledged pressure intake has one durable new batch",
            )
        if before_filesystem is not None and before_filesystem.free_bytes == 0:
            reachable("Trace spool observed exhausted filesystem backing")
        if reply is not None and reply.status in ("429", "503"):
            always(
                _retained(prior, current, time.time_ns())
                and (reply.status != "429" or not synchronized or set(current) == set(prior)),
                "trace spool saturation preserves accepted archive bytes and refuses on exhausted backing",
            )
        if reply is not None and reply.status == "429":
            reachable("Trace spool reached real archive or pending quota refusal")
            break
        if reply is not None and reply.status == "503":
            reachable("Trace spool storage unavailable and refused further intake")
            again = client.call(
                {"op": "trace", "sequence": ((sequence + 1) % 999_999) + 1, "size": "small"}
            )
            retained = _archive(config)
            if again is not None and retained is not None:
                _audit_archive(client, retained)
                always_or_unreachable(
                    again.status != "200" and _retained(current, retained, time.time_ns()),
                    "Trace spool uncertain storage refuses later admission without evicting custody",
                )
            break
        prior = current
        synchronized = True
    _physical_pressure(client, config, prior, ((attempts + 258) % 999_999) + 1)
    return 0


def main(mode: str) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    if mode == "capacity":
        return run_capacity()
    if mode == "recovery":
        return run_recovery()
    if mode == "traces":
        return run_traces()
    raise ValueError("invalid recorder scenario")
