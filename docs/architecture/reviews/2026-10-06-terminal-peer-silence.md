# Terminal peer silence scheduling

## Scope and architecture impact

ADR-0083 requires both sides of the TLS terminal peer hop to end after fifteen
seconds without hearing from the peer. The incoming `PeerSocket` and outgoing
`Remote` instead test `elapsed > 15_000` at five-second intervals. Activity
between intervals can defer retirement until almost twenty seconds. This is an
implementation mismatch with the accepted recovery requirement. The repair
preserves authority, wire framing, guest lifetime, budget ownership and the
five-second outgoing ping cadence; it introduces no domain or deployment change.

## Repair under review

The retained experiment fork shortens incoming liveness wakes to the remaining
silence budget and expires exhausted budgets at equality. Outgoing silence gets
its own deadline callback, independent of heartbeat scheduling. A wake following
new activity recomputes the remaining budget; it neither closes an active hop nor
creates another heartbeat loop. Ordinary process retirement ends timer delivery.
No per-frame timer cancellation or accumulation is introduced.

## Verification evidence

The original incoming callback property failed with 500 milliseconds remaining
and a 5,000 millisecond scheduled wake, seed 0, zero successful draws, exit 2
(`/tmp/overalls-peer-deadline-original.log`). Repaired focused checks passed seven
checks (three properties and four tests), seed 0, 2.2 seconds, exit 0
(`/tmp/overalls-peer-deadline-repaired2.log`). Restoring the periodic incoming wake
alone reproduced the expected failure; after removing that mutant, both deadline
properties passed in 0.1 seconds (`/tmp/overalls-peer-deadline-restored2.log`).
An intervening mistaken restoration failed compilation and provides no behavior
evidence (`/tmp/overalls-peer-deadline-restored.log`).

These callbacks use constructed timestamps and actual timer-BIF traces. Generated
exhausted budgets include zero overdue time but do not freeze the runtime clock.
The existing TLS tests verify forwarding and budget-owner retirement; they do
not verify elapsed silence timing.

A new generated transport history attaches a real verified-TLS peer, sends output
between heartbeat ticks, observes receipt and the production `last_seen`, suspends
the incoming peer to withhold subsequent replies, renews the directory independently,
and monitors outgoing retirement within fifteen seconds plus 250 milliseconds
of scheduler allowance. It also expects viewer closure and incoming budget-slot
release after resumption. The first run reached the outgoing deadline and viewer
closure assertions, then failed an incoming process-DOWN assertion
(`/tmp/overalls-peer-tls-silence-repaired.log`, 20.3 seconds, exit 2).
Bandit's `WebSocket.Connection.do_stop/4` calls WebSock termination but returns
`:continue` with state `:closing`; application retirement does not imply immediate
server-process death. The corrected oracle checks actual budget-slot release.
The second run completed one draw but the next draw inherited an expiring
directory lease and retired at its ten-second directory check. The fixture now
renews the current nonce before every dial and midway through the silence wait;
the revised run passed three generated histories, seed 0, 49.1 seconds, exit 0
(`/tmp/overalls-peer-tls-silence-repaired3.log`). Neither failed run earns passing
property credit. The same history against original outgoing code failed at the
predicted missing outgoing DOWN beyond the silence deadline plus allowance:
generated offset 951 milliseconds, zero successful draws, seed 0, 17.2 seconds,
exit 2 (`/tmp/overalls-peer-tls-silence-original.log`). Directory renewal passed.
The repaired outgoing source is restored. Confirmation passed three checks
(the TLS history and two callback properties), seed 0, 48.9 seconds, exit 0
(`/tmp/overalls-peer-tls-silence-restored.log`). The reviewed source and tests are
integrated; the complete focused peer files passed eight checks (four properties,
four tests), seed 0, 50.1 seconds, exit 0 against the integration worktree
(`/tmp/overalls-peer-silence-integrated.log`).
The host stream and
attachment replies remain synthetic; native guest survival, independent-node
failure and hosted Antithesis execution remain separate gaps.

## Incoming confirmation and remaining work

Add the corresponding incoming elapsed-silence transport history; its fork
property completed one draw but then failed before the second dial on expired
fixture directory authority (full file66.6seconds,exit2). It now renews the
directory midway through silence. The subsequent termination-call trace was
unobserved by the deadline even though bounded diagnostics found the process
already gone. The new oracle timestamps the process's budget-release cast;
its focused run passed three generated histories, seed 0, 49.1 seconds, exit 0
(`/tmp/overalls-peer-incoming-silence-release-trace.log`). It confirms incoming
budget-release time, actual slot removal and outgoing viewer closure after
resumption. The same property against original incoming source failed at the
predicted deadline: offset951ms, zero successful draws,seed0,17.4seconds,exit2
(`/tmp/overalls-peer-incoming-silence-original.log`). Bounded state showed an open
connection, no activity renewal and an occupied budget slot. The repaired source
is restored; confirmation passed the three generated histories, seed0,
49.1seconds,exit0 (`/tmp/overalls-peer-incoming-silence-restored.log`). The incoming
property is integrated and the complete focused peer files passed nine checks
(five properties, four tests), seed0,98.5seconds,exit0
(`/tmp/overalls-peer-silence-both-integrated.log`).
The earlier observation failures are not credited as a production counterexample
or passing incoming property.
ADR-0083 evidence,
the interactive handbook and scenario ledger are updated in this change. Complete the
Marshall compiler, contracts, formatting, full test and forced typing gates,
individual handbook reviews and evaluated HLDD validation. This report does not
claim the broader source/research review or platform acceptance is complete.

Coverage generation/check, ADR structure/local links (140 decisions) and
Ash/deployment source views passed, exit 0
(`/tmp/overalls-peer-silence-evidence-check.log`). These structural checks do not
prove runtime deadline behavior or replace individual HLDD group reviews.

The read-only full HLDD check currently fails on all seven stale group receipts
(`/tmp/overalls-peer-silence-hldd-state.log`). The new chapter evidence also stales
the previously reviewed Protocol receipt. Each affected source/chapter group
requires individual review; no receipt was refreshed for this check.

Contract syntax/coverage passed (119 CONTRACTS files, 2,518 native notes,
208 parsed source files, 2,606 maintained source files), and applicable
PeerSocket, Remote and callback-property obligations were listed
(`/tmp/overalls-peer-silence-contracts.log`, exit 0). This is structural discovery;
semantic deadline evidence is the scoped execution recorded above.

After incoming integration, coverage generation/check, ADR structure/local links
(140 decisions) and contract syntax/coverage (2,519 native notes) passed again,
exit0 (`/tmp/overalls-peer-silence-combined-governance.log`). The combined local
runtime result is nine checks; full Marshall precommit/forced typing, evaluated
HLDD and native/hosted composition remain outstanding.

Marshall's full precommit subsequently passed 1,488 checks (252 properties,
1,236 tests), two exclusions, seed 755639, in 1,708.1 seconds; forced test
Dialyzer reported zero errors, skips or unnecessary skips and passed in 47.11
seconds (`/tmp/overalls-peer-silence-marshall-precommit.log`). The final HLDD
checker, options, views and coverage checks passed; the evaluated Nix `hldd`
check passed after staging the new review/property artifacts
(`/tmp/overalls-peer-silence-final-hldd-check.log`,
`/tmp/overalls-peer-silence-nix-hldd-staged.log`).
