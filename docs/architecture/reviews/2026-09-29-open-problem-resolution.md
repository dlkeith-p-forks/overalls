# Open problem resolution after repository launch

## Scope

This review covers fixes for problems found while accepting
[ADR-0128](../decisions/0128-repository-launch-links.md). None of them were
caused by that change.

- Lilly startup blocked Brady attribution.
- Committed merge-conflict markers.
- CI coverage for Brady clones and resolver disagreement.
- Fleet monitor delivery in the Brady fleet fixture.
- Four families of load-sensitive or incorrect tests.

## Findings and fixes

- **Lilly startup blocked every service for minutes after a restart.**
  - Before any supervisor child started, `Lilly.Control.Config.load/1` hashed every
    configured guest image, about 3.5 GB each. Until that finished, the Runtime,
    ownership, ingress and the Brady attribution socket were all down, so every
    guest request through Brady was logged `unresolved`.
  - `brady-fleet`'s restart subtest failed for this reason, including at the
    pre-change base `2b30e882`.
  - **Fix:** Lilly now stages images structurally at startup. A final, isolated
    supervisor child, `Lilly.Host.ImageCatalog`, hashes them in the background,
    and host reports advertise only digest-verified images. Launch still
    re-hashes. See the [ADR-0014](../decisions/0014-image-and-address-admission.md)
    evidence.
- **Conflict markers.**
  - `origin/main` carried unresolved markers in
    `nix/tests/machines/fleet/default.nix` from the verification 110/112/113
    merges, which broke every fleet check. Merge commits skip ordinary
    pre-commit hooks, which is how they got in.
  - **Fix:** `scripts/check_conflict_markers.exs` now runs as a prek hook at
    commit and merge-commit time, and as the `conflict-markers` Nix check. It has
    property tests in `marshall/test/architecture/conflict_markers_test.exs`.
- **Brady resolver disagreement and clones in CI.**
  - **Fix:** the `brady-network` origin now answers on a second address and serves
    smart-HTTP git.
  - A guest that dials an address Brady's DNS does not return is still served
    over intercepted HTTPS, including a shallow `git clone`.
  - Plain HTTP to that address, and an SNI the origin certificate does not
    cover, are still refused.
- **Fleet monitor fixture.**
  - The Brady fleet fixture sent samples to the public origin on port 443.
    Production sends them to Marshall's fleet listener on port 5443
    (`fleet/fleet-network.nix`). Every delivery failed silently.
  - **Fix:** the fixture now uses port 5443, and failed deliveries report the
    exception class, never bodies or credentials.
- **Private Audi did not return after a Lilly stop/start.**
  - `audi-private.service` `Requires=` `lilly.service` but was only wanted by
    `multi-user.target`. A stop of Lilly stopped it, and a later start never
    brought it back.
  - `Lilly.Private.Readiness` then failed, and the executor silently deferred
    every new launch. Host enrollment performs exactly this stop/start.
  - **Fix:** `wantedBy` now includes `lilly.service` (base and Inception
    modules), Lilly logs `vm.execution_deferred` once per reason change, and
    Marshall's ingress catch-all records a closed reason class.
  - Evaluation rules in `ziggy-configuration` and `fleet-guest-trust`, and a
    Lilly deferral-history property, cover it. The correlated Audi and
    credential rejections were benign: a pending fleet certificate and a
    deliberately disabled host.
- **Lilly native helpers did not build on `main`.**
  - The pinned clippy (`-D warnings`) rejected two `nonminimal_bool` expressions
    in `lilly/native/transfer-stream` and `lilly/native/host-lock` tests.
  - The production Lilly package links these helper tools, so current `main`
    could not build Lilly for deployment. Lilly's image-copy and locked-command
    tests also failed with `:utility_unavailable`.
  - **Fix:** clippy's equivalent expressions. The helper tools build, and those
    tests pass (12/12) with them on `PATH`.
- **Stale evaluation checks.**
  - `ziggy-configuration` evaluated the Audi private issuer through the default
    host module, which dropped it in `daef5cb8`. It now imports the issuer
    module explicitly, as the Inception guest does.
  - `fleet-guest-trust-configuration` asserted a 16 GiB pool for every variant,
    although clone journeys use 32 GiB since `bce13223`. It also used the
    regex-based `lib.hasInfix` on whole composed scripts, which overflowed the
    evaluator stack. It now uses a plain substring scan.
- **Tests that asserted what the product never promised.**
  - `CustomerIsolationTest`: placement raced between two test hosts. Fixtures now
    provision on their own host.
  - Lilly Inception, credential and lock deadline tests: wall-clock bounds are now
    derived from the configured deadlines, with tolerance, and stalls are long
    enough to still detect overruns.
  - `AgentRevocationHistoryTest`:
    - Digests were fixed across generated runs, colliding on a globally unique
      column.
    - The test asserted that the fixture's own approved session was refused.
    - It treated withdrawn member sharing as removing the owner's authority.
  - `CredentialManagementBoundsTest`: aligned with the closed passkey-label
    refusal (commit `a20e7ff6`).

## Evidence

| Gate | Result |
| --- | --- |
| `brady-network` native | Passed, including "intercepted HTTPS and git clone survive a disagreeing guest DNS view" (59.26 s). |
| `brady-fleet` native | Passed: all 10 subtests, including "Brady and Lilly restarts preserve guest lifetime and refresh flow attribution" (11.58 s) and "address reuse cannot attribute an old kernel flow to the new owner" (62.47 s); test script 320 s. |
| Marshall full suite | 1342 passed (166 properties), 0 failures. |
| `ziggy-configuration`, `fleet-guest-trust-configuration` | Passed after the stale-check fixes. |
| Lilly `mix precommit` | 436 tests (56 properties), Dialyzer clean. |
| Repeated flaky-test runs | `CustomerIsolationTest` 20/20; Lilly deadline tests 20/20 isolated and 5/5 full suites under load; `AgentRevocationHistoryTest` 6/6. |
| `conflict-markers` Nix check | Built; the historical broken module is detected. |

## Remaining gaps

- The drive-by launch, the shared checkout and GitHub-only scope remain
  deliberate ADR-0128 decisions.
- Units that require `ziggy.service` or `galileo.service` share the
  stop-then-start shape. Private Audi is not wanted by them, because that would
  also start Lilly while enrollment deliberately holds it stopped.
- Reverted: a Ziggy/Galileo `ExecStartPost` that restarted private Audi while
  Lilly was active (415bffb2) broke guest readiness. Bisection with the native
  `default-oss-creation` check showed its parent and main without the hook
  passing, and every build containing it failing: guests booted, received
  trust, then never answered readiness. The mechanism was not identified when
  it was reverted.
- Re-assessed 2026-10-02: no hook is needed. The deploy path
  (`nix/modules/auto-update/runtime.py` `activate`) stops every consumer and
  health unit, switches, then explicitly starts all health units including
  `audi-private.service`, and its health check requires private Audi active.
  A throwaway NixOS VM test on the pinned systemd (260.2) showed that a
  `Requires=` dependent is restarted with its dependency on a crash with
  `Restart=on-failure` and on `systemctl restart`, and stays down only after a
  manual `stop` then separate `start`. The residual gap is therefore that
  operator sequence only, documented in HLDD 04-lifecycle.
- Reproduced the reverted hook on 2026-10-02 with the new fleet guest
  diagnostics: the guest still failed readiness, and its serial console showed
  neither the readiness diagnostics (first due 45 s after boot) nor the
  boot-complete line, although both appear on healthy guests (default-oss
  asserts the latter). The guest therefore never reached its timers or
  multi-user.target; why the hook causes that remains unexplained and is moot
  while no hook is used.
