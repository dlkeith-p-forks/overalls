# Producer worker completion histories

## Architecture impact

Baseline `bf231090049603c801f64cd0aa317a43cb85bde0`. This repairs implementation
of ADR-0136's monitored worker and completion ownership requirement. The client
now matches a death tuple to its stored worker and verifies that the local BEAM
process has died before settling the ticket. Numeric recorder schemas, persistent
markers and existing application authorization remain unchanged. No new domain,
resource, dependency or deployment role is introduced.

Reviewed the client, marker and RPC contracts and nineteen source references
across Marshall, Audi, Brady, Galileo, Enrico and Porsche. Existing callers either
finish in the admitting process or use the admitted local worker. The repair
preserves both issuer and worker completion and existing unrecorded behavior.

The captured revision used `slo_client/` and `OverallsSLOClient.Client`; the
current source is the breaking `elixir/request_accounting/` library and its
`Overalls.RequestAccounting.Producer` API. Historical seeds, logs and scope are
unchanged.

## Failure and regression oracle

Original code popped a pending ticket on a death tuple without checking its
worker. An isolated real client/marker/RPC reproduction recorded a failure while
the actual worker remained alive, then ignored authorized success. The new
live-worker property rejects foreign completion, a different worker's death tuple
and the live actual worker's death tuple before authorized issuer/worker settlement.
It checks exact pending custody and one recorded completion, then repeated
completion and eventual real worker death cannot add another terminal outcome.

A second property confirms actual worker death settles once before repeated issuer
completion. A third races issuer completion against actual worker death: either
success or failure may win, but exactly one terminal RPC remains, successful
reported duration is exact and duplicates preserve the winner without a gap.
The tests use real client processes, marker files and bounded Unix RPC, with a
controlled acknowledgment peer. Each acquired fixture resource has cleanup before
acquiring the next; server and worker death are bounded and monitor-confirmed.

The original-source control failed the live-worker property at seed `751543`,
exit 2; two other properties passed. The repaired isolated source passed all
three properties at the same seed in 0.6 seconds, exit 0.
Logs: `/tmp/overalls-slo-client-history-race-original.log` and
`/tmp/overalls-slo-client-history-race-repaired.log`.

## Project verification

The adopted project compiled with warnings treated as errors and passed nine
checks (six properties and three tests), seed `751543`, in 1.3 seconds, exit 0.
Toolchain check verified Elixir 1.20.4 and OTP 29.0.6. This used the existing pinned
development profile in an isolated worktree while the primary Marshall gate ran.
Log: `/tmp/overalls-client-history-project-tests.log`.
Component `mix precommit` subsequently passed, exit 0: nine checks (six properties
and three tests), seed `429277`, in 1.0 seconds. Forced Dialyzer passed in 3.44
seconds with zero errors, skips or unnecessary skips. Log:
`/tmp/overalls-client-history-component-precommit.log`. ADR structure, reviewed HLDD
receipts, generated coverage/options and Ash/deployment views passed. Nix `hldd`
passed, exit 0, in 28 seconds (archive `1790994701042-2550504-0.jsonl`).
Integrated consumer checks remain pending.

## Remaining gaps

A controlled acknowledgment peer does not establish authenticated Rust producer
identity, durable checkpoint custody, native systemd death recovery or every
application hook's complete user journey. Existing native recorder evidence
retains its original scope and revision. The new histories do not constitute
hosted Antithesis execution or seven days of production coverage.
