# Lilly native runtime readiness histories

## Scope and architecture impact

Base `764ee09b`; source-built nine-machine fleet with six nested Firecracker
guests across two Lilly provisioners. New exported check
`lilly-runtime-readiness` preserves ADR-0017 durable authority and guest lifetime
and ADR-0036's strict private deployment readiness (carried forward through
ADR-0038). No production behavior, protocol, capacity, domain or deployed host
placement changes; decision and implementation statuses remain unchanged.

## Oracle and review

Fixed asymmetric histories `(1,2)` and `(2,1)` and generated first/repeated main
process kills run while fixture PostgreSQL is stopped. Every incarnation must
return a complete valid negative readiness reply before a five-second polling
watch. A missing or refused socket cannot satisfy that complete-reply assertion;
it counts as false only during the bounded watch. This distinction fixes a fresh
review finding: otherwise a daemon stuck before initialization could pass.
StatusServer follows Runtime under rest_for_one, so a functioning listener also
establishes Runtime initialization and journal opening. The probe validates the
fixed public readiness schema, bounds frames and transport work, and exposes no
runtime identifiers or private payloads.

Recovery requires authenticated connection epoch advance on both hosts, fresh
reports, positive readiness and exact unchanged Firecracker PID/kernel-start/
executable snapshots. The fixture uses existing ordinary admission and real
source-built packages. No fake Runtime response establishes native readiness.
Ancestor contracts preserve isolated inputs, real package scope and precise
verification claims; the local negative-watch contract prevents absence from
replacing the complete incarnation witness. Fresh review found no additional
concrete blocker after that repair; it ran no checks.

## Verification and gaps

Isolated Ruff formatting/lint and probe ty checks passed. The all-file pinned
static run passed Ruff, ty and each application logging gate; HLDD rejected
unrefreshed receipts and generated scenario coverage, as expected before their
review. After chapter and scenario review, the repeated all-file pinned gate passed,
including HLDD, Ruff, ty and logging. ADR structure, generated options/coverage/
views and contract structure/discovery also passed. The contract gate covered
117 CONTRACTS files, 2329 native notes, 182 parsed files and 2485 maintained
source files; this remains structural evidence. The source-built native `lilly-runtime-readiness` check passed in **1786 seconds
overall**, archive `1791006040414-2019544-0.jsonl`; its machine script passed in
**897.72 seconds**, including **248.40 seconds** for the generated/fixed readiness
histories. The six-guest setup passed in **450.94 seconds**. The composed driver
Ruff/ty gate passed before native execution. Log:
`/tmp/kittens-lilly-runtime-readiness-native.log`.
No hosted Antithesis result is claimed.

The watch samples at 100-millisecond intervals and does not establish every
continuous-time transition or an exact fifteen-second delivered-report boundary.
Direct Runtime properties retain their separate boundary scope. Individual
terminal/audit/actor gate faults, updater generation promotion, physical hosts
and hosted Antithesis search remain separate acceptance work.


Final all-file pinned Ruff/ty/logging, ADR and reviewed HLDD/options/coverage/views
passed after recording native evidence. Evaluated Nix HLDD passed in **14 seconds**,
archive `1791008051071-3256094-0.jsonl`. Fresh final read-only review independently
confirmed the archive's composed checks and native durations and found no
concrete blocker or overclaim. No further native execution was performed by the
reviewer. Architecture impact remains verification under the existing decisions;
no production behavior, authority, protocol, domain or deployed topology changes.


The final integration retains all 83 unique scenario IDs from both source branches.
All-file pinned Ruff/ty/logging and ADR/HLDD/options/coverage/views passed on the
combined main tree. Evaluated Nix HLDD passed in **18 seconds**, archive
`1791008240246-3386194-0.jsonl`; log
`/tmp/kittens-lilly-readiness-primary-integration.log`. The integration changes
no Lilly/Marshall production code or native scenario code from the passing run.
Research provenance names the canonical local worktree and its inspected base
`764ee09b`; physical/updater/hosted and individual gate-fault gaps remain open.
