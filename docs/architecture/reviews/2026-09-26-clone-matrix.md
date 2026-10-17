# 2026-09-26: Clone matrix completion — image/profile/shape, failure permutations, independence oracles

Verification campaign improvement 116. Scope file: the discovery clone matrix
brief (image/profile/shape coverage, native failure permutations, direct
independence oracles). Branch `verify/116-clone-matrix`. Hard exclusions
honored: no `staging_identity?/1` or `received_dataset.ex` edits (in-flight
parent-accounting repair), no 020 cancellation-model overlap beyond the
published model files, no Inception tests, no production deployment.

## Scope delivered

Ash/PostgreSQL (new `clone_matrix_test.exs`, extended `clone_history_test.exs`):

- OSS sources clone through the real coordinator, keeping the captured profile.
- Customer sources with custom shapes keep `{architecture, image_id, profile,
  vcpu, memory_bytes, disk_bytes}` on the destination row and offered workload
  descriptor exactly; no catalog or default re-derivation.
- A clone after a completed ADR-0051 growth captures the grown 3 GiB shape on
  the destination row, descriptor and reservation.
- Image disable/rotation refuses fresh admission (`image_unavailable`) while
  the existing workload's clone activates, completes and retains its original
  image; request replay identity is stable under churn.
- Non-inception clones are independent of the configured inception image; a
  source reclassified into that configuration fails closed at activation with
  `profile_image_mismatch` and leaves no destination, transfer slot or effect.
- An unconfirmed copy keeps the request in `copying` with its retained
  snapshot, holds and slots; the authenticated receipt marker clears with the
  exact effect, and an explicit retry re-offers the same descriptor and intent.
- A destination that fails after publication moves to ordinary lifecycle
  ownership: `retry_clone` refuses `clone_not_retryable`, `cancel_clone`
  refuses `clone_already_published`, and the retained snapshot and rows remain.
- A generated property drives profile (customer/standard/oss), size (vCPU,
  memory, disk), power (running/stopped) and churn (none/disabled/rotated)
  variants through completed clones with a source-row comparator and
  independent refusal checks.

Native (fleet `cloning-fleet` additions, new zfs and permutation checks):

- `cloning-fleet` additionally asserts retained shapes on the real cross-host
  clone, ZFS `origin` emptiness and dataset GUID distinctness on both hosts,
  guest-console divergent-write invisibility, an OSS source leg with its image
  disabled mid-flow (`new` refuses while the clone completes), a public CLI
  `request cancel` issued during a real receive (source restored with unchanged
  disk identity, destination reclaimed, slots released), and post-publication
  cancel refusal. The stopped browser-clone leg now re-asserts stopped state,
  host console idleness and unchanged dataset GUID natively.
- `zfs-guest-clone` (separate suite, given the main suite's four-hour bound):
  clone after a completed 4 GiB resize with physical grown-disk capture and
  guest shape checks, plus clone-of-clone (an adopted receive restarted and
  captured as the next source) with pairwise GUID distinctness, origin
  emptiness, divergent-write invisibility and source-deletion independence.
- `clone-destination-loss`: crash the destination provisioner after its
  receive-created dataset exists; cancellation then retains slots, the
  destination hold and pending effects while the source restores, and finishes
  only through real effect receipts after the host rejoins; a cancelled request
  refuses retry.
- `clone-marshall-restart`: restart all three Marshall replicas mid-copy; the
  durable admitted request completes exactly one capture and one independent
  copy. Then two running sources on distinct hosts clone concurrently: exactly
  one wins one-slot-per-host arbitration, the loser fails with a durable
  retryable admission refusal, and an explicit retry completes it with its own
  snapshot and destination.

## Defect verdicts

1. **Inception/image reconfiguration binding.** Verified by inspection and
   pinned by test where the campaign allows: `ClonePlacement.reserve!/1`
   re-runs `Profiles.validate/1`, so an existing Inception-profile VM whose
   image is no longer the configured inception image cannot be cloned —
   conflicting with ADR-0092's catalog-independent existing-workload guarantee.
   Non-inception behavior is pinned (independence under configuration change;
   reclassification fails closed). The Inception-side resolution is a design
   choice (campaign excludes new Inception tests); requires user delegation.
   No code change.
2. **Failed terminal copies with retained unpublished snapshot not retryable.**
   Not reproduced — the described state is unreachable: the state machine's
   `fail` transition admits only `queued` (no destination/snapshot exists;
   retry re-queues from scratch) and `cleaning` (publication already
   happened). Mid-copy physically unconfirmed work never terminates the
   request; it keeps the fixed snapshot and explicit retry re-offers it
   unchanged, which matches the decision text. Pinned by the new matrix tests
   covering both terminal classes; no repair applied and none required by the
   recorded classification.

## Mutants and instrumentation

This scope names no required mutants. None were injected as part of this
improvement; the new oracles are regression statements over the referenced
classification and independence invariants, and the campaign's mutation-testing
coverage for clone remains tracked separately.


## Execution record (pinned assertion texts)

- All six clone matrix tests passed in the focused suite.
- The extended focused clone/history suite passed with the new property included.


## Evidence and execution

Focused suites (MIX_TEST_PARTITION=verify116, ERL_FLAGS="+S 6:6"):

- `clone_matrix_test.exs` alone: 6 tests, seed 469515 — pass.
- Extended set (cloneHistory, cloning, clone_ordering, clone_matrix, resize,
  state_machine): 39 checks (9 properties, 30 tests), 8 excluded, seed 351686 —
  pass.
- Stability rerun of clone_history + clone_matrix at seed 90210: 11 checks —
  pass.

Native machine runs (HEAVY lock, serialized): see per-check entries in
`nix/tests/README.md` and the scenarios ledger. Captured run facts (derivation
and output paths, durations) are appended below as they complete:

- (pending) `cloning-fleet`, `zfs-guest-clone`, `clone-destination-loss`,
  `clone-marshall-restart`.


## Native execution status (2026-09-28 landing note, corrected post-hoc)

The new native legs are registered as checks: `zfs-guest-clone` (clone matrix
storage composition), `clone-destination-loss` and `clone-marshall-restart`
(fleet permutation drivers). Execution evidence today:

- `zfs-guest-clone`: **green — `nix build .#checks.x86_64-linux.zfs-guest-clone`
  succeeded in 2,104s under the heavy lock on this tree** (the build log streams
  the clone-after-resize subtest through `resized-start`/`resized-read`; the
  earlier "failed" readings of this same run were wrapper phantoms — the
  daemon-side build kept streaming and completed successfully).
- The adjunct `lilly-transfer-sshd` unit restart-loops throughout without
  blocking the driver; the pure `zfs-guest` baseline on the same tree passed
  in 1,179s with the same loop.
- Fleet permutation legs (destination-loss mid-receive, marshall restart
  mid-copy): authored and registered; their browser-bearing fleet base is gated
  by finding 119's browser acceptance defect — recorded as queued, not claimed.
