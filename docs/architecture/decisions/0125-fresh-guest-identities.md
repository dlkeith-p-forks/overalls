# ADR-0125: Fresh guest identities after mailbox reuse

- ID: ADR-0125
- Date: 2026-09-25
- Status: superseded
- Implementation: partial
- Components: Marshall Accounts, SSH, terminal, guest account reconciliation
- Supersedes: ADR-0117
- Superseded by: ADR-0158

## Context

[ADR-0158](0158-durable-guest-identities.md) replaces the email-derived naming,
email-incarnation and compatibility rules below with immutable UID-derived guest
identities. The rationale and execution evidence in this record remain historical;
its other authority, workspace and retirement requirements carry forward.

ADR-0066 permits immediate verified registration with a fresh UUID after account
retirement. ADR-0117 carries forward ADR-0110's exact email-local-part guest name
and permanent reservation of historical names and UIDs. Their combination made
the replacement application account unable to acquire a personal guest identity.
Improvement 009 observed the unique-name refusal on a real guest; improvement 018
reproduced it through real actions and showed that re-sharing a VM with the new
UUID also refuses its whole roster. SSH account discovery advertised the old name.

## Decision

Replace **only the inherited exact guest-name rule** in ADR-0117. Carry forward
all its other requirements, including the personal workspace, automatic opening
receipts, terminal transport and consent, Cedar authority, roster boot proof,
guest account materialization, existing-disk limits and independent SSH admission.
ADR-0066's fresh account authority and cleanup ownership remain unchanged.
The user's verification campaign authorization includes correcting the workflow
and making the necessary architectural decision; the coordinator reviewed this
design before implementation.

An unused safe email local part remains the preferred full guest name. If a
historical allocation reserves it, assign the first at most 24 bytes of that
local part followed by `_g` and a newly allocated UID. Existing UID allocation
remains the PostgreSQL noncycling range **200000 through 999999**, so the complete
name stays within 32 ASCII bytes. No historical name or UID is reassigned, even
to an account that previously held it. The guest home remains `/home/<username>`.

Persist the eligible source local part separately from the assigned username.
Repeated requests for an unchanged local part reuse the same allocation. An
email rename, including returning to a previous name, retires the current
incarnation and creates another name and UID. The previous home stays on disk
and is not renamed or automatically transferred. Safe mailbox admission remains
exact and case-insensitive; suffixes are allocated by Marshall only.

Generated names may themselves equal historical exact mailbox names. Skip those
reservations using another fresh sequence value. Each complete batch has a budget
of 64 occupied suffix candidates and at most 512 users. Refuse the whole batch at
that collision budget or UID exhaustion. Rollback preserves every previous
incarnation and earlier allocation in the failed batch; consumed sequence values
may leave gaps. This bounds adversarial work without weakening permanent
reservation. Operators must resolve the cause before retrying repeated refusal;
resetting the UID sequence or deleting reservations is not a supported recovery.

Allocate each transaction's complete batch together. Lock unique User rows in
sorted UUID order, recheck active stored identity, and read current guest accounts
before taking the PostgreSQL namespace advisory lock. Only batches requiring a
new incarnation take that namespace lock. No subsequent user lock may be taken
by allocation. Roster retrieval must use this batch API rather than looping the
single-user wrapper. All PostgreSQL permanent and current-incarnation uniqueness
constraints remain authoritative.

Authenticated SSH `whoami` now resolves the durable guest identity and may allocate
it on first discovery, even before the account owns a VM. Its PaperTrail entry
retains the authenticated user as actor. Repeats preserve the name, UID and audit
inventory. Retired actors are refused. Installer/Lyra configuration consumes the
returned name; it must never reconstruct a name from an email. Browser personal
terminals and the SSH roster use the same allocator.

The migration adds a nullable `email_localpart` column and backfills it from each
historical exact username. It must not use today's renamed or tombstoned User
email. A null source on an old-release insert means the legacy exact username.
Every new-code allocation writes its source. Schema and wire data remain readable
by old releases. Old code can refuse a suffixed identity and advertise its old base
during a mixed rollout; its failed rename transaction must preserve the current
suffixed row. Complete guest usability requires all serving Marshall instances to
run the new allocator and discovery code. This change authorizes no deployment.

## Alternatives

Reusing the old name could attach the fresh UUID to an old home and was rejected.
Blocking same-email registration conflicts with ADR-0066. Replacing all names with
UUIDs would discard the requested email-derived names and rename unaffected users.
A persisted suffix only on collision preserves ordinary names and historical
ownership. Unbounded retries could hold user and namespace locks indefinitely;
bounded refusal preserves safety and limits resource use.

## Consequences

Some fresh accounts and rename generations receive suffixed names. Rerun installer
setup after an identity generation changes so its managed profile follows the
server's durable name. Existing guest helper and Lyra name validation already
support the resulting format. No guest wire protocol or new service is introduced.
UID exhaustion remains finite and closed. The namespace lock serializes only new
incarnation allocation; current-account roster refreshes retain user locking.

Authorized guest writers continue to have passwordless sudo. Distinct UID/home
allocation prevents automatic inheritance; it does not make old homes confidential
from newly authorized sudo-capable writers on a shared VM.

## Invariants and verification

- Fresh UUIDs inherit no old credentials, grants, memberships or terminal receipts.
- Names and UIDs remain permanently reserved across retirement and rename history.
- Repeats, case normalization and legacy nullable sources preserve current identity.
- Full 32-byte preferred names produce safe suffixed names of at most 32 bytes.
- Candidate collisions, the batch budget and exhausted sequence roll back completely.
- Independent Marshall processes serialize allocation and retirement through actual
  user/name locks; overlapping batches use canonical user ordering.
- SSH discovery, native personal SSH and browser terminals agree on the same
  persisted username, UID and home. Shared survivors remain usable after explicit
  replacement sharing and retain the historical home and UID.

## Implementation evidence

The [allocator](../../../marshall/lib/marshall/accounts/guest_accounts.ex),
[resource](../../../marshall/lib/marshall/accounts/guest_account.ex),
migration (`marshall/priv/repo/migrations/20260925172905_guest_identity_localpart.exs` at overalls revision `9fe1e493`, repository deleted),
[roster](../../../marshall/lib/marshall/ssh/guest_access.ex) and
[SSH discovery](../../../marshall/lib/marshall/ssh/commands.ex) implement the new
assignment and existing caller boundaries. Generated
[identity histories](../../../marshall/test/marshall/accounts/guest_identity_history_test.exs),
[rename/compatibility checks](../../../marshall/test/marshall/accounts/guest_accounts_test.exs)
and [bounded-allocation checks](../../../marshall/test/marshall/accounts/guest_identity_bounds_test.exs)
exercise database authority. The
[roster composition/name/UID binding properties](../../../marshall/test/marshall/ssh/guest_roster_history_test.exs)
and [three-BEAM roster contention schedules](../../../marshall/test/marshall/ssh/guest_roster_distributed_test.exs)
exercise the host-facing serving path: exact writer-set composition against an
independent oracle, strict version increase, stable re-fetch, the 512-candidate
atomic bound, collision-budget rollback with recovery, and the contested
retirement recheck; the [roster identity review](../reviews/2026-09-26-roster-identities.md)
records their execution and the recheck mutant. The [review](../reviews/2026-09-25-fresh-guest-identity-verification.md)
records actual runs, including [three-BEAM contention schedules](../../../marshall/test/marshall/accounts/guest_identity_distributed_test.exs),
and the complete [NixOS machine journey](../../../nix/verification/tests/machines/account-lifecycle/driver.py).
The latter passed old/fresh browser identities, distinct fresh personal and shared
guest SSH/home/UID, retained retired home ownership, explicit re-sharing and
packaged Lyra discovery/connection. It preserves old-key, unshared and stale-name
refusals. The review keeps exact revisions and the three earlier failed attempts;
database properties alone do not establish these native boundaries.

Roster boot proof implementation (ADR-0140 phase 3) changes the mechanism but
not the proof content:
- The physical evidence that ADR-0115 required (owned specification, current
  boot record, confined VMM, and an intent recheck after observing) is now
  gathered by the VM actor's own observation, under the placement lock.
- It is published as a boot row in Lilly's execution view.
- Roster lookups read that row without the lock, and the
  [exit watcher](../../../lilly/native/vm-watch/src/lib.rs) revokes it when the
  VMM dies.
- This removes the placement-lock race with reconciliation that ADR-0115
  bounded at one second, and that caused intermittent `account_refused`. Lock
  contention is now inconclusive rather than a refusal.
- [roster_bootstrap_test.exs](../../../lilly/test/roster_bootstrap_test.exs)
  covers roster-only authority during boot, revocation on negative evidence,
  revocation on disconnect and supersession, and contention being
  non-revoking.

## Open questions

Separate native Ubuntu fresh-identity acceptance, populated migration,
mixed-release operation, retained guest disks and production rollout remain
pending in the review. Wider UID-space capacity is a separate future decision;
this change does not widen or recycle the current range.

## Related decisions

[ADR-0066](0066-account-retirement.md),
[ADR-0110](0110-cedar-guest-ssh-accounts.md),
[ADR-0115](0115-ssh-roster-boot-authority.md),
[ADR-0117](0117-personal-terminal-machine-workspace.md),
[ADR-0036](0036-automatic-host-updates.md).
