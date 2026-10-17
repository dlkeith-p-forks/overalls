# Committed mail worker histories

## Scope and architecture

Baseline `9b26caa5d35fa2df6908b35682076622bd63a8f5`. Verification extension under
ADR-0024 and ADR-0040; no production delivery, token, protocol or deployment
decision changes. Three independent Marshall BEAMs use separate real PostgreSQL
pools, with the coordinating runner excluded from the peer count. Direct Ash
delivery actions exercise the locked recheck; they do not establish duplicate
Oban scheduling behavior.

## Histories and oracles

Two generated properties select rotating worker/observer assignments and one,
two or three terminal replays. Each branch runs three histories. The success
branch holds the first verified implicit-TLS connection after complete DATA,
proves the second peer is waiting on the first peer's outbox FOR UPDATE through
PostgreSQL application names and pg_blocking_pids, and asks the third peer to
read committed pending ciphertext identity. Releasing the acknowledgment must
allow both actions to return delivered while the concurrent listener counts
one connection.

The crash branch instead calls erlang halt with status137 in the first peer.
Its controller DOWN must retain the matching exit status and the real SSL
transport must report client closure. The waiting peer may retry the uncertain
submission, but decoded text/HTML, original token digest and Message-ID must
remain identical. It must commit delivered with erased payload; the third peer
must independently observe that commit, then a newly started replacement peer
must read the same terminal state and replay without opening a new connection.
This is bounded local committed transport evidence, not exactly-once
SMTP or inbox placement.

## Fixture contracts and review

Reviewed root, Marshall, test, Accounts, Mailer, committed cleanup/inventory and
delivery contracts. SMTP handlers are independently supervised with explicit
socket controlling-process transfer, so an earlier gated handler cannot block
acceptance and conceal duplicate sends. Test messages contain identity digests
and fixed protocol receipts, not raw MIME or token bytes.

Setup captures the exact outbox ID, stored token JTI and associated Oban job IDs
within one transaction before payload erasure. Teardown retires the peers before
deleting those captured rows; job deletion uses the shared helper to remove
trigger-created history. An independent complete-table inventory hashes every
field and row multiplicity to check restoration without printing payloads.

Fresh review identified setup leakage and assertion-masking cleanup paths.
Transactional setup, protected post-enqueue assertions and captured cleanup
outcomes preserve original assertion failures and separately report teardown
failures. Uncertain peer retirement forbids fixture deletion.

## Execution

The first focused file passed both properties in 53.3 seconds, seed63342,
including independent full-table fixture restoration. That execution preceded
the replacement-peer terminal check and structured RPC response validation.
The final focused file passed both properties in 63.7 seconds, seed63342,
including fresh replacement-peer terminal verification and full-table restoration.
Forced test-environment Dialyzer passed in 74.84 seconds with zero errors,
skipped warnings or unnecessary skips. Focused runtime and type evidence are
recorded in `/tmp/kittens-mail-committed-final-focused.log`. The evaluated Nix
HLDD check passed in 36 seconds (archive `1791025984098-215730-0.jsonl`). Full
Marshall precommit completed with terminal exit zero. Its runtime suite passed
1,432 checks (231 properties and 1,201 tests), with two exclusions, seed612345,
in 1,525.2 seconds. Its final forced Dialyzer passed in 50.9 seconds with zero
errors, skipped warnings or unnecessary skips. The final source includes the
comment-only cleanup contract correction. Log:
`/tmp/kittens-mail-committed-precommit-final.log`.

## Remaining gaps

Oban scheduler-created duplicate jobs, token expiry/consumption while another
worker waits, a crash after provider acknowledgment but before status commit,
host relay composition, real provider/inbox placement, native machine and hosted
Antithesis fault coverage remain separate requirements. An observed killed BEAM
and closed loopback socket do not establish host death or network isolation.
