# healthy-revision-requires-live-candidate

P0; high source confidence for the claimed ordering, hosted execution untested; safety `Always`, message **`lifecycle.update_healthy_requires_active_closure_current_secrets_and_role_health`**. The SDK assertion is missing per [scan](../existing-assertions.md). Every *new* `lastHealthy` must identify the exact active candidate closure after current secret preparation, successful candidate migration where required, and two bounded affirmative checks for each enabled role's correct readiness document. Identical-closure/current-secret verification is a separate allowed path. A stale prior healthy receipt is not a new advancement; a mere systemd-active signal or wrong v1 role/host document is not sufficient.

## Evidence and fault history

`nix/domains/system/auto-update/runtime.py:341-405` stages/compares secrets; `:437-578` preflights and runs the candidate migrator; `:580-745` switches closure and restarts secrets/consumers; `:746-940` checks active closure, secret units and two affirmative role rounds before writing `lastHealthy`; `:985-1012` handles identical closure. Role schemas differ: Ziggy includes host ID, Enrico/Audi include role, and Porsche status need not include role. [Focus 08](../discovery/property-candidates-08/healthy-revision-requires-live-candidate.md) supplied exact closure/current secret and identical-closure branch; [focus 10](../discovery/property-candidates-10/updater-versioned-health-before-promotion.md) supplied exact versioned health documents and migration custody. ADR-0036 and auto-update CONTRACTS are accepted design claims. Interrupt staging, migrator, switch, secret unit, first/second health checks or state write; vary one stale role response at a time.

## Oracle, environment, and instrumentation

On a native NixOS fixture, independently read the active closure symlink, migration unit status, secret descriptor/digest comparison (never secret bytes), enabled systemd units and live status responses; watch atomic updater state for each new `lastHealthy`. Vary closure and secret sameness, health v0/v1/v2/missing, role/host mismatch, negative status and configured `healthTimeout` 10/120/1800 seconds. A service-only fake cannot establish native activation. Distinct `Reachable` messages should mark identical-closure verify, changed-release promotion, and rejected stale role document.

## Open questions

- Can the native update fixture vary malformed and stale status documents through every real service health implementation? `(partial: native promotion and parser/socket tests exist separately; one combined source-built role matrix is missing)`

### Investigation Log

#### Can a native fixture vary status-socket documents through each real service health implementation?

- Examined: `nix/verification/tests/machines/auto-update/default.nix:1-105`, `driver.py:1-145`, `unit.py:312-460`, `nix/verification/tests/machines/fleet/scenarios/updates.py:1-48`, and `nix/domains/system/auto-update/runtime.py:746-940`.
- Found: the NixOS updater fixture switches real prebuilt specialisations and checks healthy promotion/refusal; the fleet fixture upgrades real Lilly and probes guests. Unit tests serve controlled socket documents for Porsche, Audi and host-bound health parser paths. `verify/1` requires two affirmative rounds before `record_healthy/3`.
- Not found: a single native fixture whose source-built Ziggy, Enrico, Audi and Porsche services can each emit controlled v0/v1/v2, wrong-role/host and stale documents while the updater performs a real switch. Parser mocks cannot prove those services' actual socket behavior.
- Conclusion: partial. Keep native switch/role status evidence and parser refusal evidence separate; add per-role live socket fault controls and observe `lastHealthy` plus active closure before claiming the combined matrix.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `no selected hosted template`. native-only-currently; independent witness: actual Nix closure, migrator/systemd/secret and enabled role health; surviving guest VMM/cgroup/disk where applicable. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
