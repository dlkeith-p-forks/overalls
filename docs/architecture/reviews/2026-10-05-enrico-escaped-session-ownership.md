# Enrico escaped-session ownership

## Finding and architecture impact

Reviewed ADR-0097, native ownership contracts, the source-built helper and its
generated histories on b5c9c133 plus this owned draft. The accepted requirement
is unchanged: unresolved descendant cleanup retains refusal and must not confirm
quiescence. Stable locks and the eight-command bound remain authoritative.

The new `escaped_session_retains_authority_until_actual_death` property creates
an actual descendant in a separate session using pinned setsid/Bash. Independent
`/proc` process-group/session witnesses establish escape. Fixed caller EOF,
deadline and direct completion histories each hold seven neighbor owners before
two generated trigger/neighbor draws. It requires unresolved exit126, inherited
lock refusal, full-capacity read refusal, unchanged neighbor PIDs, and exact
successor admission after guarded explicit escaped-child death. This is local
kernel evidence, not packaged cgroup or authenticated remote acceptance.

## Counterexample and repair

Diagnostic package3 failed with ten existing properties passing and the new
property failing after199.39seconds, archive `1791218339186-1008007-0.jsonl`.
The actual fixed deadline case had seven neighbors, a live escaped child and
one admission plus one repository lock descriptor, but exit124 rather than126.
Failed patch SHA256
`159bf37e97ab3caf8360275ea40b71b09343fd78a9e683ef55a14e4d0fc00e0f`,
`/tmp/kittens-enrico-escaped-owner-package3-failed.patch`.

Rustix1.1.5 documents `waitpid(None, ...)` as waiting only for children in the
caller's process group. The cleanup loop therefore missed the adopted escaped
child and treated ECHILD as confirmation. `terminate` now uses `wait(...)`,
which selects every child. The existing two-second unresolved-cleanup deadline,
private-group kill, direct-child reap and descendant-held locks are preserved.
The contract explicitly includes every adopted process group/session.
This is a medium-severity violation of cleanup confirmation under ADR-0097:
the observed inherited locks preserved writer refusal, but the helper selected
the original timeout outcome despite unresolved descendants. The repair restores
the required distinct unresolved-cleanup outcome.

Earlier runs remain failures: package1 reported Hegel nondeterminism in the new
and an existing property; complete positive PID publication was subsequently
made bounded and explicit. Package2 passed ten old properties but failed the
new exit assertion without identifying its fixed inner case. Neither failure
establishes Clippy success or a passing escaped-session baseline.

## Recorded verification and remaining gates

Package4 passed all eleven native properties in27.28seconds; the full package
passed exit0 in67seconds, archive `1791218630397-1348451-0.jsonl`, log
`/tmp/kittens-enrico-escaped-owner-package4.log`. The package runs rustfmt and
all-target Clippy with locked offline dependencies and warnings as errors.
Cargo formatting and diff checks also passed before submission. Integrated
component gates, reviewed HLDD receipts and
main integration remain pending. ADR-0097 remains accepted and partial.

The targeted reversion mutant was falsified locally: archive
`1791218779158-1446781-0.jsonl`, package exit1,223seconds; the selected property
failed191.18seconds. Deadline/seven-neighbor counterexample again observed the
escaped child alive with both locks and exit124 instead of126. The fixed and
generated histories were unchanged. See the
local mutation ledger (`antithesis/scratchbook/mutation-testing/local-enrico-escaped-session.md` at kittens revision `9fe1e493`, repository deleted).
Pinned code-contract syntax and discovery passed for the source and history
declarations; semantic review preserves all-child reaping, inherited authority,
bounded cleanup and independent process witnesses. This is self-review; no fresh
independent review is claimed.

The historical ten-property package, full fourteen-check Enrico gate and isolated
authenticated HTTPS normal/source-outage service evidence are preserved in the
[earlier review](2026-10-03-enrico-refresh-admission.md). They do not prove this
new repair's packaged service composition. Saturated cgroup restart, physical
quota, durable Marshall retry and hosted exploration remain open.

Source review additionally found the same process-group-only wait API in
Lilly's source-export and transfer-stream cleanup loops. Their all-adopted-child
contracts need separate generated regressions and source-backed reconciliation;
no repair or passing evidence for those helpers is claimed here.

## Main integration

Saved the complete owned draft in retained stash
`antithesis-enrico-escaped-session-before-main-c96-2026-10-05`, then fast-forwarded
main c96f21255449981eb587fce0dcffeecf553f007e. Restoring the draft conflicted
only in the ADR and review indexes; both upstream recorder and owned Enrico
entries were preserved. Enrico/protocol/Lilly production source and the helper
package had no upstream differences, preserving native verification scope.
Final integrated handbook receipts and component gates remain required.

## Integrated component verification

Full Enrico precommit passed exit0: fourteen checks (eleven properties, three
tests), seed344695,in303.0seconds. Forced Dialyzer passed4.54seconds with zero
errors, skips or unnecessary skips. Runtime, compiler, formatting, contracts,
logging, ADR and HLDD receipt gates passed. The test PATH selected the verified
source-built repaired helper package. Log:
`/tmp/kittens-enrico-escaped-owner-precommit.log`.
Integrated ADR, scenario generation, views, options and reviewed receipts passed
before this gate. Final all-file hooks and evaluated HLDD remain required before
commit; no new production activation or service-cgroup acceptance is claimed.

Final all-file hooks passed, including Ruff format/lint, ty, contracts, logging
and reviewed HLDD. Evaluated Nix HLDD passed exit0 in20seconds, archive
`1791219825308-2352676-0.jsonl`, log
`/tmp/kittens-enrico-escaped-owner-publish-checks3.log`. Earlier publication
attempts refused an updated receipt without corresponding chapter changes, then
stale shared Lilly/deployment chapter digests; the actual service/scenario facts
were reviewed and reconciled before this passing run. No gate was bypassed.
These structural/static results do not expand the native scope above.
