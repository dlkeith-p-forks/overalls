# Ziggy durable SLO accounting

## Scope and architecture

ADR-0063 retains durable admission and prohibits provider replay. ADR-0132
requires durable accounting before promoting candidate objectives. The checkpoint
extends Ziggy's existing private spool authority; it introduces no database,
guest identity or provider effect. Fixed aggregates contain no request content.
Counted UUIDs remain private and bounded by retained spool capacity.

Terminal slot fsync precedes checkpoint replacement; aggregate persistence
precedes ACK unlink. Replay deduplicates terminal slots, preserves acknowledged
totals and treats unfinished admission as failure with unknown duration.
Checkpoint uncertainty fences admissions and acknowledgments and stops export.

## Findings and rollout

Legacy binaries reject checkpoint filenames. Deploy compatible readers with
`durableSloCounters=false` everywhere before enabling creation. Existing
checkpoints activate durable reading regardless of that flag. Once enabled,
rollback must use the compatible reader revision. The first durable lifetime
does not reconstruct already acknowledged historical requests.

Checkpoint replacement adds fsync work at admission, completion and ACK. Fleet
throughput, disk-loss and power-loss acceptance remain open. No source change
establishes a measured seven-day result or alert notification delivery.

## Verification

The focused suite passed 14 checks: four properties and ten tests. Generated
saturation/partial-ACK histories preserve totals and source lifetime across
restart. Malformed checkpoint properties refuse inconsistent arithmetic and
identities. Explicit tests cover terminal-slot/checkpoint lag, durable-unlink
lag, uncertain writes, private custody and reader-first enable/disable history.

Ziggy precommit passed 59 checks (12 properties, 47 tests), and Dialyzer reported
zero errors and zero skipped checks. The updated native fixture passed in
78.96 seconds, including both SIGKILL recovery cases and isolated Rust export.
The final source rerun passed in 77.79 seconds after recovery was changed to
skip checkpoint rewrites for receipts already present in the aggregate.
The prior producer-only native fixture passed in 71.81 seconds: packaged Ziggy
survived SIGKILL after ACKs and during a held stream, preserving totals and
counting one interruption without repeating the provider call. It uses synthetic
control authority and real local provider TLS, not Firecracker or power loss.

The first Marshall shared gate was stopped after assertions encountered retained
rows in the default test database (extra cleanup jobs, 21 fixture VMs and 22
completed history rows). Other BEAM processes were active in the VM. Its partial
run is not passing evidence. A fresh `MIX_TEST_PARTITION=otel_slos_20261002`
gate passed: 1,392 checks (200 properties, 1,192 tests), two excluded, with
forced Dialyzer reporting zero errors and skips. It exercised the durability
commit before the upstream UI/configuration-test merge. After that merge, the
focused reader/handbook suite passed 35 checks (13 properties, 22 tests), and
Ziggy precommit passed 61 checks (13 properties, 48 tests), including the upstream
invalid OTP boot property, with zero Dialyzer errors and skips. The merged Nix
HLDD gate passed. The merged `otel-marshall` native browser fixture passed in
76.67 seconds, including the Control room `/admin/slos` page, fixed source roster
and evaluated alert-state reads. No default database reset or unrelated
process termination was performed. The first all-files prek run reported two Python driver quote
formatting differences. The pinned formatter has applied those changes;
the original run was unsuccessful. The clean all-files rerun and commit hooks passed.

## Remaining work

The producer startup review found that an empty source had no persisted lifetime.
Startup now fsyncs an empty checkpoint before readiness; compatible reader
rollback retains it. Recovery folds retained terminal slots into one final
checkpoint before callers can observe readiness. Interrupted admissions retain
their individual terminal persistence. No provider effect occurs on recovery.
The corrected focused suite passed 15 checks (four properties, eleven tests).
Its first run exposed an uppercase generated UUID fixture and an obsolete
empty-directory assertion; both were corrected without weakening validation.
The updated native fixture passed in 83.27 seconds, including private mode-0600
checkpoint custody, identical empty lifetime after restart, and no provider call
before the first admission, as well as the existing SIGKILL recovery cases.
After merging main's canonical UUID and immutable-spool loader test repairs,
Ziggy precommit passed 63 checks (14 properties, 49 tests); forced Dialyzer
reported zero errors and zero skips.
The merged packaged native fixture passed in 90.66 seconds. The Nix conflict
marker and HLDD checks passed with explicit `C.UTF-8` locales, as did the
all-files prek gate, including format, annotation and type checks.
Marshall's isolated `MIX_TEST_PARTITION=otel_slos_20261002` full precommit passed
1,392 checks (200 properties, 1,192 tests), two excluded, and forced Dialyzer
reported zero errors and skips. This run covered the producer change before
merging main's independent Enrico startup validation commit `af84b088`.

Compatible readers were pushed to main and both hosts were verified healthy at
`8704fac596dde6e8824e501e9bb01f65d1951e9b`, with zero updater failures, ready
Ziggy services, `ZIGGY_DURABLE_SLO=0`, and neither checkpoint nor staging file
present. The production host configurations now enable creation after those
checks. Producer commit `4f2f71865a285c9399de4a6c285bac2a6380305c` was pushed
to main and both hosts were verified healthy at that exact revision with zero
updater failures, affirmative readiness and `ZIGGY_DURABLE_SLO=1`. Each private
checkpoint had mode 0600; bounded comparison verified agreement with the live
snapshot for lifetime, incarnation, outcome counters and duration aggregate.
No provider request was made for these deployment checks. Rollback must retain
the compatible reader revision or a newer one.
Other application durability and complete user journeys remain open under
ADR-0132; notification routing still has no destination.
