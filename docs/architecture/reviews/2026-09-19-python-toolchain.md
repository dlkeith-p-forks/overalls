# Python typing and static-analysis gate

## Scope and decision

This review covers the repository-wide Python typing refactor and the new
static-analysis gate: a root `pyproject.toml` configuring pinned ruff
(format, lint including annotation requirements) and ty (type checking),
prek git hooks installed through devenv `git-hooks`, the new `python-static`
flake check mirroring the local gate in CI, and the replacement of the
`backup-types` mypy gate with the same ruff and ty checks. All 175 tracked
Python files outside `.agents/skills` and `marshall/deps` were reformatted
mechanically and fully annotated.

No accepted decision changes. ADR-0070 requires strict type checking for the
backup modules; this change preserves that requirement while moving it from
mypy to the pinned Rust toolchain. The machine drivers keep the NixOS test
framework's own lint and type gates over the composed driver, as required by
the `composed-drivers-statically-checked` contract in `nix/verification/tests/support`;
this change adds standalone formatting, linting and annotation enforcement for
the fragment files without bypassing composition.

## Structure

Three tiers, configured in `pyproject.toml`:

- Fully checked standalone (ruff format, ruff check with annotation rules, ty):
  `nix/domains/system`, `nix/domains/artifacts`, `nix/verification/tests/evaluation`, `nix/verification/tests/support`,
  `audi`, `scripts`, `marshall/scripts`, `lilly/test/transfer`.
- Format, lint and annotations without standalone type checking (the framework
  type-checks the concatenated driver): `nix/verification/tests/machines`.
- Excluded: `.agents/skills` assets (managed skill payloads) and vendored code.

Third-party imports resolve against a pinned `python3.withPackages` closure
(aiohttp, boto3, cryptography, dnslib, hypothesis, playwright, pyyaml,
websockets) passed via `ty check --python`, so interface drift in those
libraries is caught without an ambient environment. The target is Python 3.13
(the oldest pinned interpreter that runs this code).

## Findings addressed

- The typing refactor is behavior-preserving: TypedDict schemas with
  fail-closed validators replace bare dicts at descriptor boundaries following
  the established `backups/schema.py` pattern; importlib-loaded library
  surfaces (secret preparation, resource policy, updater) get minimal
  Protocols instead of untyped module attributes; JSON boundaries narrow
  through `object`-typed locals. Every hunk beyond annotations came from the
  sanctioned lint set (loop-variable binding, `contextlib.suppress`, combined
  context managers, ternaries) and is enumerated in the wave reports.
- Dynamic imports that only resolve at runtime (argv-driven `sys.path`
  insertion, unit `PYTHONPATH`, packaging-time copies) carry documented
  `# ty: ignore[unresolved-import]` comments naming the runtime source; there
  are no blanket ignores and no `Any` (ANN401 enforced).
- The `backup-types` sandbox copies production modules flat, so two of those
  dynamic imports resolve there and their root-only suppressions would be
  reported unused; the sandbox appends `unused-ignore-comment = "ignore"` to
  its private config copy. The repository-level gate keeps the default so
  stale suppressions still fail.
- `cloudwatch/manage.py` annotation-only `botocore` imports stay behind
  `TYPE_CHECKING` with quoted annotations so the stubbed evaluation test
  environment (which only fakes `boto3`) is unchanged.

## Validation performed

- `prek run --all-files` passes locally (ruff format, ruff check, ty) with the
  generated devenv git-hooks configuration, and the hooks fire on commits.
- Nix evaluation checks built successfully: `python-static`, `backup-types`,
  `fleet-monitor`, `brady-storage`, `host-planning`, `enrollment-preparation`,
  `secret-reconciliation`, `acme-lookup`, `guest-flush`, `guest-readiness`,
  `inception-runtime`, `audi-private-pki`, `ubuntu-guest-unit`,
  `logging-transports`, `encrypted-crash-dumps`, `private-services-guest`.
- `python3 scripts/test/test_porsche_acceptance.py` passes (6 tests).
- `elixir scripts/check_adrs.exs` passes; the code-contract format check is
  unchanged because no `@cc` directives moved.

## Remaining gaps

- The KVM machine suites were not re-run for this change; their drivers are
  covered by the framework's composed-driver lint and type gates, and their
  Python changes are annotations plus the enumerated behavior-preserving
  refactors. A routine machine-suite run on merge remains advisable.
- The Playwright browser probes (`marshall/scripts`) are type-checked but not
  runtime-verified here; they require an operator-provided Chromium.
- ty is pre-1.0; its diagnostics may shift across nixpkgs pins. The gate runs
  one pinned version from the devenv-nixpkgs input, and the nix check pins the
  same version, so drift only appears on input updates.
