# Terminal authority review

## Scope and evidence

ADR-0019 refines the accepted ADR-0008 access requirements with persisted session
identity, expiring writer claims and an explicit host-fence acknowledgment. It
adds a Marshall Terminal domain and integrates invalidation into the existing
Access/Compute transactions. It enables no remote console transport or UI.

## Findings and resolution

- **High, corrected authority gap:** an authenticated socket's cached user does
  not establish continued login or sharing authority. Sessions bind an encrypted
  token identifier and recheck AshAuthentication presence/expiry and persisted Cedar
  access on each operation. Three-node tests revoke a token after writer activation
  and verify that every node denies further authorization and refresh.
- **High, corrected coordination gap:** writer ownership needs shared authority.
  A unique per-VM row and VM lock serialize claims; one of three concurrent sessions
  wins while its repeats remain idempotent. A claim stays pending until a matching
  current-host/generation/epoch receipt. Old receipts cannot restore a previous writer.
- **High, required physical follow-up:** the host acknowledgment function is only
  a trusted coordinator boundary at present. No production console relay calls it.
  Lilly must enforce the local fence and bounded monotonic validity before a remote
  terminal endpoint can be enabled. Database tests do not prove physical single-writer
  behavior or a revocation deadline.
- **Medium, corrected cleanup race:** expiry workers take VM before mutating the
  session and recheck current expiry; a stale trigger cancels after renewal.
  Expiry is authorization state, so safety does not depend on scheduler punctuality.
- **Medium, corrected stale-generation gap:** checking only `observed_state` can
  admit a console while a new lifecycle generation is still pending. Opening now
  requires a completed current-generation start/provision operation, and lifecycle
  changes/non-running outcomes close established sessions under the VM lock.
- **Medium, corrected constraint gap:** PostgreSQL accepts an unknown check result,
  so `host_epoch > 0` alone admits null. The follow-up constraint requires complete
  host identity for pending/active claims and rejects negative epochs and invalid
  generations. Both migrations were reviewed; they add terminal tables and tighten
  the new constraint without removing existing application data.

## Verification

Marshall's final precommit passed 121 cases (8 properties, 113 tests), including
13 terminal authority cases and 10 distributed cases across three independent
BEAMs. It covers pending/active handoff, old receipts, token/role revocation,
lifecycle invalidation, host credential/session rotation, stale expiration work,
session limits, identifier encryption/audit exclusion, old running observations
and actual PostgreSQL rejection of incomplete/negative fences.

Compiler, formatting, pinned runtime, ADR checks (19 records) and Dialyzer passed.
The existing single upstream typespec exclusion remains unchanged. All four opt-in
host runtime integration cases also passed. No Lilly/protocol source or privileged
host behavior changed; physical console enforcement is not claimed by these checks.
The original-file audit found no missing files or additional unrelated edits, and
all 46 pre-existing staged relocations remain pure renames.

## Limits and follow-up

Implement the versioned relay and physical fence, then verify bounded buffers,
ordered/duplicate input handling, deadline expiry, restart and physical handoff.
Session/lease intervals are implementation defaults, not an end-to-end revocation
guarantee. Metadata retention and terminal workload acceptance remain open.
