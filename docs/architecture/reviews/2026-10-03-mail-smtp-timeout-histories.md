# SMTP post-DATA timeout histories

## Scope and architecture

Initial baseline `f26e0d47be6b5125aa6d166308bbdaafdadc7e47`; subsequently merged
origin/main `a414a5dfa1086869f6f32ec6ed2d12e48d602ba4`, retaining its Galileo/Audi
restart coverage. Verification extension under
ADR-0040's carried-forward ADR-0024 outbox and owner-deadline requirements.
Production delivery, transport configuration, token authority and decisions are
unchanged. Tests use the real Swoosh SMTP adapter, gen_smtp, verified loopback
TLS and the locked Ash delivery action inside a SQL sandbox.

## Properties and value menu

Two generated properties in
`marshall/test/marshall/mailer/smtp_test.exs` cover implicit TLS and mandatory
STARTTLS separately. Each runs three generated histories with one/two uncertain
attempts, an optional explicit 451 rejection and one/two/three terminal replays.
The actual ten-second deadline is preserved rather than accelerated. Repeated
attempt counts exercise identity over successive uncertain outcomes; these
direct Ash calls do not claim the Oban eight-attempt scheduling limit.

The fixture records complete DATA before withholding acknowledgment. Its real
transport receive must observe client closure; a fixture-initiated close cannot
satisfy that oracle. Each failed attempt leaves pending status and identical
ciphertext. Canonical Message-ID and decoded text/HTML hashes remain identical
through eventual successful delivery, and the final text contains the original
token. Terminal replay opens no connection and retains erased payload.
Elapsed-time checks allow scheduling tolerance (9–13 seconds); they do not prove
an exact kernel scheduling bound. MIME headers and random multipart boundaries
are not mistaken for payload changes.

## Contracts and fresh review

Reviewed root, Marshall, test, Accounts and Mailer contracts and the delivery
action's bounded-attempt, locked-recheck, terminal-erasure and outcome-after-commit
obligations. The SMTP adapter calls gen_smtp send_blocking in the owning task;
these tests observe its socket behavior rather than infer it from dependency
installation. Fixtures remain supervised and disposable.

Fresh review caught row accumulation across generated iterations, missing
ciphertext verification after rejection and a MIME MatchError failure path that
could expose token content. The fixture now identifies its newly inserted row,
compares only ciphertext booleans and sanitizes malformed MIME errors. Ciphertext
and token comparisons assert booleans; retry identity uses hashes. The isolated
fixture passes raw synthetic MIME through test messages, so an ExUnit mailbox
failure may expose fixture content. This does not establish universal diagnostic
redaction. Review also normalized the ignored transport-close return to `:ok`,
matching the fixture spec even when OTP reports a cleanup error; closure evidence
is recorded independently before this cleanup call.
Types are declared on fixture interfaces and new test helpers; postmerge
test-environment forced Dialyzer passed with zero errors or skipped findings.

## Execution

The first focused run failed both new properties in 52.9 seconds, seed63342;
all six existing tests passed. The failure was fixture row accumulation, not an
application defect. The corrected focused file passed eight checks (two properties
and six tests), seed63342, in 114.2 seconds. That run preceded the explicit name
mapping and final original-token assertion. Full Marshall precommit then passed
1,430 checks (229 properties, 1,201 tests), two excluded, seed282377, in
1,543.5 seconds. Forced Dialyzer passed in 53.66 seconds with zero errors,
skips or unnecessary skips after its dependency PLT rebuild. This execution
preceded the final ignored transport-close return normalization and the main
merge. Postmerge focused SMTP passed eight checks (two properties, six tests), seed63342, in 114.6 seconds.
Postmerge test-environment forced Dialyzer passed in 70.26 seconds with zero
errors, skips or unnecessary skips. The full-suite result retains its earlier
scope; focused runtime and final test-environment type verification cover the
later fixture normalization. A separate development forced Dialyzer passed in
62.21 seconds with zero errors, skips or unnecessary skips after rebuilding its
PLT; that environment does not include test support modules.

Merged documentation/static verification passed ADR structure, reviewed HLDD
receipts, generated options/coverage/views and all prek hooks, including Ruff,
formatting and ty. The evaluated Nix HLDD check passed in 33 seconds (archive
`1791024857174-3752065-0.jsonl`). These structural checks do not add SMTP or
machine acceptance evidence.

## Remaining gaps

Real provider/inbox placement, host relay composition, independently committed
transactions, process death after DATA acceptance, concurrent independent workers,
exact deadline-edge races and hosted faults remain separate. SQL sandbox rollback
does not prove durable commit. The fixture's complete DATA receipt is controlled
provider-side acceptance evidence, not inbox delivery or exactly-once SMTP.
