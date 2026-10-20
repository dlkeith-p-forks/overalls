# ADR-0073: Bounded Nix store garbage collection

- ID: ADR-0073
- Date: 2026-09-19
- Status: accepted
- Implementation: partial
- Components: NixOS deployment, automatic updates, host storage
- Supersedes: none
- Superseded by: none

## Context

Automatic host updates build and activate a new system from Git on every
poll. Sixty-six system generations accumulated on Overalls within roughly two
days of operation, and the updater explicitly excludes generation garbage
collection from its scope. `/nix` grows without bound while sharing storage
with guests: on Hetzner mirrors the store lives on the `zroot` pool beside the
quota'd guest dataset.

Measured on Overalls (Dungarees is identical): a 1.73 TiB mirror, 428 GiB of
root-side use, and a 1593 GiB guest quota that is a ceiling rather than a
reservation, leaving roughly a 170 GiB root-side share. The user authorized
porting TVL depot's threshold-triggered automatic garbage collection with
fleet-wide default enablement and reviewed values for both hosts.

## Decision

Add `services.overallsNixGc`, an opt-in NixOS module providing a oneshot
service and timer. A run executes only when free space on the filesystem
holding `/nix` (`df --output=avail`) falls below the configured GiB threshold;
it then invokes `nix-collect-garbage --delete-older-than
preserveGenerations --max-freed` with a GiB-bounded deletion cap, using the
host's configured `nix.package`. The default interval is hourly with jitter
and missed-run catch-up.

Every base and enrolled fleet host enables the module through the shared host
profile; each host sets its reviewed threshold, cap, interval and preservation
window (default 14 days) through its own configuration. Stopping the timer is
the documented manual-recovery control; no in-script kill switch exists.
Generic module defaults (100 GiB threshold, 200 GiB cap) serve any fleet host
without an explicit override.

## Alternatives

The built-in `nix.gc` service collects unconditionally on a calendar without a
free-space gate. Nix's `min-free`/`max-free` settings were rejected by depot
as unreliable and act inside the daemon rather than as a reviewable host
policy. Keeping no collection leaves generation growth unbounded. Per-host
opt-in risks a future host silently lacking reclamation, so the profile
enables it by default.

## Consequences

Reclamation is bounded per run and preserves recent generations. Because the
guest quota is not a reservation, legitimate guest growth can push pool free
space below the threshold, where a run finds nothing older than the
preservation window and exits; this accepted no-op cost is hourly and cheap.
Unreachable remote-builder cache paths may be deleted, bounded by the cap;
they repopulate on demand. Concurrent updater builds remain safe through
Nix's temporary roots, with brief GC-lock contention. The threshold keeps the
pool above the ZFS performance cliff whenever collection can actually free
space.

## Invariants and verification

The evaluation check must verify opt-in unit absence, timer emission and
conventions, the threshold gate and baked byte conversions in the script, the
pinned `nix.package` invocation, typed rejection of invalid intervals, sizes
and preservation values, and default enablement on production profile
fixtures. A machine-level collection test and production runtime observation
remain open obligations.

## Implementation evidence

- [Module](../../../nix/domains/system/nix-gc.nix) implements the threshold-gated,
  bounded collector and its contract.
- [Host profile](../../../nix/platform/hosts/profile.nix) enables collection on every
  fleet host by default.
- [Overalls](../../../fleet/roles/control-plane/configuration.nix) and
  [Dungarees](../../../fleet/hosts/dungarees/configuration.nix) carry the
  reviewed 200/400 GiB values with measured rationale.
- [Evaluation check](../../../nix/verification/tests/evaluation/nix-gc.nix) covers unit,
  script, type and fleet-default obligations.
- The [review](../reviews/2026-09-19-nix-store-gc.md) records scope and
  verification limits. Configuration-level implementation is verified; actual
  collection on production hosts is pending activation.

## Open questions

Whether a machine suite should exercise real collection below a synthetic
threshold, and whether production observations justify adjusting the reviewed
values.

## Related decisions

[ADR-0036](0036-automatic-host-updates.md),
[ADR-0067](0067-reciprocal-nix-builders.md).
