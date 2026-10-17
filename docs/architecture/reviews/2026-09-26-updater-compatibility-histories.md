# Updater compatibility histories

## Scope and architecture impact

Improvement034 uses branch `verify/034-updater-compatibility`, based on published
`ddf1d05a`. The operator journey adds compatible decryption keys, refuses changed
authority or destructive key-ring changes, then explicitly retries a corrected
candidate. There is no production runtime or release-policy change.

Reviewed [ADR-0036](../decisions/0036-automatic-host-updates.md)'s inherited
policy through ADR-0038 → ADR-0043 → ADR-0048 → ADR-0050 → ADR-0051 → ADR-0053 →
ADR-0126, ADR-0032 custody through ADR-0041/0044/0067/0086 and the ADR-0050
resource-only exception. Existing
decisions and statuses remain unchanged. Root-owned generated configuration
remains trusted; this work establishes no malformed-policy production defect.
Pre-switch compatible migration, immutable candidate identity, health verification,
no schema rollback and independent host scheduling remain in force.

## Discovery and implementation

Whole-tree caller search and inspection of the Nix test/package/flake/devenv
catalog found no executable caller for `nix/verification/tests/machines/auto-update/unit.py`.
The Python static check validates source but does not execute its assertions.
`resources_test.py` already executes separately in `host-planning`.

The new exported [check](../../../nix/verification/tests/evaluation/auto-update-compatibility.nix)
executes the unchanged [fixed assertions](../../../nix/verification/tests/machines/auto-update/unit.py)
with the supplied actual runtime path, plus two typed
[Hypothesis properties](../../../nix/verification/tests/machines/auto-update/compatibility_histories.py).
The new check copies production `runtime.py` as `updater_runtime.py`, allowing
the generated histories and standalone typing to resolve the actual declarations.
It uses the supplied pinned Python/Hypothesis/Ruff/ty packages. Standalone
`ty check` names all three copied Python files in a directory without an ancestor
project configuration, avoiding the ordinary machine-path include filter;
repository Ruff policy is retained in a separate child configuration directory.

Each of 32 generated operation histories contains all ten operations in varied
orders: key addition, inactive reorder, removal, active promotion, material
replacement, three shared-authority changes, filling sixteen entries and
overflowing to seventeen. The expectation comes from requested operation intent
and the independently retained accepted baseline. Both the real predicate and
inherited preflight must agree; a refusal is followed by explicit corrected retry.
Initial rings have at least three distinct keys, making promotion and inactive
reorder observable. Pure predicate calls must preserve both supplied mappings.

Each of 24 generated baseline histories supplies three serving rings in varied
orders. A candidate fits the first but lacks keys held by the others; the corrected
candidate fits all. A differing shared authority at each possible serving position
must veto admission. An incompatible installed file is ignored while services are
serving and becomes authoritative when none are serving. A poisoned unstaged file
ensures actual `selected()` uses the staged candidate.

## Isolation and contract review

Reviewed root, Nix/test, updater, documentation and handbook contracts plus
`compatible`, `selected`, `environment`, `serving_environments`, `preflight` and
the `run` caller. Actual `preflight` remains before migration and activation.
The typed subclass replaces only environment parsing and serving-process discovery;
unexpected commands fail closed. It deliberately bypasses the constructor that
would load root-owned helpers/state. No production path, database or service is used.

Disposable mode-0700 directories contain synthetic authority files with mode0600.
Every attempt compares the complete local file name/byte/mode/inode inventory,
serving mappings, manifests and staged path selection. Refusal must be exactly
`coordinated_secret_change`; preflight emits no stdout/stderr. These assertions
cover the actual local seam boundary. They do not establish systemd parsing,
`/proc` discovery, private staging, journal behavior, migration, activation,
durable deployment-state retry or guest survival. Synthetic key material is a
fixture only and is never installed as a production default.

No contract or accepted-policy violation was found in the final scoped review.
Syntax/discovery checks are separate from the behavioral assertions.

## Execution evidence

The exported `auto-update-compatibility` check passed in **11 seconds** on
2026-09-26. The unchanged fixed suite ran **14 tests** in 0.769 seconds; the
two generated properties ran in 2.091 seconds with 32 operation histories and
24 serving/fallback histories configured without filtering or database reuse.
The build log explicitly reports all three copied files passing standalone ty,
plus Ruff formatting and lint.

- Base: `ddf1d05a5749bf202d967cf8d687e50969d9fe0c`.
- Captured executable tree: `496cb8b974f9e3872d768d68649db51e7d02f78c`.
- Derivation: `/nix/store/1knzjmv4gf6zw6yifc9388fy63sdwnj1-overalls-auto-update-compatibility.drv`.
- Result: `/nix/store/24ylbg3qvr6fjlsiq8d3vlr6m6a8lbgr-overalls-auto-update-compatibility`.
- Production runtime SHA256: `06adee90c7c116381e1b9632c53b198a4bc23ee4415348953128c1f9f2259fe1`.
- Unchanged fixed-test SHA256: `5d228c81768f0cbd4996424a02f05cf10c86b50884e47909196b3d42a0ef012b`.
- History SHA256: `15fd26f69d0ff48a3a6fa270d072c28416721ba49ec61b4a85eb9c56a9e65312`.
- Check SHA256: `5fd55b0cbd88298b42c87457ee758864d5d57fba0d2d6fc68a9f37625fd871d5`.

Two prior check preparations failed before assertion execution and remain
recorded: the first sandbox classified the copied runtime as a local import,
exposing a Ruff ordering difference; an explicit import group corrected it.
The second used unsupported pinned-ty `--isolated`; explicit filenames in the
configuration-free sandbox corrected the command without weakening any rules.
Neither failure is counted as a native run or behavioral test result.

The initial scenario generator also rejected a prose assertion combining two
method names. Separate exact source assertions corrected the evidence entries;
this documentation failure did not change or rerun executable inputs.
The final evidence-only receipt refresh correctly rejected `updated` without
another chapter change; the reviewed bookkeeping is recorded as `no-impact`.

Contract syntax/discovery and scoped coverage passed. Pinned all-file `prek`
passed every logging, HLDD, Ruff format/lint and ty hook. The ADR checker passed
124 decisions; reviewed HLDD receipts, generated option/scenario checks and
Ash/deployment views passed. The Nix `hldd` check passed in 20 seconds. Final
executable hashes still match the captured passing inputs; evidence bookkeeping
does not rerun unchanged application or native suites.

## Retained native evidence and gaps

The [original updater review](2026-09-16-automatic-host-updates.md) retains its
isolated snapshot based on `8be693e`, actual-switch/credential-rotation acceptance,
three observed migrators and 1,714-second fleet result. Later identical-system,
socket recovery and Audi role checks retain their respective ADR-0036 references.
None is reclassified as execution of these generated histories.

No new native run is required for unchanged pure compatibility/preflight behavior.
Actual systemd process discovery, live environment replacement during a switch,
concurrent writers, native migration/activation and physical rollout need their
own evidence; local command seams cannot prove them. Independent physical rollout
scheduling remains outside host-local updates and automatic database rollback
remains forbidden. No application or shared-governance source changed, so the
unchanged application suites are not rerun for documentation. No Inception tests
or validation were run.
