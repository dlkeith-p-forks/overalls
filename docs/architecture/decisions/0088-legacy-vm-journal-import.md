# ADR-0088: Exact legacy VM journal import

- ID: ADR-0088
- Date: 2026-09-21
- Status: superseded
- Implementation: partial
- Components: Lilly VM execution, Lilly lifecycle audit
- Supersedes: none
- Superseded by: ADR-0159

> Superseded by [ADR-0159](0159-remove-legacy-compatibility.md) only for this whole decision; legacy journals no longer exist on any host. ADR-0159 carries every other requirement of this record forward unchanged.

## Context

ADR-0074 introduced explicit lifecycle state and audit envelopes without a
migration for older host metadata. Production activation then found retained
version-3 VM execution journals from the immediately preceding Lilly release.
Those journals have eleven exact fields and valid durable execution authority,
but no lifecycle `phase` or envelope. Rejecting them fenced Lilly and blocked
automatic-update health. Deleting or regenerating them would discard outcome,
generation and acknowledgment evidence required by ADR-0017.

The recovery task authorizes a permanent fix that preserves retained fleet
state. It does not authorize accepting arbitrary old or malformed formats.

## Decision

Lilly may import only the exact raw eleven-field version-3 VM execution journal
written by the pre-lifecycle implementation. Before import it applies the same
identity, integer, revision, outcome and coherence validation as a current
journal. An imported phase is the validated outcome state, or `idle` when no
outcome exists. The phase is lifecycle metadata and does not replace physical
reconciliation or establish a new outcome.

The caller continues to hold the actor journal lock. Import additionally takes
the existing audit lock, rereads and byte-compares the source, then atomically
replaces it with a valid lifecycle envelope. Every durable field is preserved,
the derived phase is added, and one `initialize_<phase>` audit event records the
time the pre-existing state entered lifecycle management. That event is not a
claim about when the physical transition originally occurred.

Current envelopes continue through the ordinary state-machine path. Any extra,
missing, malformed, differently bound or incoherent legacy field fails closed
without changing the file. This decision adds no compatibility for other
journal versions or resource types and permits no destructive reset.
It overrides only ADR-0074's original statement that this lifecycle deployment
supplied no old-journal migration; every associated fail-closed and state
retention requirement remains in force.

## Alternatives

Deleting retained actor state would lose execution authority and could permit
duplicate effects or incorrect capacity release. A read-only fallback would
make startup appear successful while leaving the first later mutation unable to
persist. A broad version upgrader would enlarge the authority boundary without
an observed need. Requiring fresh hosts follows ADR-0074's original rollout
assumption but cannot recover the already activated production fleet safely.

## Consequences

The first successful open permanently upgrades each exact legacy journal and
queues one bounded lifecycle audit event. A host with many retained placements
can therefore need several existing 16-event delivery batches, without changing
the 64-event per-journal bound. Import IDs and timestamps describe adoption into
the audit system, not historical physical execution.

The narrow importer remains production code after fleet convergence so an
older retained disk or host generation can recover through the same checked
path. Removing it requires separate evidence that no supported recovery source
can contain the exact legacy format.

## Invariants and verification

- Import preserves host, VM and placement identity, revisions, outcome ID and
  sequence, running evidence, and acknowledgment state.
- Validation completes before mutation; malformed and near-miss records remain
  byte-for-byte unchanged.
- The source is rechecked under the audit lock, so import cannot overwrite a
  concurrent journal change.
- The resulting envelope passes the ordinary lifecycle decoder and reopens
  through the current-format path.
- Unit tests cover running and empty imports, authority preservation, stable
  reopen, and malformed-shape refusal. Production verification must show Lilly
  leaves its fence while preserving retained actor journals.

## Implementation evidence

[VM journal import](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/lilly/lib/lilly/vm/journal.ex) performed the exact
shape check, existing authority validation, locked byte recheck and atomic audit
envelope publication. [Journal tests](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/lilly/test/vm/journal_test.exs)
exercised successful and refused imports without root or KVM. Focused tests and
Lilly's complete precommit gate passed; production rollout evidence remained
outstanding, so implementation was partial.

ADR-0159 Push 6 deleted the import (links above are permalinks to the last
revision containing it). The current [VM journal](../../../lilly/lib/lilly/vm/journal.ex)
accepts only the lifecycle envelope, and its [tests](../../../lilly/test/vm/journal_test.exs)
check that an unenveloped version-3 journal fails closed without rewriting.

## Open questions

None. Fleet validation remains implementation evidence rather than a design
choice.

## Related decisions

- [ADR-0017](0017-durable-vm-actors-and-host-ownership.md)
- [ADR-0036](0036-automatic-host-updates.md)
- [ADR-0074](0074-durable-lifecycle-state-machines.md)
- [Implementation review](../reviews/2026-09-21-legacy-vm-journal-import.md)
