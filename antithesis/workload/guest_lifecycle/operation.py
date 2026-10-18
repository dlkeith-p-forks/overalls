"""Closed Compute operation channel with explicit attempted and acknowledged ledger."""

import json
import os
import re
import stat
import time
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID, uuid4

from core.outcome import Observation, State

IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}\Z")
# Refusal reasons are closed atom names; anything else is never kept or logged.
REASON_TOKEN = re.compile(r"[a-z][a-z0-9_]{0,63}\Z")


@dataclass(frozen=True)
class OperationAttempt:
    request_id: UUID
    operation: str
    request_key: UUID | None
    vm_id: UUID | None
    attempted: bool
    acknowledged: bool
    result_status: str | None


@dataclass(frozen=True)
class OperatorReply:
    request_id: UUID
    operation: str
    status: str
    value: object | None
    reason: str | None = None


def reason_token(raw: object) -> str:
    """Closed refusal token safe to log; unrecognised text collapses to one token."""
    if isinstance(raw, str) and REASON_TOKEN.match(raw):
        return raw
    return "unrecognized_reason"


class OperationLedger:
    """Keep ambiguous requests visible without converting them to successes."""

    def __init__(self) -> None:
        self.entries: list[OperationAttempt] = []

    def attempted(
        self,
        request_id: UUID,
        operation: str,
        request_key: UUID | None,
        vm_id: UUID | None,
    ) -> int:
        self.entries.append(
            OperationAttempt(request_id, operation, request_key, vm_id, True, False, None)
        )
        return len(self.entries) - 1

    def settle(self, entry: int, result: Observation[OperatorReply]) -> None:
        previous = self.entries[entry]
        acknowledged = result.state is State.OBSERVED and result.value is not None
        self.entries[entry] = OperationAttempt(
            previous.request_id,
            previous.operation,
            previous.request_key,
            previous.vm_id,
            True,
            acknowledged,
            result.value.status if acknowledged and result.value is not None else None,
        )


class ComputeLifecycleOperator:
    def __init__(self, root: Path, ledger: OperationLedger) -> None:
        self._requests = root / "requests"
        self._results = root / "results"
        self._ledger = ledger

    def _call(
        self,
        operation: str,
        fields: dict[str, object],
        *,
        request_key: UUID | None = None,
        vm_id: UUID | None = None,
        wait_seconds: float = 120,
    ) -> Observation[OperatorReply]:
        """@cc [owner:ghuntley,label:verification;recovery] lifecycle-attempt-is-not-effect
        Each published request MUST be logged as attempted. Only a matching
        private terminal response may be acknowledged; timeout or uncertain
        response MUST remain unavailable until a separate durable oracle reads
        the operation and physical guest effect.
        """
        if operation not in (
            "compute.catalog",
            "compute.provision",
            "compute.lifecycle",
            "compute.get",
            "compute.operation",
            "guest.identity",
            "guest.witness",
            "guest.crash",
        ):
            raise ValueError("unsupported Compute operation")
        request_id = uuid4()
        body: dict[str, object] = {
            "version": 1,
            "request_id": str(request_id),
            "operation": operation,
        }
        if operation.startswith("compute."):
            body["actor"] = "admin_a"
        body.update(fields)
        temporary = self._requests / f".{request_id}.tmp"
        final = self._requests / f"{request_id}.json"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(body, stream, separators=(",", ":"))
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.link(temporary, final)
            temporary.unlink()
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
        entry = self._ledger.attempted(request_id, operation, request_key, vm_id)
        result = self._result(request_id, operation, wait_seconds)
        self._ledger.settle(entry, result)
        return result

    def _result(
        self, request_id: UUID, operation: str, wait_seconds: float
    ) -> Observation[OperatorReply]:
        result_file = self._results / f"{request_id}.json"
        # The operator is serial and may retry a crashed evaluation.
        deadline = time.monotonic() + wait_seconds
        while time.monotonic() < deadline:
            try:
                info = result_file.lstat()
            except FileNotFoundError:
                time.sleep(0.1)
                continue
            if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 8192:
                return Observation.unavailable()
            try:
                raw: object = json.loads(result_file.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError):
                return Observation.unavailable()
            if (
                not isinstance(raw, dict)
                or raw.get("version") != 1
                or raw.get("request_id") != str(request_id)
                or raw.get("operation") != operation
            ):
                return Observation.unavailable()
            status = raw.get("status")
            if status == "ok" and "value" in raw:
                return Observation.observed(
                    OperatorReply(request_id, operation, status, raw["value"])
                )
            if status in ("error", "refused") and isinstance(raw.get("reason"), str):
                return Observation.observed(
                    OperatorReply(
                        request_id, operation, status, None, reason_token(raw.get("reason"))
                    )
                )
            return Observation.unavailable()
        return Observation.unavailable()

    def catalog(self, wait_seconds: float = 120) -> Observation[OperatorReply]:
        """A shorter wait lets a caller poll again instead of spending its window
        on one evaluation stalled behind injected faults."""
        return self._call("compute.catalog", {}, wait_seconds=wait_seconds)

    def guest_identity(self) -> Observation[OperatorReply]:
        return self._call("guest.identity", {})

    def guest_witness(
        self, placement_id: UUID, execution_epoch: int, generation: int
    ) -> Observation[OperatorReply]:
        if execution_epoch < 1 or generation < 1:
            raise ValueError("invalid guest witness tuple")
        return self._call(
            "guest.witness",
            {
                "placement_id": str(placement_id),
                "execution_epoch": execution_epoch,
                "generation": generation,
            },
        )

    def crash_guest(
        self,
        placement_id: UUID,
        execution_epoch: int,
        generation: int,
        qemu_pid: int,
        qemu_start_ticks: int,
    ) -> Observation[OperatorReply]:
        """@cc [owner:ghuntley,label:verification] crash-exact-current-process
        A crash fault MUST name the current placement tuple and QEMU PID/start
        tick obtained from a fresh independent witness. Unknown exit result
        MUST NOT count as a physical crash or recovery precondition.
        """
        if min(execution_epoch, generation, qemu_pid, qemu_start_ticks) < 1:
            raise ValueError("invalid guest crash identity")
        result = self._call(
            "guest.crash",
            {
                "placement_id": str(placement_id),
                "execution_epoch": execution_epoch,
                "generation": generation,
                "qemu_pid": qemu_pid,
                "qemu_start_ticks": qemu_start_ticks,
            },
        )
        if result.state is not State.OBSERVED or result.value is None:
            return Observation.unavailable()
        value = result.value.value
        if (
            result.value.status != "ok"
            or not isinstance(value, dict)
            or value.get("state") != "exited"
        ):
            return Observation.unavailable()
        return result

    def provision(
        self, image_id: str, vcpu: int, memory_bytes: int, disk_bytes: int, request_key: UUID
    ) -> Observation[OperatorReply]:
        if IMAGE_ID.fullmatch(image_id) is None or vcpu < 1:
            raise ValueError("invalid image ID")
        if memory_bytes < 1 or disk_bytes < 1:
            raise ValueError("invalid guest shape")
        return self._call(
            "compute.provision",
            {
                "request_key": str(request_key),
                "image_id": image_id,
                "profile": "standard",
                "vcpu": vcpu,
                "memory_bytes": memory_bytes,
                "disk_bytes": disk_bytes,
            },
            request_key=request_key,
        )

    def get(self, vm_id: UUID) -> Observation[OperatorReply]:
        return self._call("compute.get", {"vm_id": str(vm_id)}, vm_id=vm_id)

    def operation(self, vm_id: UUID, operation_id: UUID) -> Observation[OperatorReply]:
        return self._call(
            "compute.operation",
            {"vm_id": str(vm_id), "operation_id": str(operation_id)},
            vm_id=vm_id,
        )

    def lifecycle(self, vm_id: UUID, kind: str, request_key: UUID) -> Observation[OperatorReply]:
        if kind not in ("start", "stop"):
            raise ValueError("unsupported guest lifecycle mutation")
        return self._call(
            "compute.lifecycle",
            {"vm_id": str(vm_id), "kind": kind, "request_key": str(request_key)},
            request_key=request_key,
            vm_id=vm_id,
        )
