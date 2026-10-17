# Bounded Nix store garbage collection review

Date: 2026-09-19

## Scope and architecture impact

[ADR-0073](../decisions/0073-bounded-nix-store-reclamation.md) adds
threshold-gated, per-run-bounded Nix store garbage collection and enables it on
every fleet host through the shared profile. The change touches host storage
reclamation only: no application, protocol, secret custody, isolation or guest
lifecycle boundary changes. [ADR-0036](../decisions/0036-automatic-host-updates.md)
keeps its documented exclusion of generation retention from the updater;
[ADR-0067](../decisions/0067-reciprocal-nix-builders.md) cache and scheduling
policies are unchanged, with the accepted interaction documented below. The
design ports TVL depot's automatic garbage collection module to Overalls
conventions at the user's request.

## Findings and resolution

- depot's `services.depot.automatic-gc` ran `nix-collect-garbage` through a
  store-path `script` with a `/run` kill switch, `multi-user.target` timer
  activation and untyped options. The Overalls module uses inline script text,
  typed options (`strMatching`, `ints.positive`), `timers.target` with jitter
  and catch-up, and makes stopping the timer the documented control.
- The guest dataset quota is a ceiling, not a reservation: legitimate guest
  growth can push pool free space below the 200 GiB threshold, where a run
  finds nothing older than fourteen days and exits. This no-op cost is
  hourly, bounded and accepted; the module and guide document it.
- Unreachable remote-builder cache paths may be reclaimed within the 400 GiB
  cap. Caches repopulate on demand; reciprocal builder trust and signing
  policy are unaffected.
- Concurrent auto-update builds are safe through Nix's temporary roots; a
  collection may briefly contend on the GC lock with a build. No ordering
  dependency between the units was added.
- Overalls and Dungarees measured identically: 1.73 TiB mirror, 428 GiB
  root-side use, 1593 GiB guest quota (~170 GiB root share). 200 GiB sits
  just above the ZFS performance cliff; 400 GiB reclaims the entire current
  root-side backlog in one bounded run. Sixty-six system generations had
  accumulated in roughly two days, confirming unbounded growth.

## Validation

All checks ran from the isolated worktree on the committed files.

- The new evaluation check passed with all nine cases — opt-in unit absence,
  timer emission and conventions, threshold gate with baked byte conversions,
  bounded deletion arguments, pinned `nix.package` invocation, typed
  rejection of invalid intervals/sizes/preservation windows, and default
  enablement across all four production profile fixtures:
  `/nix/store/wv084670ynq35rv04xx0p519g8ip1zrr-overalls-nix-gc-check.json`.
- Module and storage-configuration regressions passed after the profile
  change: `/nix/store/9c80yh8jfd8r7l4a59ih2qr7z5xpgxxi-overalls-module-configuration-check.json`
  and `/nix/store/jpnj08jq8347xilbww00xp7ycbrdl973-host-profile-checks.json`.
- Direct evaluation confirmed both enrolled hosts and both base
  configurations produce `overalls-nix-gc` timers with the reviewed values
  (1h, 200/400 GiB, 14d, `timers.target`, persistent).
- `nix flake check --no-build` fails identically on `main` and this branch on
  fixture-dependent checks that require previously built images (different
  unrelated derivations). This is a pre-existing limitation of `--no-build`
  in this repository, not a regression; affected checks were built directly.
- Marshall's full `mix precommit` gate passed in the worktree with the pinned
  runtime: toolchain, ADR structure, code contracts, compile, tests against
  the private loopback port-55439 fixture database, formatting and Dialyzer
  (0 errors). `cc-check format` does not support Nix sources, so contract
  syntax was validated through the precommit contract gate, matching the
  documented discovery limits.

No machine-level execution was performed: no runtime collection, KVM run or
production activation is claimed.

## Remaining gaps

Production hosts must activate the merged configuration through the normal
update path before actual reclamation is established; the first hour of
journal output on each host is the operational confirmation point. A
machine-suite test that fills `/nix` below a synthetic threshold and observes
bounded collection remains an open question under ADR-0073. The reviewed
200/400 GiB values should be revisited if production observations diverge.
