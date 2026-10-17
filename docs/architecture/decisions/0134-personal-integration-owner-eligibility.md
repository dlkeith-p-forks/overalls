# ADR-0134: Explicit personal integration attachments

- ID: ADR-0134
- Date: 2026-10-03
- Status: accepted
- Implementation: implemented
- Components: Marshall, Galileo, Audi, Porsche, NixOS
- Supersedes: none
- Superseded by: none

## Context

ADR-0080 specifies attached user VMs and automatic availability for current team
members. The earlier deployed `galileo-vm-eligibility` contract also admitted a
personal owner's VMs without attachments. Production confirmed that discrepancy:
detach did not withdraw the owner's independent eligibility. The earlier proposal
would have clarified automatic personal access. The user instead selected explicit
attachments and explicitly rejected backwards compatibility.

## Decision

A personal integration admits a VM only through a current explicit attachment,
including VMs owned by the integration owner. Ownership retains management
permission and peer-target ownership requirements; it grants no source admission.
Admission and every renewal repeat the same attachment predicate. Removing the
attachment refuses new requests and cancels existing requests through the lease.

Live team membership continues to confer automatic availability for team-owned
integrations. Explicit attachments remain available independently of membership.
Every path retains live-owner, Customer-profile and current execution fences.
An attachment grants no other VM permission and exposes no integration secrets.

There is no grandfathering, attachment backfill, feature flag or migration.
Existing unattached personal integrations refuse when the new policy takes effect.
Complete cutover of all serving Marshall replicas precedes production acceptance;
old replicas can otherwise still admit requests or renew leases. Protocol wire
versions, persistence schema and credential custody remain unchanged.

## Alternatives

Automatic personal-owner availability was the original proposal. It is rejected
because the user selected per-VM opt-in and detach must withdraw personal access.
Backfilling all currently eligible VMs would preserve implicit access and is rejected
because compatibility was explicitly unnecessary. Removing automatic team access
would contradict ADR-0077 and is outside the selected change.

## Consequences

Personal integrations need an attachment before use, including after creation of
new owner VMs. Existing workflows that relied on implicit personal access receive
closed refusals until attached. Management remains available to authorized owners.
No credentials are returned or new peer tokens minted on attachment refusal;
renewal remains TTL-only and never reissues credentials or provenance.

## Invariants and verification

Generated histories must independently model attach/detach/reattach, personal and
team ownership, retirement, archival and stale execution. Refused admission and
all renewals preserve credential/token/configuration state. Attachment mutations
retain initiating actor attribution and audit receipts after commit. Native and
production fault workloads separately inspect origin connections, dispatches,
EOF/reset and active-request cleanup, with no retry or replay claims from elapsed
time alone. Cancellation checks use a five-second bound after observed renewal
refusal or expiry; this is test acceptance, not an upstream availability SLA.

## Implementation evidence

The [admission predicate](../../../marshall/lib/marshall/galileo/authorizations.ex)
requires attachment or current owning-team membership; personal ownership is no
longer a shortcut. The [renewal histories](../../../marshall/test/marshall/galileo/renewal_history_test.exs)
add personal-owner attachment histories with an independent durable-state oracle.
Before repair the new property reproduced unattached personal admission.
Generated authority histories, native blocked upload/partial response faults and
real-policy fleet withdrawal passed. Both serving production hosts activated
`7fda1272`, including the policy/cancellation and refusal-classification fixes.
Actual direct/peer unattached403, attach/detach/restoration and1MiB upload digests
passed; open-request withdrawal closed the origin and reached zero active requests
within 1.81 seconds after observed fresh refusal. Fixtures and reservations were
cleaned. The [implementation review](../reviews/2026-10-03-galileo-attachments-and-faults.md)
records exact execution, earlier failures and boundaries.

## Open questions

No eligibility policy question remains. Invalid-TTL/control-timeout permutations
have native evidence; equivalent production injections, fresh SSH admission
reliability and independent physical-host availability retain their separate gaps.
Those broader requirements remain with ADR-0080 rather than the selected policy.

## Related decisions

- [ADR-0080](0080-named-edge-integrations.md): original attachment and lease policy.
- [ADR-0077](0077-teams-and-shared-resources.md): automatic team availability.
