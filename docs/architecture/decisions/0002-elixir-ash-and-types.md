# ADR-0002: Elixir, Ash domains and type checking

- ID: ADR-0002
- Date: 2026-09-15
- Status: accepted
- Implementation: partial
- Components: Marshall, Lilly, toolchain
- Supersedes: none
- Superseded by: none

## Context

Marshall is an Elixir/Phoenix application. The user requires Ash domain-driven
modeling, the latest stable Elixir, static type checking, Dialyzer and
property-based tests, with Elixir also selected for Lilly.

## Decision

Use separate Marshall and Lilly Elixir applications/releases in this monorepo.
Model business boundaries using Ash domains and resources, with explicit Ash
actions rather than bypassing the domain layer. Use typespecs on public APIs,
protocol payloads and resource-boundary helpers; let compiler analysis and
Dialyzer catch inconsistencies, and validate external data at runtime.

Pin the latest stable Elixir and compatible OTP when implementing the toolchain
milestone, recording versions in reproducible development/build configuration.
The planning research identified Elixir 1.20.4 as the target on 2026-09-15; verify
the stable release again when pinning. Native gradual typing is not a substitute
for runtime validation or a promise that all programs are statically proven.
Add Dialyxir/Dialyzer gates to both applications, compile with warnings as errors,
and use property-based tests for domain invariants.

## Alternatives

Keeping the starter's loose version constraint would not make builds
reproducible. Typespecs alone do not run a checker. A different Lilly language
would introduce an additional implementation stack despite the chosen Elixir
release model. Runtime validation alone misses useful compile-time feedback.

## Consequences

Framework and native dependency compatibility must be checked at upgrades.
Dialyzer requires maintained PLTs and triaged findings; suppressions need narrow,
documented reasons. Ash-generated code still needs checked boundary contracts.

## Invariants and verification

- Development, CI and production builds use an explicitly recorded compatible
  Elixir/OTP pair; latest-stable adoption is verified, not assumed.
- Compilation and Dialyzer pass for both releases once those gates are installed.
- Malformed external inputs cannot be made safe merely by attaching a typespec.
- Property tests cover behavior and invariants rather than restating functions.

## Implementation evidence

[Mix project](../../../marshall/mix.exs) supplies Phoenix/Ash and a compiler
warnings-as-errors precommit gate. [Accounts domain](../../../marshall/lib/marshall/accounts.ex)
and [User resource](../../../marshall/lib/marshall/accounts/user.ex) establish
initial Ash modeling. The shared [validator](../../../scripts/adr_validator.ex)
has boundary specs and [property tests](../../../marshall/test/architecture/adr_validator_test.exs).

[Nix toolchain](../../../nix/packages/toolchain.nix) and
[version pins](../../../.tool-versions) select Elixir 1.20.4/OTP 29.0.6;
[devenv](../../../devenv.nix) uses them. The Mix project requires Elixir 1.20.4,
includes Dialyxir and invokes both a
[runtime version check](../../../scripts/check_toolchain.exs) and Dialyzer in
precommit. The [toolchain review](../reviews/2026-09-15-toolchain.md) records the
successful runtime build, compiler/test gates and Dialyzer validation, including
one precise upstream typespec exclusion with unused-filter detection.
ADR-0065 upgrades the authentication dependency and removes that obsolete exclusion;
unused-filter detection remains enabled.

[Lilly](../../../lilly/mix.exs) has the same version requirement and passing gates,
plus typed host inventory boundaries and a tested independent release.
[Compute admission](../../../marshall/lib/marshall/compute/admission.ex),
[shared protocol](../../../protocol/mix.exs) and
[control client](../../../lilly/lib/lilly/control/client.ex) now apply those gates
to typed, runtime-validated boundaries. [ADR-0012](0012-provisioner-control-transport.md)
records their tests and compatibility rules. Execution, recovery and terminal
boundaries now participate in the same compiler/property/Dialyzer gates; the
[fleet review](../reviews/2026-09-16-nixos-fleet.md) records the latest application
gates and real nested-guest acceptance. These checks do not prove physical-host
performance or complete static correctness.

Both consumer precommit aliases now use `dialyzer --force-check`: local protocol
changes can leave `mix.lock` unchanged, and Dialyxir's quick cache check otherwise
misses new modules. [ADR-0014's review](../reviews/2026-09-15-image-address.md)
records the reproduced stale-cache finding and the verified fix.

## Open questions

The selected Cedar bridge is validated under ADR-0010. Continue validating native
dependencies as execution components are added. Choose CI caching and a
documented version-update cadence when CI is introduced.

## Related decisions

[ADR-0001](0001-architecture-governance.md),
[ADR-0009](0009-assurance-and-testing.md).
Version reference: [Elixir 1.20.4 release](https://github.com/elixir-lang/elixir/releases/tag/v1.20.4).
