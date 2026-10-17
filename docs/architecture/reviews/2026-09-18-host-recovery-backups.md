# Host recovery backup implementation review

## Scope and decision

This review covers the new backup worktree, NixOS module, per-host secret
materialization, Lilly snapshot/flush boundary, local durable coordinator,
PostgreSQL capture, Restic retention and restore, and fleet/admin observations.
[ADR-0070](../decisions/0070-host-recovery-backups.md) records the authorized design.
The root guidance now requires types across languages, including scripts/tests.

Implementation verification is complete within the isolated scope below. The
review includes integration with main (`5765ca9`) and preserves its SSH and Lilly
cleanup changes. Production deployment remains disabled pending destination and
credential provisioning.

## Findings addressed

- Generic snapshots of Lilly's pool parent would violate native ownership policy.
  The module excludes that parent from generic capture; the native helper copies
  pool metadata under its mutation lock and journals each VM snapshot separately.
- Existing source-transfer policy checks knew only transfer snapshots. They now
  include the independently verified backup expectation, without changing export
  lineage or giving transfer cleanup authority over backup snapshots.
- Cleanup previously inherited S3/database startup dependencies. Cleanup now runs
  without those credentials and retries on boot and every five minutes.
- Native snapshot existence, dataset GUID and local nonce must all match before
  destruction. Failed mount inspection no longer implies absence. A failed mount
  removal retains cleanup intent instead of silently deleting its journal.
- Bounded subprocess execution now stops and reaps a timed-out or overflowing
  reader before cleanup, and supports pool-headroom checks during guest upload.
- Backup records from an earlier collector/boot cannot render as current health.
  Closed telemetry labels and integer measurements exclude raw provider errors,
  database URLs, passwords and arbitrary fields.
- Failed secret preparation must allow the coordinator to record a credential
  failure; optional EnvironmentFiles do not authorize repository access, which
  independently requires valid private runtime credentials.

- Absolute host-path exclusions now follow files into temporary snapshot paths;
  a restored fixture proves excluded bytes are absent.
- Orphan uploads expire after their grace period even before the first complete
  host point; failed runs cannot accumulate those snapshots indefinitely.

## Verification evidence

- Strict mypy passes for all seven new backup runtime modules, guest flush,
  backup observation and their four standalone Python test files (13 files).
- Python tests pass: eight state/credential tests, eleven workflow/command tests
  including 100 generated retention cases, three guest-flush tests, two
  backup-observation tests and fourteen existing fleet collector tests.
- Nix `backup-types`, `backup-configuration`, `guest-flush` and `fleet-monitor`
  checks pass. Both production host configurations evaluate their explicit
  randomized delay to 300 seconds. Native drivers retain NixOS lint/type checks.
- Lilly's full `mix precommit` gate passes: 331 tests/properties (39 properties),
  forced Dialyzer with zero errors, ADR, contracts, compiler and formatting.
- Marshall's full gate passes: 730 tests/properties (64 properties), two excluded
  environment-specific tests, and forced Dialyzer with zero errors. Tests cover
  closed backup ingestion, stale and cross-boot/collector health, and actual
  fleet/host LiveView rendering through the observational cache.
- Nix `backup-recovery` passes real ZFS, Restic over authenticated TLS S3,
  configured remote PostgreSQL with verified TLS, database-outage preservation
  of the last good point, isolated host/database restore, exclusions, retention,
  prune/check and cleanup without database or S3 credentials.
- Nix `guest-backups` passes actual nested Firecracker: current-boot flush with
  unchanged running processes, native accounting, concurrent transfer snapshot
  coexistence, restored guest disk contents, stopped and unavailable-helper
  capture, foreign-nonce refusal and process loss after native snapshot creation
  followed by production journal-driven cleanup. Native execution used the local
  root builder with actual KVM access and the `nested-kvm` feature enabled; it
  did not substitute emulation or fixture responses for guest behavior.
- Architecture links and contract syntax/coverage checks pass. Semantic review
  traced capture/cleanup ownership, publication, reference retention, runtime
  credential custody and observational-only admin consumers. No unresolved
  contract violation was found in that scope.

## Deployment and verification limits

The endpoint, bucket, region and real credentials remain deployment inputs.
There is no physical power-loss, external-provider throughput, production S3
rollout, or automatic historical-authority reconciliation claim. Restore requires
operator fencing and isolated reconciliation, including application-key decryption
checks and rebinding replacement native identities. This feature adds logical
host recovery points; it does not replace existing physical/WAL HA requirements.
