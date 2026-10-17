---
name: architecture-review
description: Review Overalls architectural changes and milestone readiness against ADRs and implementation evidence. Use for domain boundaries, APIs or protocols, persistence, authorization, VM isolation, capacity accounting, recovery, significant dependencies, and explicit architecture reviews. Ordinary edits still get a brief impact assessment under AGENTS.md.
---

# Architecture review

## Establish scope

1. Locate the repository root with `git rev-parse --show-toplevel`. Read root
   `AGENTS.md`, applicable component guidance, `docs/architecture/README.md`, and
   the decision index. Paths below are relative to that root.
2. Read relevant ADRs and inspect the actual code, configuration and tests. For
   uncommitted work inspect both staged and unstaged diffs and relevant untracked
   files; distinguish existing user work from the current task. For a requested
   branch/commit review, use its stated base. Do not infer implementation from
   dependency lists or documentation alone.
3. Assess impact before editing. If behavior stays within existing decisions and
   contracts, explain why briefly in the task/PR summary and proceed. Otherwise
   identify affected decisions, constraints and unresolved assumptions. Reuse
   authorization already present in the task or accepted plan.

## Review the change

Review only dimensions relevant to scope, including failure behavior:

- **Domains and contracts:** Ash resource ownership, domain boundaries, typed
  command/event schemas, protocol versions and rolling upgrade compatibility.
- **Coordination:** PostgreSQL authority, transaction boundaries, atomic capacity
  reservations, idempotency, duplicate jobs, fencing, stale observations and
  reconciliation after partial failures. Disconnection is not proof of death.
- **Execution and isolation:** privileged Lilly boundary, VM process/console
  survival, host-local storage, profile networks and cross-host VM isolation.
- **Access and data:** Cedar action/resource mappings, sharing/revocation, terminal
  writer ownership, secret handling, encryption, audit and archival semantics.
- **Capacity and operation:** inventory versus utilization versus reservations,
  freshness, architecture constraints, retention, overload/backpressure, recovery,
  observability, deployment and drain behavior.
- **Verification:** typespecs/compiler/Dialyzer evidence, meaningful properties,
  concurrent multi-node scenarios, real KVM/network tests and stated scale limits.

For each actionable finding record severity, a concrete file/test or observed
fact, relevant ADR, failure consequence and recommendation. Distinguish:

- implementation violates an accepted decision;
- accepted requirement remains explicitly unimplemented;
- decision itself needs reconsideration and a replacement ADR.

Do not turn speculative risks into new approval gates. Ask only for unresolved
information that materially blocks the authorized work; continue independent
work. Do not declare runtime safety from structural documentation validation.

## Close the review

Reassess the final diff and verification results. Use `$adr-maintenance` for
changed decisions/evidence and update the system overview when its map changes.
Persist substantive reviews and milestone audits under
`docs/architecture/reviews/YYYY-MM-DD-topic.md` and link them from the reviews
index. Include scope, findings, affected ADRs, unresolved choices, checks actually
run and follow-up work. Do not create a report for a cosmetic no-impact edit.

Finish with architecture impact, ADR IDs, validation and remaining gaps in the
task/PR summary. A completed review can have explicit unresolved findings; it is
not a claim that every accepted platform requirement is implemented.
