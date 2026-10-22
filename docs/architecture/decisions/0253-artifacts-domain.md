# ADR-0253: Artifacts domain for agent-published pages

- ID: ADR-0253
- Date: 2026-10-21
- Status: accepted
- Implementation: partial
- Components: Marshall artifacts, agents, Cedar authorization, audit, diagnostics
- Supersedes: none
- Superseded by: none

## Context

Agents running in threads produce reports, dashboards and small applications
that users want to keep, revise and share. Today the only output is the model
transcript or files inside the guest, which disappear with the machine and cannot
be shared under Marshall's authorization. The user asked for an `/artifacts`
surface modelled on Claude's Artifacts: agent-published HTML or Markdown pages,
versioned with read-before-write, private by default and shared through Cedar
owner, writer and viewer roles for users and teams, with per-artifact storage.
They required AshStateMachine lifecycles, Hegel property tests, NixOS machine
tests, the shared diagnostics library, Marshall's existing audit system, Oban
for background work and administrator moderation. They rejected share scopes and
a per-owner quota.

## Decision

Add the `Marshall.Artifacts` Ash domain. An `Artifact` is an AshStateMachine
(`active → deleting → deleted`) whose immutable `Version`s are dense per artifact
and unique per originating command. `VersionFile`s reference content-addressed
SHA-256 `Blob`s stored as 1 MiB Postgres chunks, so Postgres stays the only
shared durable store and backups cover content.

Publishing is optimistic: every publish names `base_version` (0 creates) and a
stale base is refused with the current version. Edits are exact, unique
`old_str`/`new_str` pairs applied in order, all or none. A files manifest adds,
replaces, keeps or removes (`null`) paths. Limits are checked before anything is
persisted: page 16 MiB; 255 files and 64 MiB per publish; 511 files and 256 MiB
per version; 128 KiB inline content. No per-owner quota exists.

Authorization uses Cedar entity `Artifact {owner, owners, writers, viewers,
active}` built fresh from direct and current team grants. Owners and co-owners
hold every action; writers read, publish and use all storage; viewers read, use
personal storage and read shared storage. Teams receive writer or viewer only.
Elevated administrators hold only `artifact_admin_delete`, which requires a
closed moderation reason and never grants content reads.

Per-artifact storage keeps personal and shared namespaces separate, text only,
with 20 MiB caps and 256-byte keys; only owners and writers write shared storage.

The agent `artifact` tool (publish, read, list, delete) is a Marshall-executed
server tool (ADR-0255) acting with the authority of the user who prompted the
turn. Large content may be staged from the guest (`artifact_stage`, executor
capability `artifacts-v1`) as hashed chunks over the fenced executor RPC, tracked
by a `PublishRequest` state machine (`staging → committed | refused | expired`).

Every mutation and refusal writes an `Artifacts.AuditEvent` (closed kinds and
reasons, 90-day retention) in the same transaction, with LifecycleEvents,
AccessChanges and paper trail where relevant; administrator deletion also writes
an `Administration.AuditEvent`. Diagnostics are catalogued `Marshall.Events`,
spans and metrics emitted after commit. Purge, blob sweep, ticket and staging
expiry, and storage-usage reconciliation run as idempotent Oban jobs.

## Alternatives

An object store would scale content better but adds a second durable store,
credentials and a separate recovery path; it is the recorded upgrade if total
artifact bytes outgrow Postgres backups. Last-writer-wins publishing silently
loses concurrent agent edits. Share scopes and a per-owner quota were proposed
and rejected by the user.

## Consequences

Users can keep, revise and share agent output under existing authorization and
audit. Postgres grows with artifact content; deduplication, batched purge, the
blob sweep and a total-usage metric mitigate this. Models must read before
writing, which costs a round trip but prevents lost updates.

## Invariants and verification

Versions are dense and immutable; a stale base never mutates; edits are all or
none; limits are enforced before persistence; Cedar decisions are fresh per
request; every operation writes exactly one audit row; deletion revokes live
view tickets. Hegel property tests cover edits, the manifest and tool request
parsing; end-to-end server-tool tests cover publish, stale refusal, read and
Cedar visibility. NixOS machine test `artifact-agent-publish` covers guest
staging, sharing and revocation.

## Implementation evidence

- [Domain](../../../marshall/lib/marshall/artifacts.ex) and [publisher](../../../marshall/lib/marshall/artifacts/publisher.ex).
- [Cedar policy](../../../marshall/priv/cedar/compute.cedar) and [schema](../../../marshall/priv/cedar/schema.cedarschema).
- [Agent tool](../../../marshall/lib/marshall/artifacts/tool.ex) and [staging](../../../marshall/lib/marshall/artifacts/staging.ex).
- [Property tests](../../../marshall/test/marshall/artifacts) and [server-tool tests](../../../marshall/test/marshall/agents/server_tool_test.exs).

Implementation is partial until the machine tests record passing runs; see the
[review](../reviews/2026-10-21-artifacts-and-thread-tool.md).

## Open questions

Whether to move blobs to an object store once total bytes exceed backup budgets.

## Related decisions

[ADR-0254](0254-isolated-artifact-content-origin.md) serves artifact content.
[ADR-0255](0255-thread-lifecycle-and-server-tool-dispatch.md) defines server-tool dispatch.
