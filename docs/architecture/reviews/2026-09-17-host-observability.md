# Host observability implementation review

## Scope and decisions

This review covers ADR-0042, which supersedes ADR-0009's blanket diagnostic
prohibition with narrowly restricted full audit arguments and encrypted crash
dumps. ADR-0009's other assurance obligations remain unchanged. ADR-0032 secret
custody, ADR-0033 real-machine verification and ADR-0037 placement authority remain
applicable. Existing relocation, SMTP and fleet-user work was preserved.

The architecture adds per-host Fluent Bit with optional direct destinations and
separate CloudWatch resource management. Applications do not depend on AWS or the
collector. Firecracker logs use generation-specific native FIFOs; neither logging
service owns a VM process, console or stop decision. Crash dumps require an
explicit operator public key and an encryption-enabled build of the same runtime.
The updater checks this capability before stopping consumers.

## Findings and resolutions

- High, resolved: ordinary AWS environment switches do not disable Fluent Bit's
  EC2 fallback. The pinned package now selects exactly the declared provider;
  managed EC2 access requires IMDSv2. Runtime credential files reject symlinks,
  hard links, unsafe ancestry and broad permissions.
- High, resolved: journal checkpoints previously preceded the final append. The
  package checks append results and saves cursors after successful handoff. Input
  processors and persisted conditional routes avoid a memory-only log retagging
  stage before durable storage.
- High, resolved: backlog discovery used tag matching
  before loading persisted conditional routes. After SIGKILL, queued records
  were invisible to output queues. Backlog discovery now shares the core
  output-identity resolver; the three-host crash test covers this regression.
- High, resolved: the pinned CloudWatch plugin did not advertise TLS support
  or propagate hostname checks to its separate TLS contexts. The package now
  does both; managed destinations enforce certificate and hostname verification.
- High, resolved: CloudWatch can reject events inside an HTTP-200 response.
  Future events retry; permanent expiration increments the output drop counter.
  Fixtures cover both cases and check that provider bodies are not logged.
- High, resolved: logger default OTP translation can render state, arguments and
  queued terminal/mail data. Both applications install a fixed-category translator
  before the default translator. Existing more-specific diagnostic filters remain.
- Medium, resolved: case-insensitive plugin options could bypass case-sensitive
  Nix guards. Managed routing, identity, storage and TLS keys are now checked after
  case normalization, including secret option keys.
- Medium, resolved: native log retention initially applied per generation. The
  collector now bounds retained files across all generations of a placement and
  enforces the host cap. File eviction and native dropped-line counters are distinct.
- Medium, deployment requirement: fixed queue budgets cannot establish a 24-hour
  delivery window without source-rate measurements. Size with 50% headroom and
  monitor oldest chunks, free space, evictions and missing host heartbeats.

## Verification evidence

The three-host NixOS fixture has passed direct delivery, independent collector
restart, destination outage and unread journal recovery across reboot. Native
CloudWatch/OTLP fixtures passed partial-rejection handling, response privacy and
native metric conversion. Root runtime tests passed credential-boundary and native
retention checks. Actual pinned OTP encryption/decryption and missing-key rejection
passed; both encrypted application releases build from source. Both applications
also pass a real OTP process-crash privacy test. Combined module evaluation covers
encrypted dump directories, core suppression and the deployment manifest.

Lilly's 189 tests/properties and Dialyzer passed. Marshall's focused tests and
Dialyzer passed; its full suite had one 100 ms crash-report timing failure which
passed on rerun. Both precommit entrypoints stop at existing missing contract
coverage in the independently added Antithesis skill assets. Scoped Nix contract
syntax/coverage passes. The pre-commit ADR rerun passes all 43 decisions after
the concurrent host-provisioning changes reconciled their installation links.

The extended fixtures additionally exercise collector SIGKILL during an output
outage, explicit audit export and real KVM guest survival across native collector
restart. The SIGKILL/audit fixture and actual KVM/ZFS guest test passed. The final
three-host variant also passed verified-TLS CloudWatch and OTLP delivery, including
post-SIGKILL backlog replay and exclusion of restricted audit from ordinary groups.

## Remaining deployment acceptance

Live AWS IAM/KMS/retention/alarm behavior and production queue sizing require the
target account and measured workload. This change does not deploy resources or
claim live-provider acceptance. Native metric aggregation can reset on process
restart; it is diagnostic state, not durable application authority. Crash dump
retrieval/decryption stays an authorized off-host operation.
