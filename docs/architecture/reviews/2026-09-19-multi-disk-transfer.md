# Multi-disk workload transfer review

- Date: 2026-09-19
- Scope: [ADR-0072](../decisions/0072-multi-disk-workload-transfer.md) implementation
- Change: Inception two-disk workloads become portable through relocation,
  evacuation and cloning; single-disk exclusions and root-only capacity
  arithmetic are removed without a compatibility layer.

## Findings

1. **The single-disk limitation was gate-shaped, not structural.** All drives
   already share the per-placement ZFS dataset, so the dataset-scoped stream
   physically carries both drives. The blockers were the Marshall Inception
   rollback (`relocation_capacity.ex`), the clone admission gate
   (`cloning.ex`/`disk_transfer.ex`), Lilly adoption's exact
   `["rootfs.ext4"]` entry check, root-only publish/stop-evidence, and
   root-only footprint math in relocation and clone capacity.
2. **Capacity undercount was a latent overcommit bug.** Pre-copy source
   headroom, destination mirroring (`2 ×`) and temporary holds used
   `vm.disk_bytes` (root only). Lifting the exclusion without correcting the
   arithmetic would have admitted 320 GiB moves against 64 GiB holds. Both now
   use `VMShape.reservation` footprint in
   `relocation_capacity.ex` and `clone_placement.ex`, including the
   coordinator/sources/receives hold gates.
3. **Destination scheduling needed the ADR-0054 nesting proof.** Relocation
   destination selection and clone placement now require
   `Profiles.host_ready?` so an Inception workload cannot be moved onto a host
   without the fresh native proof; evacuation sources are exempt because the
   workload is leaving.
4. **Evacuation head-of-line robustness.** `:clone_in_progress` was missing
   from the recognized blocker rotation. It is currently unreachable through
   public flows (campaign creation is fenced by `RelocationGuard.host_busy?`
   and clone activation requires a normal-mode source), so the addition is
   defense-in-depth against future interleavings, tested at the admission
   layer rather than through a full campaign.
5. **Porsche and SSH surfaces shrank** by the removed `:clone_not_supported`
   reason with no compatibility mapping, per authorization.

## Affected decisions

- [ADR-0072](../decisions/0072-multi-disk-workload-transfer.md) (new, accepted,
  partial) records the decision and evidence.
- ADR-0054 and ADR-0055 exclusion clauses are cross-referenced as lifted;
  ADR-0037 and ADR-0061 evidence updated; index and overview refreshed.

## Checks actually run

- Protocol: `mix test --warnings-as-errors` — 136 passed (52 properties).
- Lilly: `mix test --warnings-as-errors` — 331 passed (39 properties).
- Marshall: `mix test` — 696 passed (64 properties), including flipped
  Inception admission/footprint tests (320 GiB holds, `2 ×` pre-copy bound,
  proof refusal, evacuation scheduling) and evacuation rotation coverage.
- Porsche: `mix test --warnings-as-errors` — 73 passed (10 properties).
- All four `mix precommit` gates (toolchain, ADR, contracts, compiler,
  warnings-as-errors tests, format, Dialyzer with forced recheck) passed for
  protocol, Lilly, Marshall and Porsche; `elixir scripts/check_adrs.exs`
  passed with 70 decisions.
- Native `kittens-zfs-transfer`: passed in 233.55 s; the new
  "inception two-drive adoption publishes every drive and refuses incomplete
  sets" subtest exercises real `zfs send | zfs receive` of a
  `rootfs.ext4` + 256 GiB `data.raw` dataset through production
  adoption: renamed and wrong-sized drive refusals, recovery after restore,
  per-drive owner/mode publication, hash and exact-size verification,
  idempotent re-adoption, `Disk.prepare` reuse and fenced cleanup.
  Correction (2026-09-19, lifecycle integration): the recorded pass predates
  the final inception driver edit. As merged, the subtest invoked
  `reject-prepare` immediately after `reuse` with no state change between,
  an unsatisfiable expectation that fails identically on pristine
  `origin/main`. The driver now removes `data.raw` first, mirroring the
  plain-adoption retained-disk refusal, so "refuses incomplete sets" tests
  an actually incomplete set; verification of the corrected subtest is
  recorded in the lifecycle integration review.
- Native `kittens-zfs-guest`: passed in 1373.10 s; the new
  "inception clone copies both drives into an independent placement" subtest
  clones a real confined Inception Firecracker guest through production
  `Lilly.Clone.Effects`: both drives publish under the destination identity,
  the booted clone reads its copied data disk, the restarted source's later
  writes do not leak into the clone, and deletion removes both drives.
- Environment note: the local Nix daemon `system-features` was extended with
  `nested-kvm` to run the guest suite locally; no repository configuration
  changed.

An earlier aborted zfs-guest run hit a transient `storage_busy` observation
race in the untouched restoration fixture; the base revision and the changed
tree both pass on rerun, and the three fixture defects found on the way
(profile key path, readiness path, retired clone-key identity) were in the new
test code, not production paths.

## Remaining gaps

- Fleet-level acceptance (an Inception workload moved and cloned across two
  real Lilly hosts through Marshall) is not provided here; it requires the
  32 GiB nested-guest fleet harness that ADR-0054's expanded acceptance
  already tracks as in progress. ADR-0072 records this obligation.

## Verdict

The change is consistent with ADR-0037's single-dataset transfer design and
ADR-0054's scheduling constraints; no boundary, protocol version or custody
contract changed. Multi-disk transfer is implemented and verified at the
storage and execution tiers; fleet acceptance remains the open obligation.
