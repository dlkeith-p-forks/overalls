# Governance milestone and platform baseline

Date: 2026-09-15. Scope: monorepo promotion, architecture workflow, initial ADRs,
repository skills and structural validation. This is not a production-readiness
review of a working VM platform.

This captures the initial baseline. The subsequent
[runtime and Lilly foundation review](2026-09-15-toolchain.md) records progress
against its toolchain and provisioner findings.

## Evidence and architecture impact

Inspected the existing Marshall working tree, including
[Mix configuration](../../../marshall/mix.exs),
[application supervision](../../../marshall/lib/marshall/application.ex),
[Accounts](../../../marshall/lib/marshall/accounts.ex),
[User](../../../marshall/lib/marshall/accounts/user.ex),
[router](../../../marshall/lib/marshall_web/router.ex),
[test configuration](../../../marshall/config/test.exs) and
[development environment](../../../devenv.nix).

The change establishes a shared repository boundary and maintenance workflow.
[ADR-0001](../decisions/0001-architecture-governance.md) is implemented here;
[ADR-0002](../decisions/0002-elixir-ash-and-types.md) through
[ADR-0009](../decisions/0009-assurance-and-testing.md) capture accepted platform
requirements with evidence-limited implementation status. No new transport,
fencing, key-management or HA-provider choice is silently accepted.

Git promotion retains the original HEAD
`17c1edae1389cd5dfb7f62d2f74df2019558a320` on `main`. The original index was
remapped under `marshall/` without rewriting history. A private local backup of
Git metadata and the original working files was made before migration. Original
file hashes and index entries were compared immediately after migration; source
contents were preserved and existing edits stayed separate from the staged
relocation.

## Findings

These are explicitly unimplemented requirements or open design details, rather
than regressions introduced by this governance milestone.

| Priority | Evidence and relevant decision | Consequence | Recommendation / completion condition |
| --- | --- | --- | --- |
| High | [Mix](../../../marshall/mix.exs) has the starter Elixir constraint and no Dialyzer; [ADR-0002](../decisions/0002-elixir-ash-and-types.md) | Required toolchain/type-analysis gates are incomplete | Pin the latest stable compatible Elixir/OTP pair, add Dialyzer and validate native dependencies before platform work relies on them |
| High | Only Accounts is registered in [configuration](../../../marshall/config/config.exs); [ADR-0003](../decisions/0003-control-plane-coordination.md), [ADR-0006](../decisions/0006-capacity-accounting.md) | There is no durable capacity ledger or provisioning transaction | Implement Ash hosts/reservations/operations and prove three-node allocation races and retry safety |
| High | Lilly, host supervision and VM lifecycle code are absent; [ADR-0004](../decisions/0004-lilly-and-vm-actors.md), [ADR-0005](../decisions/0005-vm-lifecycle-and-storage.md) | VM survival, persistent storage and bounded recovery are unverified | Supply two x86-64 KVM hosts; review execution/console protocols and verify crash/restart/reconciliation behavior |
| High | Network allocator and firewall implementation are absent; [ADR-0007](../decisions/0007-profile-networking.md) | NAT and VM isolation cannot be claimed | Review host/IPv6/anti-spoofing policy and execute a same-host/cross-host, same-profile/cross-profile connectivity matrix |
| High | [User](../../../marshall/lib/marshall/accounts/user.ex) provides authentication only; [ADR-0008](../decisions/0008-identity-sharing-and-terminal.md) | No Cedar enforcement, sharing or single-writer terminal exists | Implement the Cedar/Ash bridge, permission matrix and session revocation/fencing tests |
| High | [Configuration](../../../marshall/config/config.exs) uses starter logging; extension packages are only installed; [ADR-0009](../decisions/0009-assurance-and-testing.md) | Required encryption, redaction, history and cleanup/archival semantics are not established | Define resource coverage, key lifecycle and log schema; prove no secret/terminal leakage and safe cleanup |
| Medium | No workload targets or distributed tests; [ADR-0003](../decisions/0003-control-plane-coordination.md), [ADR-0009](../decisions/0009-assurance-and-testing.md) | Three-to-100-node support is a design target, not measured behavior | Specify host/VM/session/request counts, database connection budgets and failure/load acceptance criteria |

## Workflow review

The skills were walked through against these representative scenarios. This is
an instruction and fixture review, not a claim that a separate agent executed
each workflow:

- **Cosmetic edit:** a brief no-impact explanation satisfies root guidance;
  neither skill mandates an empty ADR or full report.
- **Architectural change:** identify affected records before implementation,
  assess relevant failure cases, update decisions/evidence, and persist a
  substantive review against the final diff.
- **Supersession:** a proposed replacement remains related until accepted;
  activation updates both directions and preserves old rationale. Tests reject
  missing reciprocal links, contradictory status and cyclic history.
- **Implementation update:** a planned record can become partial/implemented
  when real artifacts exist, with remaining obligations explained. Tests reject
  architecture-only or nonexistent evidence; review still judges sufficiency.

Both skills resolve shared paths from the Git root, and root guidance applies
from root and Marshall. Nested Phoenix guidance is preserved. The validator is
dependency-light; StreamData is explicit in Marshall because the new history
properties use it directly. It remains available in all environments to match
Ash's existing runtime dependency on it.

## Verification

Completed on 2026-09-15 using the available Elixir 1.18.4/OTP 28 shell:

- `elixir scripts/check_adrs.exs` from root and
  `elixir ../scripts/check_adrs.exs` from Marshall: passed, nine decisions.
- Bundled skill-creator `quick_validate.py` for both skills: passed. UI metadata
  was checked for valid descriptions, explicit skill invocation prompts and
  implicit invocation enabled.
- Git-root/ancestor discovery layout from root and Marshall: passed; shared
  instructions, skills and their local links resolve. This verifies repository
  layout, not a live editor's skill picker.
- `mix test test/architecture/adr_validator_test.exs`: 17 regression tests and
  two properties passed. Generated acyclic histories and deliberately closed
  replacement cycles exercised 70 property runs in total.
- `mix precommit`: passed, including the shared ADR check, compilation with
  warnings as errors, dependency-lock cleanup, formatting, and the complete
  suite of 22 tests plus two properties. Tests used a temporary local PostgreSQL
  instance; no real VMs were involved.
- `git fsck --no-reflogs`, staged relocation whitespace checks and comparison
  against the pre-migration snapshot: passed. Only the intended additions to
  Marshall's AGENTS.md, formatter and Mix configuration changed original files;
  all other original file bytes and the existing Phoenix guidance are preserved.

The governance milestone is complete. These checks do not establish Cedar,
capacity, networking, KVM execution, production HA, Dialyzer or the latest-stable
Elixir upgrade; the findings above remain follow-up obligations.

## Follow-up

Implement the platform sequence in [the overview](../README.md). Request only
missing information needed for that work: KVM host identities and workload
targets. Transport/enrollment, freshness cutoffs, writer leases, host drain and
guest-initiated shutdown semantics remain open design details in their ADRs.
Production automation, CI provider and branch protection are subsequent work.
