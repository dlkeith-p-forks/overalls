# Empty Lilly authority rebind review

## Scope and architecture impact

This review covers the explicit recovery path needed to enroll an already
installed but empty Lilly host after replacement of Marshall's database. It
extends ADR-0045's administrative enrollment boundary without changing
ADR-0037/ADR-0092 relocation, capacity or workload ownership protocols. Ordinary
automatic updates retain their existing prohibition on Lilly binding changes.

## Findings and disposition

- **Resolved, high — stale physical ownership blocked explicit recovery.** The
  installed host and per-pool owner records retained host and pool UUIDs issued by
  the lost control plane. The normal updater correctly rejected the changed
  binding, but explicit enrollment had no bounded recovery path. The new
  `--rebind-empty-lilly` option is restricted to explicit authenticated enrollment
  and preserves that ordinary-update fence.
- **Resolved, high — a rebind must not adopt live or recoverable workload state.**
  The runner stops Lilly and checks VM units and child cgroups; actor, command, VM,
  guest-network-claim and transfer state; active/import pool records; and recursive
  ZFS dataset/snapshot names before changing authority. It invokes Lilly's reviewed
  network destruction boundary to verify and remove only the old empty host-owned
  namespace, links and tables. Persistent base network configuration and lock files
  are not mistaken for guest state. Any workload residue fails closed. Retired
  deletion tombstones are intentionally retained because they convey no executable
  or transferable ownership.
- **Resolved, high — owner changes span multiple filesystem records.** A private
  prepared/complete journal binds the revision and exact old/new host and pool
  records. Pool records change before the global host record. Retrying accepts the
  exact old/new mix produced by a partial atomic-write sequence; an inconsistent
  completed journal is rejected. The old Lilly service restarts only when all
  authority records can still be proven unchanged.
- **Resolved, medium — physical pool matching could be ambiguous.** Duplicate
  filesystem identities are rejected before mapping pools. Rebinding requires the
  complete non-authority owner shape, native storage identity and transfer-state
  path to remain unchanged.

These were implementation defects in the explicit enrollment recovery boundary,
not reasons to weaken the accepted updater identity contract or replace an ADR.

## Verification

- `nix build .#checks.x86_64-linux.host-planning -L` passed 22 primary and 5
  secondary cases. The focused cases cover success with retained tombstones,
  completed retry, partial-write retry, active execution, durable state, child ZFS
  state, ambiguous/changed physical pools and ordinary-updater rejection.
- The repository Python check passed formatting, linting and typing across 472
  files. Module and enrollment configuration evaluations built successfully.
  ADR validation passed for 91 decisions. Contract syntax, coverage and 19 checker
  regressions passed for 1,793 maintained source files.
- The host-enrollment NixOS machine check was attempted twice. Both runs booted
  the fixture and reached `sshd.service`, then failed in the driver's initial
  Nix-store seed with `failed to start SSH connection to '127.0.0.1'`. This occurs
  before `exercise.py`, the enrollment runner or the rebind path executes, so no
  machine acceptance is claimed from those runs.

The first production rebind attempt exposed a review defect before owner mutation:
the initial implementation required the entire Lilly network directory to be
empty, but an empty host correctly retains its host-level claim, nftables programs
and lock. It stopped Lilly, refused in enrollment preflight and restarted the old
service. The corrected boundary rejects only per-guest claims and delegates exact
empty native-network verification and cleanup to `Lilly.Network.destroy/1` before
changing authority. Focused checks were rerun after this correction. The production
retry passed cleanup and authority mutation, then exposed two later recovery gaps:
candidate activation failed its resource-policy service with only an
undifferentiated diagnostic, and an exact explicit retry refused because the
activated descriptor already held the new binding. The follow-up makes that
already-equal state an idempotent rebind completion and adds closed, non-sensitive
resource-policy reason diagnostics. Production activation retry remains pending
publication of that follow-up.

The closed production reason then identified private receipt I/O. Explicit
enrollment had removed `enrollment.json` to gate polling, while activation replay
of a retained resource-transition journal required that same receipt. A private
in-progress marker now makes candidate activation apply native resource settings
without replaying receipts. Enrollment health remains the only publisher of the
new receipt and clears the marker before enabling the updater; interruption keeps
both the marker and polling gate for an exact retry.

The next retry passed resource activation and reached Lilly startup, which acquired
the new physical owner record and then rejected the retained command-store host
identity as `invalid_state_store`. Although its command directory was empty, the
store's `identity.json` is correctly host-bound authority. The rebind now changes
that exact old-to-new identity atomically after the empty execution/store checks;
the already-completed production journal can repair only its recorded old/new pair
under the same revalidated fences.

## Deployment and remaining acceptance

The production Dungarees host was observed empty before this change. Its reviewed
network cleanup and authority mutation completed under the journal; candidate
activation then failed at the receipt-replay boundary described above. Publishing
the marker follow-up, successful activation, Lilly readiness, scheduler enablement
and the requested Porsche create/clone/two-relocation workflow remain separate
live acceptance. ADR-0092 remains partial until its complete component, native and
live obligations are satisfied.

## Affected decisions

- [ADR-0045](../decisions/0045-declarative-lilly-enrollment.md)
- [ADR-0037](../decisions/0037-workload-placement-and-relocation.md)
- [ADR-0092](../decisions/0092-portable-workload-bundles.md)
