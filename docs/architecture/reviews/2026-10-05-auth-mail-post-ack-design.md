# Auth mail post-acknowledgement commit boundary

## Source and decision review

Reviewed DeliverAuthEmail, AuthEmail, CommittedMailFixture, the three-peer mail
properties, concurrent SMTP fixture, root/Marshall/Accounts contracts and
ADR-0024's accepted successor ADR-0040. SMTP acceptance is an irreversible
external effect; a lost database commit can legitimately require an identical
retry. Existing owner-crash coverage kills the worker while DATA's reply is
withheld, so it does not cover acknowledgement before commit failure.

## Draft property and implementation

The draft adds a test-only Ash after_action hook to the real deliver action.
It reports only nonce/booleans proving an open transaction, delivered status and
erased uncommitted ciphertext, then waits. Three independent Marshall peers
retain real verified-TLS SMTP and PostgreSQL pools. After releasing DATA250,
the first peer must reach that hook while a third still reads committed pending
state with its original ciphertext digest. A second peer must demonstrably wait
on the exact row. Halt137 then releases the uncommitted owner; the waiting worker
must submit the same canonical identity/body/token digest, commit delivered/nil,
and terminal replays including a replacement peer must open no further SMTP.
Duplicates across the uncertain commit are permitted, as ADR-0040 requires.

The existing pre-acknowledgement and successful serialization properties are
retained. The draft reuses captured fixture cleanup and peer-death witnesses;
it adds no production code, SQL trigger, resource, protocol or authority. Its
callback observations never expose the changeset, record or credential payload.

Draft files: `/tmp/kittens-mail-post-ack-draft-u2p3w2`. Retained patches:
fixture (`antithesis/scratchbook/properties/patches/auth-email-post-ack-fixture.patch` at kittens revision `9fe1e493`, repository deleted)
and property (`antithesis/scratchbook/properties/patches/auth-email-post-ack-property.patch` at kittens revision `9fe1e493`, repository deleted).
Pinned Code.format_string parsing/formatting passed; compiler, typing, runtime,
mutation and integration have not run. The main worktree remains frozen for
Marshall's full gate. This draft is not recorded passing handbook coverage.

## Remaining evidence

Run after the current component gate, preserving isolated fixture inventories.
Verify the hook actually runs before commit, real250 completion, rollback and
exact independent ciphertext observations, successor submission and terminal
no-connection replays. Target a realistic status/retirement mutant only after a
green baseline. Event ordering, actual host relay, inbox placement, native machine
composition and hosted faults remain separate. Architecture impact is verification
of ADR-0040's existing uncertainty/serialization decisions; self-review only.
