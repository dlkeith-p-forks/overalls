# Integrated property gate stability

## Scope and architecture impact

Test-only fixture freshness and bounded whole-history execution budgets preserve
ADR-0006 capacity, ADR-0037 relocation and ADR-0009 verification requirements.
No production behavior, protocol, host placement, clock authority or capacity
threshold changes. Ordinary Start continues to require both fresh host and pool
reports, measured physical headroom, retained disk and current authority. Decision
and implementation statuses remain unchanged; no new ADR is required.

## Integrated findings

The primary main gate at `690b6e87`, seed `630207`, completed in 1859.6 seconds:
1425 of 1428 checks passed (226/227 properties, 1199/1201 tests), two exclusions.
The retry proof-window property reached its 300-second whole-history budget while
waiting on admission SQL. Two relocation cleanup histories expected positive
Start but received `insufficient_capacity`. Forced Dialyzer passed in 42.92
seconds with zero errors/skips. Log:
`/tmp/kittens-enrico-terminald-final-main-gates.log`.

Inspection of RestartCapacity confirms that stale pool telemetry also rejects
Start with insufficient capacity. Long successful cleanup histories supplied
neither continuing host nor pool reports before their positive restart witness.
The fixture now refreshes existing report timestamps before Start only, retaining
all capacity values, inventory, holds, placement and epoch assertions. This is a
synthetic healthy-inventory precondition, not acceptance of stale production
telemetry or an authenticated host report journey. A local contract and typed
helper interface make the assumption explicit.

The four complete fifteen-window retry menus retain every admission/deadline
refusal and repeated-scan accounting witness. Their whole database-history budget
is bounded at 900 seconds. This admits slow execution; it is not a performance
claim or an extension of any product deadline.

## Recorded verification and remaining work

The preliminary six selected relocation checks using host-only refresh passed
in 37.1 seconds, seed `630207`. The final host-and-pool fixture plus retry budget
passed ten checks (four properties and six examples) in 132.4 seconds, same seed;
29 unrelated cases were excluded. Logs:
`/tmp/kittens-relocation-healthy-fixture-focused.log` and
`/tmp/kittens-marshall-gate-failures-repaired-focused.log`. The helper's explicit
return and typespec/contract were added afterward without changing assertions;
the final integrated compiler/type/test gates below cover that revision.

Fresh independent read-only review found no production defect hidden by fixture
refresh and requested the now-added helper contract. It performed no execution.
The frozen integrated source `764ee09b` passed the full pinned gate: all-file
Ruff/ty/logging and reviewed HLDD, ADR structure, generated options/coverage/views,
evaluated Nix HLDD and Marshall precommit. Marshall passed **1428 checks
(227 properties, 1201 tests), two excluded**, seed `728068`, in **1631.1 seconds**.
Its 28 browser-state checks passed. Forced Dialyzer passed in **49.04 seconds**
with zero errors, skips or unnecessary skips. Log:
`/tmp/kittens-audi-terminald-stability-final-main-gates.log`.
The evaluated HLDD archive is `1791003686509-680552-0.jsonl` (14 seconds).

This records passing integration of the typed host/pool fixture and complete
retry menus, along with the Audi and terminald repairs. Native relocation,
independent physical-host availability and hosted Antithesis acceptance remain
separate from this ordinary full-suite result. Subsequent upstream integration
must preserve these scopes and run the affected component/governance gates.


## Upstream integration

The subsequent merge includes origin `c295ae4a`: Galileo's verified403 guest
refusal repair and scoped production cache/telemetry evidence. The merged ledger
retains all **82 unique scenario IDs** from both branches. The sole conflict was
the review receipt manifest; affected source groups and chapters were reviewed
again and receipts regenerated. No Marshall production code or tests changed.

The merged candidate passed all-file Ruff/ty/logging, ADR and reviewed HLDD,
generated options/coverage/views, and evaluated Nix HLDD in **17 seconds**,
archive `1791005753366-1878007-0.jsonl`. Galileo precommit passed **31 checks
(12 properties, 19 tests)**, seed `350026`, in **109.6 seconds**. Forced Dialyzer
passed in **5.07 seconds** with zero errors, skips or unnecessary skips. Log:
`/tmp/kittens-antithesis-origin-integration-gates.log`.

Architecture boundaries and decision statuses remain unchanged. Incoming
ADR0080/0134 refusal semantics, ADR0135 cache acceptance and ADR0136 request
accounting evidence preserve their stated physical, fault and hosted gaps.
The full Marshall result above remains evidence for its unchanged code/test
revision; it is not a new execution of every native or hosted scenario.


The next incoming commit `7fda1272` expands Enrico's actual native accounting
history. Its merged source passed all-file Ruff/ty/logging, ADR and reviewed
HLDD/options/coverage/views. The source-built `enrico-service` rerun passed in
**82 seconds**, with **50.25 seconds** of machine script, archive
`1791007896750-3146391-0.jsonl`. Recorder SIGKILL retains completed history with
the producer alive; producer SIGKILL settles a blocked admitted refresh once
without inventing duration or replacing the published mirror. Evaluated HLDD
passed in **17 seconds**, archive `1791007979037-3146026-0.jsonl`. Log:
`/tmp/kittens-antithesis-enrico-origin-native-hldd.log`. Production Enrico,
Marshall and Galileo source did not change in this second merge; the native
check verifies composition with the earlier local Enrico repair.


The next incoming commit `f3118c92` adds native DNS accounting histories.
The fixture merge preserves both explicit 426 expiry/operator recovery and
recorder/producer continuity assertions. The combined source-built `audi-dns`
check passed in **101 seconds**, including **77.39 seconds** of machine script,
archive `1791008502526-3552358-0.jsonl`. Evaluated HLDD passed in **19 seconds**,
archive `1791008603832-3526660-0.jsonl`; all-file Ruff/ty/logging and reviewed
ADR/HLDD/options/coverage/views passed. Log:
`/tmp/kittens-antithesis-dns-origin-integration.log`. Source-built native DNS
fault scope remains distinct from real Marshall/Firecracker publication,
in-flight producer loss, overload/storage faults and physical acceptance.
