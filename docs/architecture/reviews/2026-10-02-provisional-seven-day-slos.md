# Provisional seven-day fleet objective review

Date: 2026-10-02. Decision: [ADR-0132](../decisions/0132-seven-day-provisional-fleet-objectives.md)
supersedes [ADR-0129](../decisions/0129-fleet-otel-slos.md).

## Scope and authority

This review covers the Nix-owned twelve-path roster, seven-day Prometheus
recordings and burn expressions, private Grafana panels, and Marshall's
signed-in projection. It preserves Audi's guest diagnostic boundary and
Marshall's existing current-login hook. Prometheus remains observational;
none of these recordings authorizes a VM transition or resource release.

The user directed seven-day targets and burn alerts. The preceding 28-day
wait is retained as historical rationale in ADR-0129 and replaced by
ADR-0132's provisional target decision. No contact route was supplied or
configured, so Prometheus warning states do not page an operator.

## Findings

1. **Candidate boundary, high:** Brady, Galileo, Enrico, Porsche, Ziggy,
   Audi private/DNS/SSH and Marshall Web retain their narrow named completion
   boundaries. Several source snapshots can lose unexported outcomes on
   restart. The seven-day rule withholds those windows until current source
   start time predates the full window, but this cannot reconstruct earlier
   lost outcomes or prove end-to-end journeys. Do not promote candidates to
   final SLOs before durable source accounting and native journey tests.
2. **Underclass boundary, high:** The host-owned Rust monitor probe tests
   local socket readiness on both hosts. It does not see authorized proxy
   completion, provider health or stream completion. Its 99% provisional
   target is explicitly monitor readiness only.
3. **Missing data, medium:** All 20,160 expected 30-second samples are
   required from both collectors and every enrolled application source.
   A source restart or unavailable collector withholds the result. Prometheus
   retention is bounded by 10 GB as well as 35 days, so disk pressure can
   keep a seven-day window unknown. Neither silence nor sparse traffic earns
   a zero-error result.
4. **Alert delivery, medium:** Fast and slow error-budget expressions have
   minimum-volume and eligible-history gates. They are provisioned as
   provisional Prometheus warning states. There is no independent alert
   evaluator or configured notification receiver; an Overalls outage can
   prevent their evaluation entirely.
5. **Read authority, low:** The UI's Nix catalog must match Marshall's fixed
   ID, recording, objective and target roster. The reader discards arbitrary
   Prometheus labels, duplicate rows and malformed values. The existing
   current-login hook fences a revoked mounted reader; operator Grafana stays
   on loopback.

## Verification and open work

The focused Marshall SLO suite passed 10 tests, including four generated
properties. The initial full-window Promtool fixture hit its test-harness
sample cap; the final fixture uses a two-minute synthetic scrape cadence with
the same seven-day window and a scaled 5,040-sample threshold. The production
rule retains 20,160 samples at the 30-second cadence. The Promtool seven-day
fixture passed both complete two-host observations and a known-down collector;
the ordinary rule fixture passed missing-history and retained-source refusals.
Seven-day recordings evaluate every five minutes and burn rules every minute.

The two-node `otel-fleet` NixOS check passed in 558 seconds. It asserted 33
provisioned Grafana panels, their guarded objective expressions, collector
outage/recovery and trace-queue replay. The packaged `otel-marshall` check
passed in 79 seconds with ordinary signed-in objective cards, anonymous and
revoked refusal, and missing seven-day data shown as unknown. Both use
disposable peers, not production credentials or a seven-day running machine.

After rebasing onto ADR-0131's automatic remembered sign-in, the first
packaged browser rerun found that revoking only the active login let the
ordinary reader resume through its remembered credential. The fixture now
revokes exactly one active login and one remembered credential for its
isolated identity. The rebased two-node check passed in 58 seconds, including
active and copied browser refusal; no production identity was changed.

The Marshall full `mix precommit` run entered its distributed suite but
encountered failures in unrelated admission and queue tests against a shared
database with retained fixture rows and connection exhaustion. It was stopped
after those failures; the focused SLO suite, contract checker, ADR checker and
Nix HLDD gate passed separately. At review time production has less than seven
days of collection and cannot demonstrate objective compliance. Deployment
revision and live observations remain to be recorded.

## Production rollout

Commit `cef0d0a6` reached `origin/main` on 2026-10-02. Dungarees and
Overalls each reported `phase=healthy`, `failures=0` and that exact
`lastHealthy.revision`. Overalls first encountered a Nix temporary build
directory error while starting the Marshall derivation; its automatic retry
completed and left no updater failure. The active Overalls Grafana provisioned
dashboard file contains 33 panels. Its Prometheus API listed 12 provisional
seven-day recording rules and 24 burn alerts. After its first five-minute
evaluation, every recording rule reported `health=ok`; the burn rules were
healthy and inactive. An instant query returned no seven-day objective values,
as expected before seven days of eligible history. No signed-in production
browser session was used and no seven-day compliance claim is supported by
this rollout.

## Seven-day burn arithmetic and reader correction

The initial alert configuration copied 14.4 and 6 multipliers from a
thirty-day budget. For the same consumed-budget fractions, the seven-day
thresholds are `0.02 * 168 / 1 = 3.36` and `0.05 * 168 / 6 = 1.4`.
The Nix expression now derives both from the objective horizon. Six Promtool
fixtures passed: fast plus slow firing at 4% errors, slow-only firing at 2%,
no firing at 0.5%, recovery, sparse traffic and expired eligible history.
These are alert arithmetic fixtures with an injected eligible recording;
the separate seven-day fixture verifies recording eligibility.

Marshall's prior below-target prose incorrectly implied a warning after five
minutes based only on the long-window ratio. It now projects the actual fast
and slow states from the fixed local rule API. The reader validates exactly
24 reviewed alert names and label maps, healthy rule evaluation and per-rule
timestamps no older than 90 seconds or more than 30 seconds in the future.
Unknown objective history suppresses an otherwise inactive evaluator state.
Generated tests cover rule permutations, corruption and both clock boundaries.
The focused SLO suite passed 15 tests, including seven generated properties.
A read-only response from live Overalls also parsed as twelve complete sources
with inactive fast and slow states. This verifies the live API schema against
the compiled reader; it does not establish a signed-in production browser read.

Architecture impact remains within ADR-0132's observational signed-in boundary.
This introduces no mutation, new credential, domain resource or placement.
Missing or failed evaluation produces unknown; the local Prometheus remains
the same failure boundary. Candidate accounting, complete journeys and alert
notification routing remain open. The extended `otel-marshall` NixOS check
passed; its VM script finished in 90.79 seconds. The packaged reader accepted
all 24 real, healthy inactive rules, and Chromium verified unknown burn states
without eligible seven-day history, ordinary-reader admission, anonymous
refusal and active/remembered credential revocation. This does not establish
native firing alerts or production signed-in rendering.

The full Marshall suite recorded 1,382 passing checks (200 properties and
1,182 tests), ten invalid job-history distributed cases after peer startup
failed, and two excluded cases. A separate database rerun without application
recompilation passed all ten distributed cases in 9.1 seconds. This retry
does not turn the initial suite into an uninterrupted passing run. The final
selector-based SLO UI suite passed all four tests. Terminal and dashboard
static checks passed. Forced Dialyzer passed with zero errors and no skipped
or unnecessary warnings. The original `mix precommit` exited 2 because of
the ten invalid cases; the successful isolated retry is separate evidence.

Contract review traced the fixed rule parser, its snapshot projection and
the signed-in LiveView consumer, plus the packaged seed and generated tests.
No violation was found in that scope: malformed evaluator data remains
unknown, returned text cannot enter the UI, and the reader grants no mutation
authority. Complete journeys and durable source accounting remain obligations.

## Correction deployment

Commit `c9fffb4c6a344ef63ee5a3acc2948f6a2351d638` reached `origin/main`.
On 2026-10-02 both Overalls and Dungarees reported `phase=healthy`, zero
failures and that exact `lastHealthy.revision`. A live rule response had all
24 burn rules healthy with the corrected 3.36/1.4 expressions; the compiled
Marshall reader accepted twelve complete burn readings. The twelve
five-minute recording rules initially awaited their first evaluation after
restart. Signed-in production rendering, seven-day measured compliance and
notification delivery remain unverified.
