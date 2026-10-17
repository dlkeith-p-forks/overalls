# Lilly completed launch recovery

## Architecture impact

Test-only extension of ADR-0017's durable attempt, independent executor lifetime
and stable outcome replay. Actor, Store, Journal and fake executor contracts were
reviewed. No execution, storage, protocol or deployment behavior changes.

## Verified history

The new property suspends the actual actor after durable attempt admission,
lets its executor complete and exit normally, and observes the successful result
in the actor mailbox while the journal remains byte-identical with no outcome.
It kills the actor before processing that result. Two replacement actor lifetimes
adopt the completed fake unit without another launch and replay the exact
recovered outcome identity and sequence one. Each actor is unlinked and its
cleanup is bounded and monitor-confirmed.

The adopted four-property file passed with warnings treated as errors, seed
`751543`, in 8.4 seconds, exit 0. Log:
`/tmp/kittens-lilly-completed-history-adopted.log`. The unchanged three-property
baseline separately passed in 7.6 seconds at the same seed. Component precommit
passed 475 checks (85 properties, 390 tests), seed `700852`, in 63.6 seconds,
exit 0. Forced Dialyzer passed in 17.66 seconds with zero errors, skips or
unnecessary skips. Log: `/tmp/kittens-lilly-completed-trusted-precommit.log`.
The pinned host helpers were selected directly from their root-owned Nix store
directory. An earlier run through user-owned profile ancestry correctly failed
three configuration cases and is not passing evidence. ADR/HLDD references,
generated coverage/options and Ash/deployment views passed. Nix `hldd` passed,
exit 0, archive `1790996693997-4133095-0.jsonl`. Final integrated checks remain
pending.

## Remaining gaps

This uses a durable controlled executor. It does not establish native systemd,
Firecracker, ZFS or full Lilly application death recovery. Those boundaries and
hosted process faults remain separate acceptance requirements.
