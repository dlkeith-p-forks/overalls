"""Real Enrico refresh histories with SQL, origin and native object witnesses."""

import logging
import os
import time
from pathlib import Path
from uuid import NAMESPACE_URL, UUID, uuid4, uuid5

from antithesis.assertions import always, reachable

from core.interesting import choice
from core.outcome import State
from repository.client import Attempt
from repository.fixture import OriginState
from repository.native import occupied_slots, service_generation, snapshot_matches_inodes
from repository.observer import read_snapshot
from repository.oracle import Published
from repository.restart import EnricoRestarter
from repository.runtime import Runtime, load_runtime

LOG = logging.getLogger(__name__)


def _settled(
    runtime: Runtime, repository_id: UUID, attempt_id: UUID, seconds: float
) -> Attempt | None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        observation = runtime.enrico.status(repository_id, attempt_id)
        if (
            observation.state is State.OBSERVED
            and observation.value is not None
            and observation.value.state in ("failed", "succeeded")
        ):
            return observation.value
        time.sleep(0.2)
    return None


def run_published_head() -> int:
    """@cc [owner:ghuntley,label:verification] enrico-published-head-independent-oracle
    A failed-refresh verdict MUST require a ready pre-fault SQL head, a real
    Marshall worker failure audit, and an explicit-SHA native Git read of the
    original sentinel. Unavailable observations MUST leave the claim unknown.
    """
    runtime = load_runtime()
    repository_id = runtime.fixture.repository_id
    published = runtime.oracle.published(repository_id)
    source = runtime.origin.state()
    if (
        published.state is not State.OBSERVED
        or published.value is None
        or published.value.phase != "ready"
        or published.value.head is None
        or source.state is not State.OBSERVED
        or source.value is None
    ):
        LOG.info("Enrico published-head case unexercised: no ready fixture head")
        return 0
    try:
        return _published_head_effect(runtime, published.value, source.value)
    finally:
        runtime.origin.set_fault("normal")
        restored = runtime.origin.set_generation(source.value.generation)
        if restored.state is not State.OBSERVED or restored.value != source.value.head:
            LOG.info("Enrico origin generation restoration remains unknown")


def _published_head_effect(runtime: Runtime, published: Published, source: OriginState) -> int:
    repository_id = published.repository_id
    head = published.head
    if head is None:
        return 0
    generation = source.generation
    if source.head != head:
        matched = False
        for candidate in (1, 2, 3):
            changed = runtime.origin.set_generation(candidate)
            if changed.state is State.OBSERVED and changed.value == head:
                generation = candidate
                matched = True
                break
        if not matched:
            LOG.info("Enrico published-head case unexercised: published SHA is outside fixture")
            return 0
    expected = f"fixture-generation-{generation}\n".encode()
    before = runtime.oracle.blob(repository_id, head)
    if before.state is not State.OBSERVED or before.value != expected:
        LOG.info("Enrico published-head case unexercised: native baseline unavailable")
        return 0
    next_generation = 3 if generation != 3 else 1
    moved = runtime.origin.set_generation(next_generation)
    if moved.state is not State.OBSERVED or moved.value == head:
        return 0
    if not runtime.origin.set_fault("error"):
        return 0
    try:
        if not runtime.operator.refresh(uuid4(), repository_id):
            return 0
        deadline = time.monotonic() + 40
        failed_attempt: UUID | None = None
        while time.monotonic() < deadline:
            observed = runtime.oracle.published(repository_id)
            if (
                observed.state is State.OBSERVED
                and observed.value is not None
                and observed.value.phase == "failed"
                and observed.value.head == head
                and observed.value.attempt_id is not None
                and observed.value.attempt_id != published.attempt_id
            ):
                audited = runtime.oracle.failure_audit(repository_id, observed.value.attempt_id)
                if audited.state is State.OBSERVED and audited.value is True:
                    failed_attempt = observed.value.attempt_id
                    break
            time.sleep(0.2)
        if failed_attempt is None:
            return 0
        current = runtime.oracle.published(repository_id)
        if (
            current.state is State.OBSERVED
            and current.value is not None
            and current.value.head == head
            and current.value.phase != "removing"
        ):
            deadline = time.monotonic() + 8
            native = runtime.oracle.blob(repository_id, head)
            api = runtime.enrico.blob(repository_id, head)
            while (
                native.state is State.UNAVAILABLE or api.state is State.UNAVAILABLE
            ) and time.monotonic() < deadline:
                time.sleep(0.2)
                if native.state is State.UNAVAILABLE:
                    native = runtime.oracle.blob(repository_id, head)
                if api.state is State.UNAVAILABLE:
                    api = runtime.enrico.blob(repository_id, head)
            if native.state is State.OBSERVED or native.state is State.REFUSED:
                always(
                    native.state is State.OBSERVED and native.value == expected,
                    "Enrico published Git head remains addressable through failed refresh",
                )
            if native.state in (State.OBSERVED, State.REFUSED) and api.state in (
                State.OBSERVED,
                State.REFUSED,
            ):
                always(
                    api.state is State.OBSERVED and api.value == expected,
                    "Enrico explicit published SHA returns the original sentinel blob",
                )
            if native.state is State.OBSERVED and native.value == expected:
                reachable("Enrico retained prior published head across force push")
        audit = runtime.oracle.failure_audit(repository_id, failed_attempt)
        if audit.state is State.OBSERVED and audit.value is True:
            reachable("Marshall settled failed Enrico refresh without replacing head")
    finally:
        runtime.origin.set_fault("normal")
    return 0


def run_replay() -> int:
    """@cc [owner:ghuntley,label:verification] enrico-retained-replay-window
    Replay MUST reuse the exact repository and attempt IDs and compare native
    origin request receipts only within an observed retained completion window.
    No assertion may extend Enrico deduplication past eviction or restart.
    """
    runtime = load_runtime()
    repository_id = uuid5(NAMESPACE_URL, f"enrico-replay/{runtime.fixture.repository_id}")
    attempt_id = uuid4()
    generation = service_generation(runtime.mirror_root)
    if generation.state is not State.OBSERVED or generation.value is None:
        return 0
    if not runtime.origin.set_fault("delay", choice((500, 2999, 3000))):
        return 0
    try:
        first = runtime.enrico.refresh(
            repository_id, attempt_id, runtime.fixture.owner, runtime.fixture.name
        )
        if first.state is not State.OBSERVED:
            return 0
        duplicate_count = choice((1, 2, 8))
        for _ in range(duplicate_count):
            runtime.enrico.refresh(
                repository_id, attempt_id, runtime.fixture.owner, runtime.fixture.name
            )
        settled = _settled(runtime, repository_id, attempt_id, 35)
        if settled is None:
            return 0
        baseline = runtime.origin.state()
        if baseline.state is not State.OBSERVED or baseline.value is None:
            return 0
        replay_consistent = True
        replay_observed = False
        for _ in range(duplicate_count):
            duplicate = runtime.enrico.refresh(
                repository_id, attempt_id, runtime.fixture.owner, runtime.fixture.name
            )
            if duplicate.state is State.OBSERVED and duplicate.value is not None:
                replay_observed = True
                replay_consistent = replay_consistent and duplicate.value == settled
        after = runtime.origin.receipts(baseline.value.sequence)
        final_generation = service_generation(runtime.mirror_root)
        if (
            final_generation.state is not State.OBSERVED
            or final_generation.value != generation.value
        ):
            return 0
        if replay_observed:
            always(
                replay_consistent,
                "Enrico retained attempt replay returns its completed receipt",
            )
        if replay_observed and after.state is State.OBSERVED and after.value is not None:
            always(
                len(after.value) == 0,
                "Enrico retained attempt replay starts no second fetch",
            )
            reachable("Enrico returned retained attempt receipt without new fetch")
    finally:
        runtime.origin.set_fault("normal")
    return 0


def run_replay_cap() -> int:
    """@cc [owner:ghuntley,label:verification] enrico-cap-real-effects
    Cap evidence MUST come from 1,025 completed real native Git attempts, not
    injected Manager state. Deadline or any unsettled attempt leaves the cap
    branch unexercised; eviction MUST NOT be called indefinite deduplication.
    """
    runtime = load_runtime()
    repository_id = uuid5(NAMESPACE_URL, f"enrico-replay-cap/{runtime.fixture.repository_id}")
    generation = service_generation(runtime.mirror_root)
    if generation.state is not State.OBSERVED or generation.value is None:
        return 0
    if not runtime.origin.set_fault("normal"):
        return 0
    first_id: UUID | None = None
    latest_id: UUID | None = None
    deadline = time.monotonic() + 1500
    for index in range(1025):
        if time.monotonic() >= deadline:
            LOG.info("Enrico receipt-cap campaign unexercised: bounded deadline reached")
            return 0
        attempt_id = uuid4()
        submitted = runtime.enrico.refresh(
            repository_id, attempt_id, runtime.fixture.owner, runtime.fixture.name
        )
        if submitted.state is not State.OBSERVED:
            return 0
        terminal = _settled(runtime, repository_id, attempt_id, 12)
        if terminal is None or terminal.state != "succeeded":
            return 0
        if index == 0:
            first_id = attempt_id
        latest_id = attempt_id
    if first_id is None or latest_id is None:
        return 0
    newest = runtime.enrico.status(repository_id, latest_id)
    oldest = runtime.enrico.status(repository_id, first_id)
    if (
        newest.state is not State.OBSERVED
        or newest.value is None
        or newest.value.state != "succeeded"
        or oldest.state is not State.OBSERVED
        or oldest.value is None
    ):
        return 0
    finished_generation = service_generation(runtime.mirror_root)
    if (
        finished_generation.state is not State.OBSERVED
        or finished_generation.value != generation.value
    ):
        return 0
    always(
        oldest.value.state == "missing",
        "Enrico oldest completed receipt evicts after 1,025 native Git attempts",
    )
    if oldest.value.state == "missing":
        reachable("Enrico evicted oldest completed attempt receipt at cap")
    baseline = runtime.origin.state()
    if baseline.state is not State.OBSERVED or baseline.value is None:
        return 0
    replayed = runtime.enrico.refresh(
        repository_id, latest_id, runtime.fixture.owner, runtime.fixture.name
    )
    after = runtime.origin.receipts(baseline.value.sequence)
    final_generation = service_generation(runtime.mirror_root)
    if final_generation.state is not State.OBSERVED or final_generation.value != generation.value:
        return 0
    if replayed.state is State.OBSERVED and replayed.value is not None:
        always(
            replayed.value == newest.value,
            "Enrico newest receipt remains replayable at the bounded cap",
        )
    if after.state is State.OBSERVED and after.value is not None:
        always(
            len(after.value) == 0,
            "Enrico retained attempt replay starts no second fetch at receipt cap",
        )
    return 0


def _fill_eight_slots(runtime: Runtime, generation: str) -> bool:
    attempts = [
        (
            uuid5(NAMESPACE_URL, f"enrico-native/{runtime.fixture.repository_id}/{generation}/{i}"),
            uuid4(),
        )
        for i in range(8)
    ]
    for repository_id, attempt_id in attempts:
        submitted = runtime.enrico.refresh(
            repository_id, attempt_id, runtime.fixture.owner, runtime.fixture.name
        )
        if submitted.state is not State.OBSERVED or submitted.value is None:
            return False
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        slots = occupied_slots(runtime.mirror_root)
        if slots.state is State.OBSERVED and slots.value is not None and len(slots.value) == 8:
            return True
        time.sleep(0.05)
    return False


def run_native_admission_after_restart() -> int:
    """@cc [owner:ghuntley,label:verification] enrico-restart-physical-admission
    The restart branch MUST require an exact new Enrico service generation and
    pre/post native slot saturation. A physical admission verdict MUST use the
    current original lock inodes and complete passive holder snapshot, never
    only Manager status or a simulated task completion.
    """
    runtime = load_runtime()
    root = Path(os.environ["ANTITHESIS_ENRICO_CONTROL_ROOT"])
    baseline = runtime.origin.state()
    if baseline.state is not State.OBSERVED or baseline.value is None:
        return 0
    if not runtime.origin.set_fault("hold"):
        return 0
    try:
        if not _fill_eight_slots(runtime, "before"):
            LOG.info("Enrico restart case unexercised: eight pre-restart slots did not overlap")
            return 0
        try:
            receipt = EnricoRestarter(root).restart(uuid4())
        except OSError:
            return 0
        if receipt is None:
            LOG.info("Enrico restart case unexercised: no exact service restart receipt")
            return 0
        live = runtime.enrico.status(uuid4(), uuid4())
        if live.state is not State.OBSERVED or live.value is None or live.value.state != "missing":
            return 0
        deadline = time.monotonic() + 12
        retired = False
        while time.monotonic() < deadline:
            slots = occupied_slots(runtime.mirror_root)
            if slots.state is State.OBSERVED and slots.value is not None and not slots.value:
                retired = True
                break
            time.sleep(0.1)
        if not retired:
            LOG.info("Enrico restart lock retirement unproven: slot witness unavailable or held")
            return 0
        reachable("Enrico restart retired prior native Git slot owners")
        if not _fill_eight_slots(runtime, "after"):
            LOG.info("Enrico admission case unexercised: eight post-restart slots did not overlap")
            return 0
        ninth_id = uuid5(NAMESPACE_URL, f"enrico-native/{runtime.fixture.repository_id}/ninth")
        ninth_attempt = uuid4()
        runtime.enrico.refresh(ninth_id, ninth_attempt, runtime.fixture.owner, runtime.fixture.name)
        ninth = runtime.enrico.status(ninth_id, ninth_attempt)
        witness_deadline = time.monotonic() + 5
        snapshot_valid = False
        while time.monotonic() < witness_deadline:
            after = occupied_slots(runtime.mirror_root)
            snapshot = read_snapshot(
                Path(os.environ["ANTITHESIS_ENRICO_OBSERVER_FILE"]), receipt.generation
            )
            after_snapshot = occupied_slots(runtime.mirror_root)
            snapshot_valid = (
                snapshot.state is State.OBSERVED
                and snapshot.value is not None
                and snapshot_matches_inodes(snapshot.value, runtime.mirror_root)
                and after.state is State.OBSERVED
                and after.value is not None
                and after_snapshot.state is State.OBSERVED
                and after_snapshot.value == after.value
                and {slot.slot for slot in snapshot.value.slots if slot.holder_pids} == after.value
            )
            if snapshot_valid:
                break
            time.sleep(0.1)
        if snapshot_valid and snapshot.value is not None and after.value is not None:
            slot_holders = {pid for slot in snapshot.value.slots for pid in slot.holder_pids}
            always(
                len(after.value) <= 8
                and all(
                    set(repository.holder_pids).issubset(slot_holders)
                    and sum(
                        bool(set(repository.holder_pids) & set(slot.holder_pids))
                        for slot in snapshot.value.slots
                    )
                    <= 1
                    for repository in snapshot.value.repositories
                ),
                "Enrico native Git ownership bounds physical concurrent refreshes",
            )
        if (
            snapshot_valid
            and after.state is State.OBSERVED
            and after.value is not None
            and len(after.value) == 8
            and ninth.state is State.OBSERVED
            and ninth.value is not None
        ):
            always(
                ninth.value.state == "missing",
                "Enrico ninth refresh receives admission refusal while eight native slots remain held",
            )
            if ninth.value.state == "missing":
                reachable("Enrico observed ninth-admission refusal with eight physical slots held")
    finally:
        runtime.origin.set_fault("normal")
        held = runtime.origin.receipts(baseline.value.sequence)
        if held.state is State.OBSERVED and held.value is not None:
            for receipt in held.value:
                if receipt.mode == "hold":
                    runtime.origin.release_hold(receipt.sequence)
    return 0
