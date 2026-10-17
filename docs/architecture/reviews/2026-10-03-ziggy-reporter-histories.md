# Ziggy reporter receipt histories

## Architecture impact

Baseline `b49db79e53a0fac29aa99280b7be96409d029f47`. This verification
change preserves ADR-0100's provider and accounting authority and ADR-0132's
durable terminal inference measurement boundary. No production behavior,
protocol, persistence format, dependency or deployment change is introduced.

## Property and contracts

The [reporter history property](../../../ziggy/test/reporter_history_test.exs)
uses the real Reporter and durable Spool with a controlled request callback.
Each generated draw executes fixed receipt counts 2/127/128/129 and the first,
middle and last selected conflict positions. Generated refusal orders and
repetition counts 1/2/4 exercise transient failures, wrong acknowledgements
naming another queued receipt and the actual completion-conflict classifier.

Distinct protocol-valid completions carry known and unknown duration/usage.
Every refusal phase preserves exact receipt bytes, complete pending entries
and lifetime outcome/duration totals. Each reporting pass checks the complete
per-ID attempt delta against the independent 128-entry bound. Healthy neighbors
drain in precisely checked batches while one conflict remains; spool restart
retains that exact receipt and totals. Explicit final acknowledgement preserves
totals while freeing the last slot.

The first callback blocks outside the controller until the actual suspend
system message is observed in the Reporter's mailbox. The current batch finishes
before suspension, so an automatic timer cannot mask a reduced batch-size bug.
Task cleanup precedes Reporter cleanup. Repository and Ziggy contracts preserve
unknown usage, immutable accounting, content-free diagnostics and scoped claims.

## Verification

The focused property passed seed `203368` in 7.6 seconds, warnings-as-errors,
terminal exit0. Log: `/tmp/kittens-ziggy-reporter-history-focused.log`.
The initial run exposed an uppercase hexadecimal UUID fixture after the small
cases; correcting the generator and validating every ID preserves the oracle.
Full Ziggy precommit passed 64 checks (15 properties, 49 tests), seed 521050, in 61.7
seconds. Forced Dialyzer passed in 5.33 seconds with zero errors, skips or unnecessary
skips; terminal exit0.
Log: `/tmp/kittens-ziggy-reporter-history-full-gates.log`. Fresh source review
found no concrete blocker. Publication verification passed the all-file static,
ADR, local HLDD and generated-reference checks and the evaluated Nix HLDD gate.
Marshall's test phase passed 1,423 checks (222 properties, 1,201 tests), with two
exclusions, seed `119138`, in 1,531.1 seconds. Forced Dialyzer passed in 51.6
seconds with zero errors, skips or unnecessary skips; the complete publication
command exited 0.
Log: `/tmp/kittens-ziggy-reporter-publication-gates.log`.

## Remaining gaps

This checks controlled initial reporting batches and local durable files.
Automatic timer cadence, reporter conflict event visibility, actual HTTP,
Marshall commits and lost replies, native disk faults and hosted fault search
remain open. One persistent conflict does not establish fairness when a complete
128-entry batch consists of permanent conflicts. No provider request is replayed
or exercised by this property.
