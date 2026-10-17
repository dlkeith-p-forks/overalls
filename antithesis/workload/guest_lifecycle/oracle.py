"""Pure, conditional checks over independent guest, storage and durable receipts."""

from dataclasses import dataclass
from enum import Enum
from uuid import UUID

from guest_lifecycle.witness import GuestIdentity, GuestWitness, ProcessIdentity


class Verdict(Enum):
    MATCH = "match"
    VIOLATION = "violation"
    UNEXERCISED = "unexercised"


@dataclass(frozen=True)
class PhysicalReceipt:
    operation_id: UUID
    vm_id: UUID
    placement_id: UUID
    execution_epoch: int
    generation: int
    boot_id: UUID | None
    boot_challenge_sha256: str | None
    guest_ready: bool
    status: str


@dataclass(frozen=True)
class StorageWitness:
    placement_id: UUID
    dataset_guid: str
    address: str
    network_attached: bool
    content_sha256: str | None


@dataclass(frozen=True)
class WorkspaceWitness:
    boot_id: UUID
    source_digest: str | None
    done_marker: bool
    head: str | None
    expected_head: str | None


@dataclass(frozen=True)
class RuntimeWitness:
    incarnation: str
    connected_session: UUID | None
    delivered_report_session: UUID | None
    delivered_report_age_ms: int | None
    actors_reconciled: bool
    ready: bool


def ready_matches_current_boot(
    receipt: PhysicalReceipt,
    current: GuestWitness | None,
    *,
    current_generation: int | None,
) -> Verdict:
    """@cc [owner:ghuntley,label:verification] ready-needs-exact-physical-proof
    A committed guest-ready receipt MUST match the current placement, epoch,
    generation, challenge and guest boot UUID. Missing current observation is
    unexercised; an emulated adapter result alone MUST NOT count as proof.
    """
    if receipt.status != "completed" or not receipt.guest_ready:
        return Verdict.UNEXERCISED
    if (
        current is None
        or current_generation is None
        or current.physical_boot is None
        or receipt.boot_id is None
        or receipt.boot_challenge_sha256 is None
    ):
        return Verdict.UNEXERCISED
    if (
        current.placement_id != receipt.placement_id
        or current.execution_epoch != receipt.execution_epoch
        or current.generation != receipt.generation
        or current_generation != receipt.generation
        or current.boot_id != receipt.boot_id
        or current.boot_challenge_sha256 != receipt.boot_challenge_sha256
    ):
        return Verdict.VIOLATION
    return Verdict.MATCH


def continuing_boot_adoption(
    before: GuestWitness | None,
    after: GuestWitness | None,
    *,
    accepted_new_generation: bool,
    stale_delivery_settled_new_journal: bool | None,
) -> Verdict:
    """Require the same observed process start tick and guest boot on adoption."""
    if not accepted_new_generation or before is None or after is None:
        return Verdict.UNEXERCISED
    old = before.physical_boot
    new = after.physical_boot
    if (
        old is None
        or new is None
        or before.generation is None
        or after.generation is None
        or stale_delivery_settled_new_journal is None
    ):
        return Verdict.UNEXERCISED
    if (
        before.placement_id != after.placement_id
        or before.execution_epoch != after.execution_epoch
        or after.generation <= before.generation
        or old != new
        or stale_delivery_settled_new_journal
    ):
        return Verdict.VIOLATION
    return Verdict.MATCH


def stopped_retains_disk(
    before: StorageWitness | None,
    stopped: StorageWitness | None,
    guest: GuestWitness | None,
    *,
    stop_completed: bool,
    compute_held: bool | None,
    disk_held: bool | None,
) -> Verdict:
    """@cc [owner:ghuntley,label:storage;verification] stop-needs-disk-and-vmm-witness
    A completed stop MUST have no live VMM or network attachment and MUST
    retain the measured dataset GUID, address, disk reservation and content.
    Missing physical or reservation evidence MUST remain unexercised.
    """
    if not stop_completed:
        return Verdict.UNEXERCISED
    if (
        before is None
        or stopped is None
        or guest is None
        or compute_held is None
        or disk_held is None
        or before.content_sha256 is None
        or stopped.content_sha256 is None
        or not before.dataset_guid
        or not stopped.dataset_guid
    ):
        return Verdict.UNEXERCISED
    if (
        before.placement_id != stopped.placement_id
        or guest.placement_id != before.placement_id
        or before.dataset_guid != stopped.dataset_guid
        or before.address != stopped.address
        or before.content_sha256 != stopped.content_sha256
        or stopped.network_attached
        or guest.guest_state != "stopped"
        or guest.qemu is not None
        or guest.backend is not None
        or not guest.overlay_present
        or compute_held
        or not disk_held
    ):
        return Verdict.VIOLATION
    return Verdict.MATCH


def restart_from_retained_disk(
    before_stop: StorageWitness | None,
    restarted: StorageWitness | None,
    old_boot: GuestWitness | None,
    new_boot: GuestWitness | None,
) -> Verdict:
    if (
        before_stop is None
        or restarted is None
        or old_boot is None
        or new_boot is None
        or before_stop.content_sha256 is None
        or restarted.content_sha256 is None
        or old_boot.physical_boot is None
        or new_boot.physical_boot is None
        or old_boot.execution_epoch is None
        or new_boot.execution_epoch is None
    ):
        return Verdict.UNEXERCISED
    if (
        before_stop.placement_id != restarted.placement_id
        or before_stop.dataset_guid != restarted.dataset_guid
        or before_stop.address != restarted.address
        or before_stop.content_sha256 != restarted.content_sha256
        or old_boot.physical_boot == new_boot.physical_boot
        or new_boot.execution_epoch <= old_boot.execution_epoch
    ):
        return Verdict.VIOLATION
    return Verdict.MATCH


def workspace_checkout_claim(
    identity: GuestIdentity,
    guest: GuestWitness | None,
    workspace: WorkspaceWitness | None,
    *,
    checkout_complete_claimed: bool,
) -> Verdict:
    """@cc [owner:ghuntley,label:verification] workspace-ready-is-separate
    A null source capability MUST mean checkout is unavailable, distinct from
    checkout refusal or completion. A completion claim needs a matching guest
    boot, durable done marker and actual Git HEAD.
    """
    if identity.workspace_source_version is None:
        return Verdict.VIOLATION if checkout_complete_claimed else Verdict.UNEXERCISED
    if not checkout_complete_claimed:
        return Verdict.UNEXERCISED
    if guest is None or workspace is None or guest.physical_boot is None:
        return Verdict.UNEXERCISED
    if (
        workspace.boot_id != guest.boot_id
        or not workspace.done_marker
        or workspace.head is None
        or workspace.expected_head is None
        or workspace.head != workspace.expected_head
    ):
        return Verdict.VIOLATION
    return Verdict.MATCH


def ready_while_checkout_pending(
    identity: GuestIdentity, guest: GuestWitness | None, workspace: WorkspaceWitness | None
) -> Verdict:
    if identity.workspace_source_version is None or guest is None or workspace is None:
        return Verdict.UNEXERCISED
    if guest.physical_boot is None or workspace.boot_id != guest.boot_id:
        return Verdict.UNEXERCISED
    return Verdict.MATCH if not workspace.done_marker else Verdict.UNEXERCISED


def runtime_restart_readiness(
    old_incarnation: str,
    before: RuntimeWitness | None,
    after: RuntimeWitness | None,
    old_vmm: ProcessIdentity | None,
    current_vmm: ProcessIdentity | None,
) -> Verdict:
    """New ready state requires fresh authenticated report and retained VMM."""
    if (
        before is None
        or after is None
        or after.incarnation == old_incarnation
        or old_vmm is None
        or current_vmm is None
    ):
        return Verdict.UNEXERCISED
    if not after.ready:
        return Verdict.MATCH if old_vmm == current_vmm else Verdict.VIOLATION
    if (
        after.connected_session is None
        or after.delivered_report_session != after.connected_session
        or after.delivered_report_session == before.delivered_report_session
        or after.delivered_report_age_ms is None
        or not 0 <= after.delivered_report_age_ms <= 15_000
        or not after.actors_reconciled
        or old_vmm != current_vmm
    ):
        return Verdict.VIOLATION
    return Verdict.MATCH
