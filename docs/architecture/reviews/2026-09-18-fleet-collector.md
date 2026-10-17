# Detailed fleet collector foundation

## Scope and architecture impact

[ADR-0060](../decisions/0060-detailed-fleet-monitoring.md) adds independent detailed
observations without changing ADR-0023 capacity-report history or the current
admission transaction. This review covers host measurement parsing, independent
runtime, retry spool, opt-in NixOS service and Lilly unit-description metadata.
The launched placement/epoch/generation description is diagnostic evidence only;
ADR-0017's execution guards and physical outcome authority are unchanged.

## Findings and evidence

The measurement library (`nix/domains/system/fleet-monitor/metrics.py` at overalls revision `a99f74f0`, repository deleted) separates
host/CPU/device/interface/workload/ZFS records, omits unavailable values and uses
context-bound counter deltas. CPU guest time is removed from user/nice before
displaying a breakdown. ZFS GUIDs retain the full unsigned 64-bit identity range;
they are strings, not floating-point metrics. Dataset recursion and physical pool
use remain separate. Unlimited cgroup and dataset limits are explicit.

The runtime (`nix/domains/system/fleet-monitor/runtime.py` at overalls revision `a99f74f0`, repository deleted) bounds subprocess
output/time and checks systemd invocation metadata before and after cgroup
collection. VM namespace TAP names derive from physical placement, not guest input.
Only selected unit properties are read; guest processes and terminal contents are
not collected. The spool uses atomic fsynced files, separate export and collection
threads, bounded replay batches and acknowledgments restricted to the sent batch.
Its time/count/byte caps report drops rather than promising lossless outages.

Remaining implementation/verification obligations:

- The ingestion endpoint, credential provisioning/revocation, live caches, durable
  batch acknowledgments, history/retention, UI and scale benchmark are not yet
  implemented. The module is opt-in and must not be enabled before that endpoint
  and its credentials are deployed.
- TLS delivery/ack fault cases and native cgroup, ZFS and namespace tests remain.
  Unit fixtures cannot establish actual launched VM or migration attribution.
- Old running VM units lack the new versioned description. Their attribution
  remains unknown until a normal launch produces it; no forced restart is added.
- Host identity is shared with Lilly for deduplication, not hardware attestation.
- The privileged collector needs network namespace and ZFS read access. Its fixed
  executable/argv paths, source allowlists and service resource limits preserve
  separation from guest lifecycle but still require native containment checks.

## Verification performed

- Ten isolated Python tests passed: unknown/zero, guest-time accounting, boot/gap/
  reset/incarnation changes, disk/interface classification, cgroup identity,
  ZFS accounting, bounded reads, metadata parsing, spool restart/partial ACK/
  expiry/overflow/count limits, and subprocess output/time bounds.
- Pinned Nix `fleet-monitor` and `fleet-monitor-configuration` builds passed.
  Configuration checks cover disabled behavior, all three Marshall unit names,
  secret dependencies and collector resource limits.
- A read-only Linux probe collected one host, 33 CPU records, 14 disk records and
  three interfaces in 0.0022 seconds. Four unavailable sources remained explicit.
  This is local procfs evidence, not the 100-host benchmark or native ZFS acceptance.
- Lilly's full precommit passed: 273 checks including launched-revision metadata,
  and Dialyzer with zero errors. Marshall's consumer gate subsequently passed
  562 checks and Dialyzer (one existing suppression).

The next ingestion foundation adds the Fleet Ash domain, separate physical-host
rows, dedicated monitor credentials with secret-free audit, and a strict sample
validator. Seven focused tests passed. A real 51-record local collector envelope
also passed the Elixir validator. These changes require a new full gate; they do
not yet provide the HTTP endpoint or durable batched storage. Monitor secrets use
high-entropy SHA-256 digests rather than recoverable ciphertext, as now recorded
in ADR-0060. Rotation/revocation touch only monitor resources. Persistence must
revalidate queued credential IDs under the same monitor-host lock.

## Contracts and follow-up

Reviewed root, Nix/module/test, Lilly and relevant source contracts. New notes
require independent budgets, safe metadata, identity-aware rates and durable ACK
semantics. Unit descriptions preserve existing native guard argv and cgroup
ownership. Final component gates and the remaining
[acceptance ledger](../../history/ledgers/admin-implementation.md) remain required.
