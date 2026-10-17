"""Real Compute admission commands with independent committed-row witnesses."""

import json
import logging
import os
import time
from dataclasses import dataclass
from pathlib import Path
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
        Path(os.getenv("ANTITHESIS_CONTROL_OPERATOR_ROOT", "/run/overalls-control-requests"))
    )
    catalog = operator.catalog()
    if catalog.state is not State.OBSERVED or catalog.value is None:
        return None
    selected = catalog.value
    image = next(
        (candidate for candidate in selected.images if _catalog_fits(selected, candidate)), None
    )
    if not selected.capacity_known or image is None:
        LOG.info("Compute admission unexercised: measured eligible host capacity unavailable")
        return None
    sql = SqlOracle(config)
    return Runtime(
        owner_id, fixture.host_ids, operator, AdmissionOracle(sql), sql, image, AttemptLedger()
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
    if before is None or before:
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


def run_atomic_allocation() -> int:
    runtime = load_runtime()
    if runtime is None:
        return 0
    key = uuid4()
    name = f"admission-{key.hex[:20]}"
    response, rows = new_admission(runtime, key, name)
    if rows is None or response.state is not State.OBSERVED or response.value is None:
        return 0
    result = response.value
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


def run_key_survives_archive() -> int:
    runtime = load_runtime()
    if runtime is None:
        return 0
    key = uuid4()
    name = f"admission-{key.hex[:20]}"
    first, initial_rows = new_admission(runtime, key, name)
    if first.state is not State.OBSERVED or first.value is None:
        return 0
    if initial_rows is None:
        return 0
    verdicts: list[bool] = []
    if first.value.status == "error":
        if initial_rows:
            verdicts.append(False)
        return _key_verdict(verdicts)
    vm = provisioned(first.value)
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
    if current is not None:
        if _one_identity(current, vm) is not True:
            verdicts.append(False)
        elif identical.state is State.OBSERVED and identical.value is not None:
            retry = provisioned(identical.value)
            same = retry is not None and retry.vm_id == vm.vm_id
            verdicts.append(same)
            if same:
                reachable("Marshall admission reused durable idempotency history")

    changed_attempt = runtime.attempts.submit(
        runtime.operator, runtime.oracle, runtime.owner_id, key, runtime.image, f"{name}-changed"
    )
    changed = changed_attempt.response
    current = (
        changed_attempt.committed.value
        if changed_attempt.committed.state is State.OBSERVED
        else None
    )
    if current is not None:
        if _one_identity(current, vm) is not True:
            verdicts.append(False)
        elif changed.state is State.OBSERVED and changed.value is not None:
            if changed.value.status == "ok":
                verdicts.append(False)
            elif changed.value.reason == "idempotency_conflict":
                verdicts.append(True)
                reachable("Marshall admission rejected changed same-key request")

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
    return _key_verdict(verdicts)
