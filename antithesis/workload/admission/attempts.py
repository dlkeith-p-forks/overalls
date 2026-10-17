"""Workload-owned attempted envelopes, separate from Marshall receipts and SQL."""

from dataclasses import dataclass, field
from time import time_ns
from uuid import UUID

from admission.client import CatalogImage, ComputeOperator, DomainResult, provisioned
from admission.oracle import AdmissionOracle, Allocation
from core.outcome import Observation, State


@dataclass(frozen=True)
class Attempt:
    owner_id: UUID
    request_key: UUID
    image_id: str
    name: str
    vcpu: int
    memory_bytes: int
    disk_bytes: int
    submitted_at_ns: int


@dataclass(frozen=True)
class AttemptResult:
    attempted: Attempt
    response: Observation[DomainResult]
    committed: Observation[tuple[Allocation, ...]]

    def acknowledged_vm_id(self) -> UUID | None:
        if self.response.state is not State.OBSERVED or self.response.value is None:
            return None
        receipt = provisioned(self.response.value)
        return receipt.vm_id if receipt is not None else None


@dataclass
class AttemptLedger:
    """Preserve submitted envelopes even when a result or SQL read disappears."""

    entries: list[AttemptResult] = field(default_factory=list)

    def submit(
        self,
        operator: ComputeOperator,
        oracle: AdmissionOracle,
        owner_id: UUID,
        key: UUID,
        image: CatalogImage,
        name: str,
    ) -> AttemptResult:
        """@cc [owner:ghuntley,label:verification] attempted-is-not-acknowledged
        The workload MUST record the immutable request envelope before invoking
        Marshall. Transport loss and SQL unavailability MUST remain separate
        from definite domain error, acknowledged VM ID, and committed rows.
        """
        vcpu, memory, disk = image.request_shape()
        attempt = Attempt(owner_id, key, image.image_id, name, vcpu, memory, disk, time_ns())
        # The attempt exists before a request can commit or its reply disappear.
        self.entries.append(
            AttemptResult(attempt, Observation.unavailable(), Observation.unavailable())
        )
        response = operator.provision(key, image, name=name)
        committed = oracle.allocation(owner_id, str(key))
        result = AttemptResult(attempt, response, committed)
        self.entries[-1] = result
        return result
