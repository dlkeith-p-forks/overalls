# Auth mail post-ACK transaction-loss property

## Scope and architecture impact

Base edee0815. The original post-ACK extension changes the committed mail
fixture and distributed property file. The subsequent reproduced sender-domain
identity defect also changes DeliverAuthEmail and expected IDs in mail tests. Reviewed ADR-0040's carried-forward ADR-0024 decisions, the real
DeliverAuthEmail/Ash action transaction, root/Marshall/Accounts/test contracts,
SMTP fixture and captured cleanup. This verifies existing uncertainty, stable
retry identity and encrypted-payload retirement requirements. The original extension has no production impact. The subsequent repair changes
the Message-ID namespace while preserving accepted ADR-0024/0040 retry identity
and uncertainty decisions; its upgrade boundary is documented below. No new
resource, authorization or deployment topology. Self-review.

## Independent observations

Three independent Marshall BEAMs use separate real PostgreSQL pools and actual
verified-TLS SMTP. After real DATA acceptance, a test-only after_action hook
parks the real delivery transaction with delivered status and nil ciphertext.
A peer-local ETS gate returns only nonce-correlated booleans through standard-I/O
RPC. Its owner is the delivery process; no payload, record or diagnostic escapes.
The third peer still observes the original committed pending ciphertext digest.
The second must wait on the exact first owner's row lock before halt137 kills
the first. The successor submits the same Message-ID/body/token digest, commits
delivered/nil, and a replacement peer's terminal replays open no SMTP connection.
Duplicates across lost commit are permitted; SMTP acceptance is not inbox delivery.

## Recorded verification

The corrected full file passed exit0, seed0,70.4seconds: three properties,
including the unchanged pre-ACK crash and successful serialization histories.
Warnings-as-errors compiler and formatting checks passed before execution.
Log `/tmp/kittens-mail-post-ack-baseline2.log`. The new history passed all three
generated draws; this record does not assert every random ordering was selected.
The open-transaction/delivered/erased gate assertion establishes the tested hook
boundary; it is not inferred from successful SMTP alone.

The first draft failed exit2,seed0,93.7seconds: two existing properties passed,
new property received no parent-PID gate notification after the SMTP reply.
Standard-I/O peer RPC does not provide that assumed delivery channel. This was
a fixture observation failure, not a product rollback counterexample. Replacing
the notification with the closed peer-local RPC observation produced the green
baseline. Log `/tmp/kittens-mail-post-ack-baseline.log`; no passing claim credits it.

The payload-retirement mutant failed all three properties in53.1seconds; the
new gate observed open transaction and delivered status but false payload
erasure. Only that earlier boundary is mutation-credited. Source was restored
byte-for-byte; the focused restored property passed28.2seconds,seed0, with two
exclusions. See the local-mail-post-ack-retain-ciphertext ledger for patch/hash
and retained copy. Full typing/consumer/publication gates and integration remain
open. Native host relay, inbox placement, hosted faults and configuration
changes between attempts are separate unverified boundaries. The pre-repair source
derived Message-ID's domain and link origin from live configuration; this
property holds those settings fixed and does not establish identity stability
across their rotation.

## Integration preflight

Re-reviewed the owned ETS observation, nonce matching, independent committed
snapshot, exact row-lock wait, halt137 observation and complete retry identity
comparison. The production payload-retirement mutant patch matches its recorded
SHA256. The retained fixture/property diff applies cleanly with `git apply --check`
to the origin98aff42a-merged control worktree; it has not been applied while that
tree's full Marshall gate is running. The temporary integration patch is
`/tmp/kittens-mail-post-ack-integration.patch`, SHA256
`7ad2190df6dd628a2c2280828e8040a703108a2c729591b2a19bb080d17012b9`.
This preflight proves patch compatibility only. Full merged execution, Dialyzer,
handbook/scenario integration and publication remain required. The untracked
dependency symlink is outside the patch.

## Sender-domain rotation candidate

ADR-0040 carries forward ADR-0024 Message-ID stability, and the production
email-bounded-external-attempt contract requires retries to retain the delivery's
Message-ID. Current send_bounded derives the domain afresh from live mail_from.
A successor using a different sender domain therefore appears able to change
the Message-ID of the same pending delivery. This is a source-backed mismatch,
not a recorded runtime counterexample or a new accepted configuration policy.

A fourth generated property is now present under the sender_rotation tag. It
holds the actual post-ACK/open-transaction barrier, changes only the second
peer's sender to one of two synthetic domains and independently verifies that
configuration, then retains the existing lock/committed-snapshot/crash/retry
identity oracle. The original three properties and their tags are preserved.
Pinned formatting passed, and the native contract structure gate plus all19
checker regression tests passed after installing the pinned checker with npm ci
and scripts disabled. Logs `/tmp/kittens-mail-sender-rotation-format.log` and
`/tmp/kittens-mail-sender-rotation-contracts2.log`. The first structural attempt
failed because this separate worktree lacked its checker installation; it is
not credited as a pass. At that draft checkpoint execution and typing were pending; the runtime
counterexample and focused repair result are recorded below. The earlier temporary integration patch and its clean-apply
result cover only the original post-ACK extension, not this additional draft.
Architecture impact is verification of the existing identity requirement;
any needed persistence/configuration repair still requires design review.

### Recorded sender-rotation counterexample

Focused sender_rotation execution exited2,seed0,21.0seconds: zero of one property
passed, three excluded. Compiler warnings-as-errors passed before execution.
Log `/tmp/kittens-mail-sender-rotation-baseline.log`. The independently observed
retry retained token/text/HTML digests but changed the same delivery's Message-ID
domain from example.test to retry.example.test after the successor configuration
changed. Thus the stable-Message-ID contract mismatch is reproduced over actual
verified-TLS SMTP and separate committed pools, not inferred from configuration
alone. This does not claim every generated domain/order was reached, terminal
replay success after the failure, inbox placement or a passing repair.
Production repair, architecture/handbook reconciliation and full typing/integration
gates remain required.

### Repair and first focused result

send_bounded now constructs the Message-ID from the immutable delivery UUID and
the fixed kittens.invalid application namespace; the current configured sender
still supplies From. The namespace is an identifier component, not an SMTP
recipient or a DNS/TLS endpoint. This preserves ADR-0024/0040's stable identity
requirement without adding mutable state or a database migration. Existing test
expectations for the former sender-domain format are reconciled. A local
config-independent identity contract and explicit send_bounded typespec were
added; no new diagnostic event or credential-bearing metadata was introduced.

The first repaired sender_rotation selection passed exit0,seed0,22.9seconds:
one property, three excluded; warnings-as-errors compilation passed. Log
`/tmp/kittens-mail-sender-rotation-repaired.log`. Its initial exact namespace
assertion was then refined only for rotation histories to compare actual first
and retry identities independently of the repair's chosen namespace; original
nonrotation histories retain their exact format expectation. Combined current-source mail execution passed exit0,seed0,266.0seconds:
19checks (9properties,10tests), including all four distributed properties,
waiting-authority, mail adapter and SMTP files. Log
`/tmp/kittens-mail-stable-identity-combined.log`. Full typing/integration gates
remain pending. The contract checker subsequently rejected contiguous @cc
blocks; a blank line separates them before rechecking. This is structural
formatting, not a runtime repair.

This correction cannot reconstruct a Message-ID already emitted by the older
sender-based implementation. An uncertain pending delivery spanning the old/new
format transition may have a different first upgraded ID; the guarantee now
covers attempts made by the corrected implementation, including sender changes.
No provider-side deduplication, inbox placement or body/origin stability across
endpoint configuration rotation is established. Full decision/handbook and final
architecture reconciliation remain required before publication.

## Sender-rotation mutation attribution

The isolated sender-derived-header mutant failed exit2,seed0,73.6seconds: all
four distributed properties failed. The targeted rotation history reached the
actual first/retry identity comparison and observed equal token/text/HTML
digests with differing example.test/retry.example.test Message-ID domains. Its
namespace-independent initial assertion therefore does not mask the regression.
Other histories failed earlier fixed-format assertions and are not credited as
rotation sensitivity. Later terminal observations after the targeted failure
are not credited. See the [mutation ledger](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/antithesis/scratchbook/mutation-testing/local-mail-sender-domain-identity.md).
Source restoration was compared byte-for-byte. Restored focused execution
passed exit0,seed0,28.1seconds:one property,three exclusions, warnings-as-errors
compilation; `/tmp/kittens-mail-sender-rotation-restored.log`. Full forced
typing/integrated publication remain pending.

## Current integration preflight

The complete tracked mail diff does not apply cleanly to verified control
255a2346: the property research, review index and scenario ledger have concurrent
edits. This is a documentation reconciliation requirement, not a source merge
failure. Production and test changes alone pass git apply --check against that
clean tree. Code patch `/tmp/kittens-mail-stable-identity-code.patch`, SHA256
`0b88d60f1cc90bef8535f65c77549d23abf6fbf06e0e6497b022d9f8d9535462`.
These checks do not establish integrated execution. The tracked patch excludes
untracked ledgers/review and the dependency symlink; it is not a complete
publication artifact. Latest main is also newer and must be integrated.

## Pre-integration typing

Pinned format --check-formatted and forced MIX_ENV=test Dialyzer passed exit0
on the corrected mail worktree. PLT rebuild passed in3m16.34s; analysis passed
in54.24seconds with zero errors, skips or unnecessary skips. Log
`/tmp/kittens-mail-stable-identity-dialyzer.log`. This covers the mail tree
before origin's later Lilly/Ziggy/Porsche changes and is not a full integrated
consumer gate. The source remained fixed during execution.
