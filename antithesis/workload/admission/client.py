"""Typed private channel for real, closed Marshall Compute domain actions."""

import json
import os
import re
import stat
import time
from dataclasses import dataclass
from pathlib import Path
from typing import TypeGuard
from uuid import UUID, uuid4

from core.outcome import Observation, State

_IMAGE = re.compile(r"sha256:[0-9a-f]{64}\Z")
_NAME = re.compile(r"[a-z][a-z0-9-]{0,62}\Z")


@dataclass(frozen=True)
class CatalogImage:
    image_id: str
    minimum_memory_bytes: int
    minimum_disk_bytes: int

    def request_shape(self) -> tuple[int, int, int]:
        memory = max(536_870_912, self.minimum_memory_bytes)
        disk = max(2_147_483_648, self.minimum_disk_bytes)
        memory = (memory + 1_048_575) // 1_048_576 * 1_048_576
        disk = (disk + 4095) // 4096 * 4096
        return 1, memory, disk


@dataclass(frozen=True)
class Catalog:
    capacity_known: bool
    available_vcpu: int
    available_memory_bytes: int
    available_disk_bytes: int
    images: tuple[CatalogImage, ...]


@dataclass(frozen=True)
class Provisioned:
    vm_id: UUID
    owner_id: UUID
    placement_id: UUID
    host_id: UUID
    execution_epoch: int
    generation: int
    image_id: str
    profile: str
    vcpu: int
    memory_bytes: int
    disk_bytes: int


@dataclass(frozen=True)
class Machine:
    vm_id: UUID
    owner_id: UUID
    name: str
    placement_id: UUID
    host_id: UUID
    execution_epoch: int
    generation: int
    desired_state: str
    observed_state: str
    image_id: str
    profile: str
    vcpu: int
    memory_bytes: int
    disk_bytes: int
    archived: bool


@dataclass(frozen=True)
class DomainResult:
    operation: str
    status: str
    value: object | None
    reason: str | None


class ComputeOperator:
    def __init__(self, root: Path, timeout_seconds: float = 30.0) -> None:
        self._requests = root / "requests"
        self._results = root / "results"
        self._timeout = timeout_seconds

    def _call(self, operation: str, fields: dict[str, object]) -> Observation[DomainResult]:
        """@cc [owner:ghuntley,label:security;verification] compute-private-result
        Requests MUST use exact closed operations and private atomic publication.
        Only a same-ID, same-operation terminal result is evidence. Timeout,
        malformed output or `uncertain` MUST remain unavailable, including if
        Marshall committed after the reply was lost.
        """
        if operation not in (
            "compute.catalog",
            "compute.provision",
            "compute.lifecycle",
            "compute.get",
        ):
            raise ValueError("unsupported Compute operation")
        request_id = uuid4()
        body = {
            "version": 1,
            "request_id": str(request_id),
            "operation": operation,
            "actor": "admin_a",
        } | fields
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
        result_file = self._results / f"{request_id}.json"
        deadline = time.monotonic() + self._timeout
        while time.monotonic() < deadline:
            try:
                file_info = result_file.lstat()
            except FileNotFoundError:
                time.sleep(0.1)
                continue
            if (
                not stat.S_ISREG(file_info.st_mode)
                or file_info.st_mode & 0o077
                or file_info.st_size > 8192
            ):
                return Observation.unavailable()
            try:
                parsed: object = json.loads(result_file.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError):
                return Observation.unavailable()
            if (
                not isinstance(parsed, dict)
                or parsed.get("version") != 1
                or parsed.get("request_id") != str(request_id)
            ):
                return Observation.unavailable()
            status = parsed.get("status")
            if status == "uncertain":
                return Observation.unavailable()
            if parsed.get("operation") != operation:
                return Observation.unavailable()
            if status == "ok":
                if "value" not in parsed:
                    return Observation.unavailable()
                return Observation.observed(DomainResult(operation, "ok", parsed["value"], None))
            if status in ("error", "refused"):
                reason = parsed.get("reason")
                if not isinstance(reason, str) or not 1 <= len(reason) <= 128:
                    return Observation.unavailable()
                return Observation.observed(DomainResult(operation, "error", None, reason))
            return Observation.unavailable()
        return Observation.unavailable()

    def catalog(self) -> Observation[Catalog]:
        result = self._call("compute.catalog", {})
        if (
            result.state is not State.OBSERVED
            or result.value is None
            or result.value.status != "ok"
        ):
            return Observation.unavailable()
        value = result.value.value
        if not isinstance(value, dict) or not isinstance(value.get("capacity_known"), bool):
            return Observation.unavailable()
        available = value.get("available")
        if not isinstance(available, dict):
            return Observation.unavailable()
        vcpu = available.get("vcpu")
        memory = available.get("memory_bytes")
        disk = available.get("disk_bytes")
        if not (_nonnegative_int(vcpu) and _nonnegative_int(memory) and _nonnegative_int(disk)):
            return Observation.unavailable()
        images = value.get("images")
        if not isinstance(images, list):
            return Observation.unavailable()
        selections: list[CatalogImage] = []
        for image in images:
            if not isinstance(image, dict) or not isinstance(image.get("id"), str):
                return Observation.unavailable()
            image_id = image["id"]
            minimum_memory = image.get("minimum_memory_bytes")
            minimum_disk = image.get("minimum_disk_bytes")
            if (
                _IMAGE.fullmatch(image_id) is None
                or not _nonnegative_int(minimum_memory)
                or not _nonnegative_int(minimum_disk)
            ):
                return Observation.unavailable()
            selections.append(CatalogImage(image_id, minimum_memory, minimum_disk))
        return Observation.observed(
            Catalog(value["capacity_known"], vcpu, memory, disk, tuple(selections))
        )

    def provision(
        self, key: UUID, image: CatalogImage, *, name: str | None = None
    ) -> Observation[DomainResult]:
        """Select an aligned VM shape from a live catalog image's minimums."""
        if _IMAGE.fullmatch(image.image_id) is None or (
            name is not None and _NAME.fullmatch(name) is None
        ):
            raise ValueError("invalid closed provision selection")
        vcpu, memory, disk = image.request_shape()
        if memory > 274_877_906_944 or disk > 536_870_912_000:
            raise ValueError("catalog image exceeds bounded VM size")
        fields: dict[str, object] = {
            "request_key": str(key),
            "image_id": image.image_id,
            "profile": "standard",
            "vcpu": vcpu,
            "memory_bytes": memory,
            "disk_bytes": disk,
        }
        if name is not None:
            fields["name"] = name
        return self._call("compute.provision", fields)

    def lifecycle(self, vm_id: UUID, kind: str, key: UUID) -> Observation[DomainResult]:
        if kind not in ("start", "stop", "delete"):
            raise ValueError("unsupported lifecycle action")
        return self._call(
            "compute.lifecycle", {"vm_id": str(vm_id), "kind": kind, "request_key": str(key)}
        )

    def get(self, vm_id: UUID) -> Observation[DomainResult]:
        return self._call("compute.get", {"vm_id": str(vm_id)})


def provisioned(result: DomainResult) -> Provisioned | None:
    """Validate the small public receipt before using it as an acknowledgement."""
    value = result.value
    if (
        result.operation != "compute.provision"
        or result.status != "ok"
        or not isinstance(value, dict)
    ):
        return None
    raw_ids = (
        value.get("vm_id"),
        value.get("owner_id"),
        value.get("current_placement_id"),
        value.get("host_id"),
    )
    if not all(isinstance(item, str) for item in raw_ids):
        return None
    try:
        vm_id, owner_id, placement_id, host_id = (UUID(item) for item in raw_ids)
    except (TypeError, ValueError):
        return None
    epoch, generation = value.get("execution_epoch"), value.get("generation")
    image, profile = value.get("image_id"), value.get("profile")
    vcpu, memory, disk = value.get("vcpu"), value.get("memory_bytes"), value.get("disk_bytes")
    if (
        type(epoch) is not int
        or epoch < 1
        or type(generation) is not int
        or generation < 1
        or not isinstance(image, str)
        or _IMAGE.fullmatch(image) is None
        or profile != "standard"
        or type(vcpu) is not int
        or type(memory) is not int
        or type(disk) is not int
        or min(vcpu, memory, disk) < 1
    ):
        return None
    return Provisioned(
        vm_id,
        owner_id,
        placement_id,
        host_id,
        epoch,
        generation,
        image,
        profile,
        vcpu,
        memory,
        disk,
    )


def machine(result: DomainResult) -> Machine | None:
    """Validate current Compute.get state; `running` still needs physical witness."""
    value = result.value
    if result.operation != "compute.get" or result.status != "ok" or not isinstance(value, dict):
        return None
    raw_ids = (
        value.get("vm_id"),
        value.get("owner_id"),
        value.get("current_placement_id"),
        value.get("host_id"),
    )
    if not all(isinstance(item, str) for item in raw_ids):
        return None
    try:
        vm_id, owner_id, placement_id, host_id = (UUID(item) for item in raw_ids)
    except (TypeError, ValueError):
        return None
    name = value.get("name")
    epoch, generation = value.get("execution_epoch"), value.get("generation")
    desired, observed = value.get("desired_state"), value.get("observed_state")
    image, profile = value.get("image_id"), value.get("profile")
    vcpu, memory, disk = value.get("vcpu"), value.get("memory_bytes"), value.get("disk_bytes")
    archived = value.get("archived")
    if (
        not isinstance(name, str)
        or _NAME.fullmatch(name) is None
        or type(epoch) is not int
        or epoch < 1
        or type(generation) is not int
        or generation < 1
        or not isinstance(desired, str)
        or not isinstance(observed, str)
        or not isinstance(image, str)
        or _IMAGE.fullmatch(image) is None
        or not isinstance(profile, str)
        or type(vcpu) is not int
        or type(memory) is not int
        or type(disk) is not int
        or min(vcpu, memory, disk) < 1
        or not isinstance(archived, bool)
    ):
        return None
    return Machine(
        vm_id,
        owner_id,
        name,
        placement_id,
        host_id,
        epoch,
        generation,
        desired,
        observed,
        image,
        profile,
        vcpu,
        memory,
        disk,
        archived,
    )


def _nonnegative_int(value: object) -> TypeGuard[int]:
    return type(value) is int and value >= 0
