# Runtime, type analysis and Lilly foundation review

Date: 2026-09-15. Scope: the runtime and type-analysis milestone and initial Lilly
release/inventory code under
[ADR-0002](../decisions/0002-elixir-ash-and-types.md) and
[ADR-0009](../decisions/0009-assurance-and-testing.md). The full platform goal
remains active; this review does not treat the governance milestone as completion
of VM provisioning.

## Architecture impact

The prior shell used Elixir 1.18.4 and the application allowed `~> 1.17`.
The selected runtime is now pinned to Elixir 1.20.4 and OTP 29.0.6. Both releases
were checked against the official release APIs on this date:
[Elixir release](https://github.com/elixir-lang/elixir/releases/tag/v1.20.4) and
[OTP release](https://github.com/erlang/otp/releases/tag/OTP-29.0.6).

[Nix toolchain](../../../nix/domains/artifacts/infrastructure/toolchain.nix) pins release source hashes, retains
debug information needed by Dialyzer, and uses a headless OTP build.
[devenv](../../../devenv.nix) selects those runtimes;
[version file](../../../.tool-versions) records the matching versions for other
version managers. [Runtime check](../../../scripts/check_toolchain.exs) verifies
both actual patch versions before precommit.

[Marshall's Mix project](../../../marshall/mix.exs) and
[Lilly's Mix project](../../../lilly/mix.exs) require the selected Elixir patch
version and add Dialyxir to development/test dependencies and precommit.
This enforces the previously accepted decision; no replacement ADR is needed.

Lilly now has an independent OTP application and a typed, read-only
[CPU/memory inventory collector](../../../lilly/lib/lilly/host/inventory.ex).
Physical cores are deduplicated across hyperthreads; missing topology is unknown.
Malformed/unreadable capacity returns an error. Memory free and available are
distinct; available is the kernel's estimate accounting for reclaimability and
watermarks, so it need not exceed free. See the
[kernel procfs definitions](https://docs.kernel.org/filesystems/proc.html).
Properties cover generated CPU topologies and memory capacity bounds. This is a
partial step under [ADR-0004](../decisions/0004-lilly-and-vm-actors.md) and
[ADR-0006](../decisions/0006-capacity-accounting.md), not a scheduling ledger or
complete telemetry collector. Privileged VM effects are not present yet.

## Verification and findings

- Nix built the pinned runtimes successfully. The version checker accepts
  Elixir 1.20.4/OTP 29.0.6 and rejects the original 1.18.4/28.5.0.5 shell.
- Lilly's seven unit tests and two properties pass on the pinned runtime. A live
  read of this exe.dev VM reports x86-64, 32 logical/physical cores and memory
  byte counters. This confirms procfs collection, not KVM or admission behavior.
- The new compiler found two redundant truthiness conditions in generated
  table content (`marshall/lib/marshall_web/components/table_content.ex`, removed with the Mishka set by ADR-0161)
  and stepper (`marshall/lib/marshall_web/components/stepper.ex`, likewise removed)
  components. The first was inside an already conditional title element; the
  second tested a value already constrained to a string by its helper. Removing
  these redundant checks preserves behavior for valid inputs.
- The shared [ADR validator](../../../scripts/adr_validator.ex) used a type name
  now built into Elixir. Renamed it to `adr_record` and added a parser return spec.
- Lilly's Dialyzer analysis passed with zero warnings and no exclusions. Its
  production release built successfully and executed the inventory probe through
  the release launcher.
- Marshall's compilation and 22 tests plus two properties passed. The first
  Dialyzer run identified missing ExUnit entries in the test PLT and one upstream
  authentication typespec referencing `Ash.Resource.record/0`, omitted by Ash on
  OTP 29. Added ExUnit to the PLT. The exact upstream diagnostic is documented in
  [a narrow filter](../../../marshall/.dialyzer_ignore.exs), with unused-filter
  detection enabled. The published 2.17.3 archive matches the installed source;
  the [upstream fix](https://github.com/team-alembic/ash_authentication_phoenix/commit/9edd90969adbe91df7a3ee652004d08a463f555e)
  is on the 3.0 release-candidate branch. Other unknown types and all application
  findings still fail the gate. Remove this filter when a stable dependency
  release includes the corrected type.
- Full Marshall precommit passed after those corrections: 22 tests, two
  properties, compiler warnings as errors, and Dialyzer with the one documented
  upstream diagnostic filtered and no unused filters. Initial third-party
  dependency compilation emitted upstream deprecation/type diagnostics; the
  repository application compilation gate passes without disabling compiler type
  analysis.
- The shared ADR and exact-runtime checks and root formatter check pass under
  the pinned runtime. There are no broad Dialyzer warning exclusions or
  `--ignore-exit-status` flags. The runtime/type-analysis milestone and Lilly
  inventory foundation are verified; the full platform remains incomplete.

## Remaining platform obligations

This section records the scope at the toolchain milestone. The subsequent
[capacity admission review](2026-09-15-capacity-admission.md) records progress on
transactions, Cedar and audit/logging; the overview has the current status.

Lilly VM execution, capacity transactions, Cedar, encryption/audit, networking, the terminal
protocol, multi-node tests and real-KVM verification remain open. The request for
two x86-64 KVM hosts is pending while implementation continues locally.
