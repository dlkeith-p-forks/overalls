"""Real Compute admission commands with independent committed-row witnesses."""

import json
import logging
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal
from uuid import UUID, uuid4

from antithesis.assertions import always, reachable

from admission.attempts import AttemptLedger
from admission.client import (
    Catalog,
    CatalogImage,
    ComputeOperator,
    DomainResult,
    Provisioned,
    provisioned,
)
from admission.oracle import AdmissionOracle, Allocation
from core.config import Config, read_fixture
from core.outcome import Observation, State
from core.sql import SqlOracle

LOG = logging.getLogger(__name__)

# Fixed, nonsecret reasons an admission command can stop before reaching a
# settled Marshall decision. Each is logged at most once per process.
Unexercised = Literal[
    "Compute catalog result unavailable",
    "measured eligible host capacity unavailable",
    "no enabled catalog image advertised",
    "pre-submission SQL snapshot unavailable",
    "fresh admission key already has committed rows",
    "Marshall admission reply unavailable",
    "post-submission SQL snapshot unavailable",
    "operator image precheck refused before admission",
    "real delete was not observed archived",
]
_REPORTED: set[str] = set()
# The operator boots one Marshall release per request; under a saturated CPU
# that alone can approach 30 s, after which the result would be unknown.
OPERATOR_TIMEOUT_SECONDS = 90.0


# Marshall.Compute.Error reasons are lowercase atom names.
_REASON = re.compile(r"[a-z_]{1,64}")
_REFUSALS: set[str] = set()


def unexercised(reason: Unexercised) -> None:
    """Log one static reason once per process; never a pass, never a failure."""
    if reason not in _REPORTED:
        _REPORTED.add(reason)
        LOG.info("Compute admission unexercised: %s", reason)


def _configure_logging() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")


@dataclass(frozen=True)
class Runtime:
    owner_id: UUID
    host_ids: tuple[UUID, ...]
    operator: ComputeOperator
    oracle: AdmissionOracle
    sql: SqlOracle
    image: CatalogImage
    attempts: AttemptLedger


def _owner(path: Path) -> UUID:
    parsed: object = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(parsed, dict) or parsed.get("schema_version") != 1:
        raise ValueError("invalid Compute fixture")
    account = parsed.get("admin_a")
    if not isinstance(account, dict) or not isinstance(account.get("id"), str):
        raise ValueError("missing Compute fixture owner")
    return UUID(account["id"])


def load_runtime() -> Runtime | None:
    config = Config.from_environment()
    fixture = read_fixture(config.fixture_manifest)
    owner_id = _owner(
        Path(
            os.getenv(
                "ANTITHESIS_REPOSITORY_FIXTURE_FILE", "/run/overalls-control-secrets/fixture.json"
            )
        )
    )
    operator = ComputeOperator(
        Path(os.getenv("ANTITHESIS_CONTROL_OPERATOR_ROOT", "/run/overalls-control-requests")),
        timeout_seconds=OPERATOR_TIMEOUT_SECONDS,
    )
    image = select_image(operator.catalog())
    if image is None:
        return None
    sql = SqlOracle(config)
    return Runtime(
        owner_id, fixture.host_ids, operator, AdmissionOracle(sql), sql, image, AttemptLedger()
    )


def select_image(catalog: Observation[Catalog]) -> CatalogImage | None:
    """@cc [owner:ghuntley,label:verification;capacity] admission-catalog-image-selection
    Only an observed catalog with known capacity and an advertised enabled image
    MAY select an image. A fitting image is preferred; when the catalog's
    unlocked headroom is below the request shape the request is still submitted,
    because Marshall's serialized admission transaction, not this observer,
    decides placement and a definite refusal is a real admission decision.
    Every other outcome MUST log a static unexercised reason and select none.
    """
    if catalog.state is not State.OBSERVED or catalog.value is None:
        unexercised("Compute catalog result unavailable")
        return None
    selected = catalog.value
    if not selected.capacity_known:
        unexercised("measured eligible host capacity unavailable")
        return None
    if not selected.images:
        unexercised("no enabled catalog image advertised")
        return None
    return next(
        (candidate for candidate in selected.images if _catalog_fits(selected, candidate)),
        selected.images[0],
    )


def _catalog_fits(catalog: Catalog, image: CatalogImage) -> bool:
    vcpu, memory, disk = image.request_shape()
    return (
        catalog.available_vcpu >= vcpu
        and catalog.available_memory_bytes >= memory + 67_108_864
        and catalog.available_disk_bytes >= disk + 1_073_741_824
    )


def _rows(oracle: AdmissionOracle, owner_id: UUID, key: UUID) -> tuple[Allocation, ...] | None:
    result = oracle.allocation(owner_id, str(key))
    return result.value if result.state is State.OBSERVED else None


def new_admission(
    runtime: Runtime, key: UUID, name: str
) -> tuple[Observation[DomainResult], tuple[Allocation, ...] | None]:
    """@cc [owner:ghuntley,label:verification] admission-attempt-vs-commit
    The unique-key request MUST be recorded before submission. Only a valid
    domain result and successful independent SQL snapshot may establish the
    settled admission result; a missing reply MUST remain an uncertain attempt.
    """
    before = _rows(runtime.oracle, runtime.owner_id, key)
    if before is None:
        unexercised("pre-submission SQL snapshot unavailable")
        return Observation.unavailable(), None
    if before:
        unexercised("fresh admission key already has committed rows")
        return Observation.unavailable(), None
    result = runtime.attempts.submit(
        runtime.operator, runtime.oracle, runtime.owner_id, key, runtime.image, name
    )
    if result.response.state is State.UNAVAILABLE:
        # The first call may have committed; retry the identical Compute key.
        result = runtime.attempts.submit(
            runtime.operator, runtime.oracle, runtime.owner_id, key, runtime.image, name
        )
    after = result.committed.value if result.committed.state is State.OBSERVED else None
    return result.response, after


def _settled(
    response: Observation[DomainResult], rows: tuple[Allocation, ...] | None
) -> tuple[DomainResult, tuple[Allocation, ...]] | None:
    """A Marshall decision with its committed-row witness, or a logged reason."""
    if response.state is not State.OBSERVED or response.value is None:
        unexercised("Marshall admission reply unavailable")
        return None
    if rows is None:
        unexercised("post-submission SQL snapshot unavailable")
        return None
    if response.value.status == "error" and response.value.reason == "image_unavailable":
        # The operator's catalog precheck refused before Marshall admission ran.
        unexercised("operator image precheck refused before admission")
        return None
    if response.value.status == "error":
        _refused(response.value.reason)
    return response.value, rows


def _refused(reason: object) -> None:
    """Log Marshall's closed refusal token once per process; any other text stays unnamed."""
    token = reason if isinstance(reason, str) and _REASON.fullmatch(reason) else "unrecognized"
    if token not in _REFUSALS:
        _REFUSALS.add(token)
        LOG.info("Compute admission refused: %s", token)


def run_atomic_allocation() -> int:
    _configure_logging()
    runtime = load_runtime()
    if runtime is None:
        return 0
    key = uuid4()
    name = f"admission-{key.hex[:20]}"
    response, observed_rows = new_admission(runtime, key, name)
    settled = _settled(response, observed_rows)
    if settled is None:
        return 0
    result, rows = settled
    if result.status == "error":
        joined = not rows
    else:
        receipt = provisioned(result)
        joined = (
            receipt is not None
            and len(rows) == 1
            and rows[0].vm_id == receipt.vm_id
            and rows[0].owner_id == receipt.owner_id
            and rows[0].placement_id == receipt.placement_id
            and rows[0].host_id == receipt.host_id
            and rows[0].joined_at_admission()
        )
    always(joined, "Marshall acknowledged admission has one joined allocation and dispatch job")
    if joined and result.status == "ok":
        reachable("Marshall admission reached joined dispatch enqueue")
    return 0


def _one_identity(rows: tuple[Allocation, ...] | None, vm: Provisioned) -> bool | None:
    if rows is None:
        return None
    return len(rows) == 1 and rows[0].vm_id == vm.vm_id


def _archive(runtime: Runtime, vm_id: UUID) -> bool:
    """Only a real lifecycle delete followed by observed archival opens this branch."""
    deletion = runtime.operator.lifecycle(vm_id, "delete", uuid4())
    if (
        deletion.state is not State.OBSERVED
        or deletion.value is None
        or deletion.value.status != "ok"
    ):
        return False
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        state = runtime.oracle.archived(vm_id)
        if state.state is State.OBSERVED and state.value is True:
            return True
        time.sleep(1)
    return False


def _key_verdict(verdicts: list[bool]) -> int:
    if verdicts:
        always(all(verdicts), "Marshall replayed admission key never allocates a second VM")
    return 0


def _refused_replay(runtime: Runtime, key: UUID, name: str) -> bool | None:
    """Replay a definitely refused key once; it may admit at most one VM."""
    attempt = runtime.attempts.submit(
        runtime.operator, runtime.oracle, runtime.owner_id, key, runtime.image, name
    )
    settled = _settled(attempt.response, _committed(attempt.committed))
    if settled is None:
        return None
    result, rows = settled
    if result.status == "error":
        return not rows
    receipt = provisioned(result)
    return receipt is not None and _one_identity(rows, receipt) is True


def _committed(
    observation: Observation[tuple[Allocation, ...]],
) -> tuple[Allocation, ...] | None:
    return observation.value if observation.state is State.OBSERVED else None


def run_key_survives_archive() -> int:
    _configure_logging()
    runtime = load_runtime()
    if runtime is None:
        return 0
    key = uuid4()
    name = f"admission-{key.hex[:20]}"
    first_response, first_rows = new_admission(runtime, key, name)
    settled = _settled(first_response, first_rows)
    if settled is None:
        return 0
    first, initial_rows = settled
    verdicts: list[bool] = []
    if first.status == "error":
        if initial_rows:
            verdicts.append(False)
        else:
            # A real refusal (for example insufficient measured headroom) still
            # leaves a replayable key: the identical request may admit at most
            # one VM and never a second one.
            replay = _refused_replay(runtime, key, name)
            if replay is not None:
                verdicts.append(replay)
        return _key_verdict(verdicts)
    vm = provisioned(first)
    if vm is None or _one_identity(initial_rows, vm) is not True:
        verdicts.append(False)
        return _key_verdict(verdicts)

    identical_attempt = runtime.attempts.submit(
        runtime.operator, runtime.oracle, runtime.owner_id, key, runtime.image, name
    )
    identical = identical_attempt.response
    current = (
        identical_attempt.committed.value
        if identical_attempt.committed.state is State.OBSERVED
        else None
    )
    if current is None:
        unexercised("post-submission SQL snapshot unavailable")
    elif _one_identity(current, vm) is not True:
        verdicts.append(False)
    elif identical.state is State.OBSERVED and identical.value is not None:
        retry = provisioned(identical.value)
        same = retry is not None and retry.vm_id == vm.vm_id
        verdicts.append(same)
        if same:
            reachable("Marshall admission reused durable idempotency history")
    else:
        unexercised("Marshall admission reply unavailable")

    changed_attempt = runtime.attempts.submit(
        runtime.operator, runtime.oracle, runtime.owner_id, key, runtime.image, f"{name}-changed"
    )
    changed = changed_attempt.response
    current = (
        changed_attempt.committed.value
        if changed_attempt.committed.state is State.OBSERVED
        else None
    )
    if current is None:
        unexercised("post-submission SQL snapshot unavailable")
    elif _one_identity(current, vm) is not True:
        verdicts.append(False)
    elif changed.state is State.OBSERVED and changed.value is not None:
        if changed.value.status == "ok":
            verdicts.append(False)
        elif changed.value.reason == "idempotency_conflict":
            verdicts.append(True)
            reachable("Marshall admission rejected changed same-key request")
    else:
        unexercised("Marshall admission reply unavailable")

    if _archive(runtime, vm.vm_id):
        archived = _rows(runtime.oracle, runtime.owner_id, key)
        if archived is not None and len(archived) == 1 and archived[0].archived:
            replay_attempt = runtime.attempts.submit(
                runtime.operator, runtime.oracle, runtime.owner_id, key, runtime.image, name
            )
            replay = replay_attempt.response
            after = (
                replay_attempt.committed.value
                if replay_attempt.committed.state is State.OBSERVED
                else None
            )
            if after is not None:
                if _one_identity(after, vm) is not True:
                    verdicts.append(False)
                elif replay.state is State.OBSERVED and replay.value is not None:
                    repeated = provisioned(replay.value)
                    same = repeated is not None and repeated.vm_id == vm.vm_id
                    verdicts.append(same)
                    if same:
                        reachable("Marshall admission replay found archived idempotency history")
        elif archived is not None:
            verdicts.append(False)
    else:
        # Expected under the stub: the controlled executor never completes a delete.
        unexercised("real delete was not observed archived")
    return _key_verdict(verdicts)
