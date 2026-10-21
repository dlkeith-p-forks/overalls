# ADR-0251: Thread-owned durable attachments

- ID: ADR-0251
- Date: 2026-10-21
- Status: accepted
- Implementation: partial
- Components: marshall, lyra, ziggy
- Supersedes: none
- Superseded by: none

## Context

Agents need to exchange files without embedding file bytes in model tool arguments
or results. Attachments must inherit the owning user thread's current permissions,
remain available independently of one guest or Marshall instance, and have explicit
lifecycle and security audit evidence. The user explicitly requested structured
upload/download tools, thread ownership, state machines, property tests and audit
logs, and authorized implementation.

## Decision

The Agents domain owns attachment metadata, encrypted PostgreSQL chunks and
content-free audit receipts. Current user-thread Cedar authority governs each
operation. Uploads require write permission; reads require read permission. A
storage identifier, previous authorization or executor lease alone grants none.

A file is bounded to 10 MiB, transferred in aligned chunks of at most 256 KiB and
encrypted with Marshall.Vault's tagged keyring. Publication verifies contiguous
content, size and SHA-256 before the attachment state machine enters available.
Thread-scoped retry keys preserve content identity and the initial uploader.

Model upload/download tools take absolute guest file paths and return metadata.
Authenticated guest transfer calls carry bytes separately from model arguments
and require the started command, current VM binding, executor fence and current
thread authority. Download publication must not overwrite existing guest files.
The existing control-socket limit is unchanged.

Browser multipart uploads use the same durable chunks. Browser downloads require
a current persisted login, current thread read access and an actor-bound,
short-lived, single-use token supplied in a header. Successful token consumption
and its audit receipt commit before bytes are returned.

All security-sensitive operations require content-free durable audit receipts;
system expiration receipts may have a null actor because no user initiated them.
Failure to persist a required receipt must refuse the operation atomically.
Machine stop/suspension removes board posts, not retained thread attachments.
Deletion and abandoned-upload reclamation require explicit state transitions;
ordinary thread archival must preserve authorized retained reads.

## Alternatives

- Inline base64 model arguments consume context, expose content to inference and
  make transport retries part of model history; rejected.
- Local Marshall blob directories require shared placement, replication and key
  custody that are absent from the existing deployment; rejected as the new path.
- An external object store can reduce PostgreSQL load but adds a new authority,
  credentials and recovery boundary. Revisit if measured bounded storage load
  warrants it; it is not required for the current file-size limit.

## Consequences

PostgreSQL backup and Vault key retention become attachment durability boundaries.
Chunk reads currently assemble the bounded file before slicing, which costs extra
work. Key rotation, quotas, orphan reclamation and native failure recovery require
explicit validation. Legacy local-storage APIs still exist and are not evidence of
completion of this decision.

## Invariants and verification

- Missing chunks, content conflicts and bad digests must prevent publication.
- Revoked authority and stale commands/fences must prevent content transfer.
- Model command results must contain bounded metadata, never uploaded bytes.
- Audit failure must preserve pre-operation state and permit a fresh valid retry.
- Token replay, expired tokens and revoked browser logins must refuse bytes.
- Property histories check content identity and failure atomicity; NixOS machine
  tests must establish the actual Lyra/Ziggy/Marshall transfer boundary.

## Implementation evidence

- [Attachment](../../../marshall/lib/marshall/agents/attachment.ex) implements the lifecycle.
- [AttachmentTransfers](../../../marshall/lib/marshall/agents/attachment_transfers.ex)
  and [AttachmentChunks](../../../marshall/lib/marshall/agents/attachment_chunks.ex)
  implement authorized durable transfer and integrity checks.
- [AttachmentAudit](../../../marshall/lib/marshall/agents/attachment_audit.ex)
  records successful transfer and browser token operations transactionally.
- [Lyra transfer](../../../lyra/src/agent/attachment.rs) implements guest file transfer.
- [Generated histories](../../../marshall/test/marshall/agents/attachment_history_test.exs)
  and [controller tests](../../../marshall/test/marshall_web/controllers/attachment_controller_test.exs)
  cover bounded BEAM behavior; exact executions are in the
  [review](../reviews/2026-10-20-thread-attachments.md).

Deletion and abandoned-upload audit coverage now exists. Available attachments
remain readable from retained authorized threads after archival; machine shutdown
does not delete them. A cleanup supervisor expires pending/uploading rows after
24 hours, using the explicit `failed` state and a system audit receipt. Explicit
deletion requires current thread manage authority, destroys chunks before the
terminal `deleted` transition, and records a receipt. Removal of legacy local APIs,
rotation, independent-connection races, native transfer acceptance and full gates
remain unfinished or unverified. Implementation remains partial.

## Open questions

Define retention/quota defaults and operational key-rotation acceptance before
claiming production attachment storage complete. No policy may discard retained
thread attachments merely because their machine stopped.

## Related decisions

- [ADR-0175](0175-thread-sharing-and-bound-machine-authority.md)
- [ADR-0142](0142-overallsprotocol-control-websocket.md)
