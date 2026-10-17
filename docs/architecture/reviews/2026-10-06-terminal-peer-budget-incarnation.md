# Terminal peer budget incarnation verification

## Scope and architecture impact

Source/research review resolved the historical missing-monitor question: incoming
PeerSocket and outgoing Remote both monitor the budget incarnation returned at
admission. The previous mass-owner-death property covers accounting reclamation,
but not live peer shutdown after the budget itself restarts. The new property
verifies existing ADR-0083/0142 requirements; durable authority, guest lifetime,
wire schemas and decision rationale/status are unchanged. Production code is
unchanged by this property addition.

## Executed property

`marshall/test/marshall/terminal/remote_test.exs` generates one to three real
verified-TLS peer pairs with persistent attachments. Production TerminalPeerAPI
checks the signed current-location proof. The host stream and attachment replies
are synthetic. Exact occupancy is twice the live remote count. The test kills
the exact budget, observes every admitted owner terminate, waits for its supervised
successor, checks zero occupancy and unchanged location/live synthetic stream,
and admits precisely the generated number of replacement pairs. Replacement
owners terminate before the next draw.

Focused execution passed four checks (one property, three tests), seed 0,
2.0 seconds, exit 0 in `/tmp/kittens-peer-budget-incarnation-attached.log`.
The initial listing fixture failed its live occupancy assertion because one-shot
control replies deliberately terminate Remote; persistent attachments corrected
the fixture. That initial result is not a production counterexample
(`/tmp/kittens-peer-budget-incarnation-first.log`).

## Mutation validation and limits

The first return-owner-PID mutant run ended at an unrelated stream_busy refusal:
shrinking reused the still-live initial attachment after a partially executed
destructive budget restart. No falsification is credited to that run
(`/tmp/kittens-peer-budget-return-owner-mutant.log`). Shrinking is now disabled
for this destructive generated history; a fresh matching baseline and re-sweep
are in progress. Full Marshall precommit and forced typing remain pending.

Matching no-shrink fork baseline passed four checks (one property, three tests), seed 0, 2.1 seconds, exit 0.
Log `/tmp/kittens-peer-budget-incarnation-fork-baseline2.log`. The realistic
mutant returns the admitted caller PID instead of the budget PID on fresh
admission, causing both peer sides to monitor themselves. It failed the predicted
missing old-owner DOWN after budget death: generated two pairs, zero successful
draws, seed 0, 3.4 seconds, exit 2. Log
`/tmp/kittens-peer-budget-return-owner-mutant2.log`. Later replacement-admission
checks are not mutation-credited. Source restored and byte-compared; restored
execution passed four checks, seed 0, 2.1 seconds, exit 0, in
`/tmp/kittens-peer-budget-incarnation-restored.log`.

The property does not establish native guest survival, physical channel custody,
cross-node partitions or hosted Antithesis acceptance. These remain separate gaps.
