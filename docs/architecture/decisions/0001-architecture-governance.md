# ADR-0001: Architecture governance and monorepo

- ID: ADR-0001
- Date: 2026-09-15
- Status: accepted
- Implementation: implemented
- Components: repository, Marshall, Lilly
- Supersedes: none
- Superseded by: none

## Context

The project needs architecture reviews that continue as implementation changes.
Decisions, assumptions and implemented capabilities must remain distinguishable.
Marshall began as a nested Git repository with existing uncommitted work.

## Decision

Use Overalls as the monorepo, retaining Marshall history and working changes.
Keep a root AGENTS.md, component guidance, repository-local architecture-review
and adr-maintenance skills, an overview, a numbered decision index and persisted
substantive reviews. Every change receives an impact assessment before editing
and against the final diff; architectural changes and milestone completion need
a full review. Update affected records in the same change.

Decision status is proposed/accepted/rejected/superseded. Implementation status
is planned/partial/implemented and requires evidence. Correct facts and evidence
in place; material replacement of an accepted decision creates a new ADR with
reciprocal supersession links and preserved rationale. Use existing task/plan
authorization for acceptance; unresolved new choices remain proposed.

Run the dependency-light Elixir structural checker locally and through Marshall
precommit; future Lilly must reuse it. This implements the user's authorized
architecture-governance plan and monorepo choice.

## Alternatives

A separate documentation repository would detach review from code changes.
Independent nested repositories would make shared skills and guidance discovery
less direct. Mandatory full reports for every edit add noise; an impact
assessment can establish that a small change preserves the architecture.

## Consequences

The same change can review decisions and implementation. Contributors must keep
indexes and evidence current. Structural validation detects mechanical drift;
human or agent review still judges rationale, evidence sufficiency and safety.
Old commit paths remain relative to the former Marshall root.

## Invariants and verification

- IDs are stable and unique; rejected/superseded IDs are never reused.
- Supersession is reciprocal and acyclic. Index metadata matches each record.
- Accepted does not imply implemented. Evidence points to real artifacts.
- Root guidance and skills are discoverable from root and Marshall.
- Regression and property tests exercise malformed records and graph changes.

## Implementation evidence

[Root guidance](../../../AGENTS.md) defines the workflow;
[review skill](../../../.agents/skills/architecture-review/SKILL.md) and
[maintenance skill](../../../.agents/skills/adr-maintenance/SKILL.md) implement
repeatable review instructions. [Validator](../../../scripts/adr_validator.ex)
and [CLI](../../../scripts/check_adrs.exs) check structure;
[tests](../../../marshall/test/architecture/adr_validator_test.exs) exercise
invalid metadata, references, evidence and supersession graphs.
[Precommit](../../../marshall/mix.exs) invokes the shared check. The
[baseline review](../reviews/2026-09-15-governance-baseline.md) records validation
and preserves platform gaps. Agent instructions are guidance, not a CI merge
protection rule.

[ADR-0028](0028-colocated-code-contracts.md) extends this workflow with colocated
requirements, scoped CONTRACTS and structural precommit gates. ADR rationale and
semantic review remain distinct from contract syntax validation.

## Open questions

CI hosting and branch protection are not selected. Add automated invocation of
the same checker when repository CI is introduced.

## Related decisions

All subsequent ADRs follow this lifecycle. See
[the overview](../README.md) and [decision index](README.md).
