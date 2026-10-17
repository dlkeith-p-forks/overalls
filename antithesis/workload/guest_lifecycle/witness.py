"""Read the QEMU guest's independently observed process and port-1024 identity."""

import re
from dataclasses import dataclass
from uuid import UUID

from core.outcome import Observation, State
from guest_lifecycle.operation import ComputeLifecycleOperator

SHA256 = re.compile(r"[0-9a-f]{64}\Z")


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    start_ticks: int


@dataclass(frozen=True)
class GuestIdentity:
    image_id: str
    minimum_disk_bytes: int
    memory_bytes: int
    vcpu: int
    workspace_source_version: int | None


@dataclass(frozen=True)
class GuestSpec:
    placement_id: UUID
    execution_epoch: int
    generation: int


@dataclass(frozen=True)
class GuestWitness:
    guest_state: str
    placement_id: UUID
    execution_epoch: int | None
    generation: int | None
    boot_id: UUID | None
    ready: bool
    qemu: ProcessIdentity | None
    backend: ProcessIdentity | None
    boot_challenge_sha256: str | None
    image_manifest_sha256: str
    overlay_present: bool
    overlay_bytes: int | None
    overlay_sha256: str | None

    @property
    def physical_boot(self) -> tuple[ProcessIdentity, UUID, str] | None:
        if (
            not self.ready
            or self.qemu is None
            or self.backend is None
            or self.boot_id is None
            or self.boot_challenge_sha256 is None
        ):
            return None
        return self.qemu, self.boot_id, self.boot_challenge_sha256


def _positive(value: object) -> int:
    if type(value) is not int or value < 1:
        raise ValueError("invalid positive integer")
    return value


def _digest(value: object, *, nullable: bool = False) -> str | None:
    if value is None and nullable:
        return None
    if not isinstance(value, str) or SHA256.fullmatch(value) is None:
        raise ValueError("invalid SHA-256")
    return value


def _process(value: object) -> ProcessIdentity | None:
    if value is None:
        return None
    if not isinstance(value, dict) or set(value) != {"pid", "start_ticks"}:
        raise ValueError("invalid process identity")
    return ProcessIdentity(_positive(value["pid"]), _positive(value["start_ticks"]))


def parse_identity(raw: object) -> GuestIdentity:
    """@cc [owner:ghuntley,label:verification] guest-source-capability-is-explicit
    A null workspace source capability MUST remain absent; it MUST NOT be
    represented as a failed or completed checkout.
    """
    if (
        not isinstance(raw, dict)
        or set(raw)
        != {
            "state",
            "image_id",
            "minimum_disk_bytes",
            "memory_bytes",
            "vcpu",
            "workspace_source_version",
        }
        or raw["state"] != "ok"
    ):
        raise ValueError("invalid guest identity")
    image_id = raw["image_id"]
    source = raw["workspace_source_version"]
    if (
        not isinstance(image_id, str)
        or re.fullmatch(r"sha256:[0-9a-f]{64}", image_id) is None
        or source not in (None, 2)
    ):
        raise ValueError("invalid guest image capability")
    return GuestIdentity(
        image_id,
        _positive(raw["minimum_disk_bytes"]),
        _positive(raw["memory_bytes"]),
        _positive(raw["vcpu"]),
        source,
    )


def parse_witness(raw: object, spec: GuestSpec) -> GuestWitness:
    """@cc [owner:ghuntley,label:verification] guest-witness-exact-tuple
    A witness MUST match the requested placement, epoch and generation and
    include real process start ticks. Missing fields or transport failure are
    unknown, never physical absence or success.
    """
    if (
        not isinstance(raw, dict)
        or set(raw)
        != {
            "state",
            "guest_state",
            "placement_id",
            "execution_epoch",
            "generation",
            "boot_id",
            "ready",
            "qemu",
            "backend",
            "boot_challenge_sha256",
            "image_manifest_sha256",
            "overlay_present",
            "overlay_bytes",
            "overlay_sha256",
        }
        or raw["state"] != "ok"
    ):
        raise ValueError("invalid guest witness")
    if raw["placement_id"] != str(spec.placement_id):
        raise ValueError("guest witness tuple mismatch")
    execution_epoch = raw["execution_epoch"]
    generation = raw["generation"]
    if execution_epoch is not None:
        execution_epoch = _positive(execution_epoch)
    if generation is not None:
        generation = _positive(generation)
    if (execution_epoch is None) != (generation is None):
        raise ValueError("partial guest witness tuple")
    if execution_epoch is not None and (
        execution_epoch != spec.execution_epoch or generation != spec.generation
    ):
        raise ValueError("guest witness tuple mismatch")
    guest_state = raw["guest_state"]
    ready = raw["ready"]
    overlay_present = raw["overlay_present"]
    if (
        guest_state not in ("running", "stopped", "degraded", "uncertain")
        or type(ready) is not bool
        or type(overlay_present) is not bool
    ):
        raise ValueError("invalid guest witness state")
    raw_boot = raw["boot_id"]
    boot_id = UUID(raw_boot) if isinstance(raw_boot, str) else None
    if raw_boot is not None and boot_id is None:
        raise ValueError("invalid boot ID")
    overlay_bytes = raw["overlay_bytes"]
    if overlay_bytes is not None:
        overlay_bytes = _positive(overlay_bytes)
    qemu = _process(raw["qemu"])
    backend = _process(raw["backend"])
    challenge = _digest(raw["boot_challenge_sha256"], nullable=True)
    image_digest = _digest(raw["image_manifest_sha256"])
    overlay_digest = _digest(raw["overlay_sha256"], nullable=True)
    if image_digest is None:
        raise ValueError("missing image digest")
    if ready and (
        guest_state != "running"
        or execution_epoch is None
        or generation is None
        or qemu is None
        or backend is None
        or boot_id is None
        or challenge is None
    ):
        raise ValueError("ready without a complete physical boot")
    if overlay_digest is not None and (guest_state != "stopped" or not overlay_present):
        raise ValueError("overlay digest requires stopped disk")
    return GuestWitness(
        guest_state,
        spec.placement_id,
        execution_epoch,
        generation,
        boot_id,
        ready,
        qemu,
        backend,
        challenge,
        image_digest,
        overlay_present,
        overlay_bytes,
        overlay_digest,
    )


class GuestWitnessClient:
    def __init__(self, operator: ComputeLifecycleOperator) -> None:
        self.operator = operator

    def identity(self) -> Observation[GuestIdentity]:
        reply = self.operator.guest_identity()
        if reply.state is not State.OBSERVED or reply.value is None:
            return Observation.unavailable()
        try:
            return Observation.observed(parse_identity(reply.value.value))
        except (ValueError, TypeError):
            return Observation.unavailable()

    def witness(self, spec: GuestSpec) -> Observation[GuestWitness]:
        """@cc [owner:ghuntley,label:verification] observe-no-physical-mutation
        A workload witness MUST use the read-only operator bridge to the real
        guest process. A Lilly adapter report alone MUST NOT prove a physical
        boot or retained disk.
        """
        reply = self.operator.guest_witness(
            spec.placement_id, spec.execution_epoch, spec.generation
        )
        if reply.state is not State.OBSERVED or reply.value is None:
            return Observation.unavailable()
        try:
            return Observation.observed(parse_witness(reply.value.value, spec))
        except (ValueError, TypeError):
            return Observation.unavailable()
