# Standalone nix-compact extraction

Date: 2026-09-21

## Scope and decision

The user requested a public `ghuntley/nix-compact` repository, a local
`~/src/nix-compact` checkout initialized with devenv, flake consumption and a move
of the existing implementation. They selected public visibility and supplied
Geoffrey Huntley `<ghuntley@ghuntley.com>` as the commit identity.

[ADR-0087](../decisions/0087-compact-nix-build-logs.md) retains its logging,
build-result, privacy and output-budget rationale. This extraction changes source
ownership and dependency wiring, not those decisions. The C++ implementation and
test sources were checked byte-for-byte against the original implementation's
Git blobs before publication. NixOS/devenv integration is generalized upstream;
the consumer retains its established option defaults and package inputs.

## Artifacts

- Public repository: [ghuntley/nix-compact](https://github.com/ghuntley/nix-compact).
- Local independent Git/devenv project: `/home/ghuntley/src/nix-compact`.
- Pinned public source: [7b420585](https://github.com/ghuntley/nix-compact/tree/7b4205856cd01b2c356197689daabcca19baa7af).
- [Public flake](https://github.com/ghuntley/nix-compact/blob/7b4205856cd01b2c356197689daabcca19baa7af/flake.nix)
  exports packages, an app, development shell, opt-in NixOS module, devenv module,
  package/check factories and four checks. Supported Nix/platform combinations
  fail explicitly rather than silently selecting another version.
- [Consumer flake](../../../flake.nix), [devenv inputs](../../../devenv.yaml),
  [package adapters](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/nix/domains/artifacts/nix-compact/default.nix) and
  [NixOS adapter](../../../nix/domains/system/nix-compact.nix) use the pinned source.
- [Lock resolver](../../../nix/domains/artifacts/nix-compact/source.nix) preserves direct
  imports used by existing fixtures, resolving the root lock's immutable GitHub
  revision. Normal flake outputs pass the dependency explicitly.
- [Guide](../../development/nix-build-logs.md) points to maintained public documentation.
  Historical completion-review implementation links remain pinned to their
  original reviewed revision. No logger/archive/classifier/reader/Hegel source
  copy remains in the consumer.

## Standalone validation

Executed successfully in the standalone checkout:

- `devenv init`, followed by the pinned `devenv shell` and `nix develop`.
  Both development entry points select the patched executable and shared toolchain.
- `nix flake check --no-build --option allow-import-from-derivation false`.
- Native package build and `core`, `native`, `native-development`, and
  `configuration` checks. The C++ core and Hegel behavior are unchanged.
- Public GitHub flake invocation via `nix run github:ghuntley/nix-compact/<rev>`.
- GitHub Actions is configured with immutable action pins, flake evaluation,
  all four checks, package build and development-shell verification.

The first cold GitHub run exposed a warm-cache assumption: Hegel's lockfile was
read from a fetched derivation during evaluation. Hash-pinned Cargo vendoring
moves that work into fetching. The public development matrix now uses direct
immutable Nixpkgs snapshots rather than the consumer's IFD-based package wrapper.
Evaluation with IFD disabled and both local native variants pass after that fix.
The consuming development package set remains unchanged and is tested through
the exported factories.

## Consumer verification

Final consumer check, lock-alignment, module, public devenv-import, architecture
and contract validation results are recorded at completion of this migration.
Live fleet activation is not part of this extraction; hosts consume the new pin
on their normal rebuild/activation. Remote protocol fixtures do not establish
physical-network availability.
