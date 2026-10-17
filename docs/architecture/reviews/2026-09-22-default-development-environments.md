# Default development environments

- Date: 2026-09-22
- Scope: default `jq`, `direnv` and `devenv` installation on fleet hosts, the
  NixOS guest image and the Ubuntu guest image
- ADRs: ADR-0094 (new), ADR-0076 (superseded), ADR-0068 and ADR-0073

## Scope and evidence

The review covers the shared fleet host profile, both guest image definitions,
the Ubuntu authenticated package lock and offline builder, evaluation checks and
the real guest command-presence probe. The user explicitly authorized the new
defaults and then added `jq` on 2026-09-22. Both guest images already contained
and checked `jq`; the follow-up changes only the shared fleet host profile.

## Findings

1. **ADR-0076 requires replacement, not an evidence-only edit.** Its reviewed
   package set and Ubuntu source boundary excluded these tools. ADR-0094 carries
   forward its toolset and image boundaries, respects ADR-0093's later guest SSH
   decision, and records the newly authorized packages and narrow Ubuntu
   exception. ADR-0076 is retained as implemented history and marked superseded.
2. **Ubuntu needs one bounded source exception.** The authenticated Ubuntu
   snapshot supplies `direnv` but not `devenv`. The builder therefore copies
   only the pinned Nixpkgs `devenv` runtime closure, loads its registration into
   the guest Nix database and anchors it with a GC root. This avoids first-boot
   networking and preserves ADR-0068's Ubuntu-package rule for every other
   application.
3. **The change does not alter runtime authority or isolation.** All three
   commands are idle executables. No service, listener, credential, guest
   address, SSH path or Podman setting changes. Existing exact-artifact manifests
   and manifest-derived disk sizing continue to govern the larger images.

## Decisions and open questions

The Ubuntu exception is limited to `devenv`; `jq` and `direnv` remain locked to
the Ubuntu snapshot. There are no unresolved design choices.

## Verification performed

- `elixir scripts/check_adrs.exs` passed for all 92 decisions after integration
  with ADR-0093.
- `node scripts/check_contracts.mjs format` passed for 92 `CONTRACTS` files,
  1,452 native notes and 1,796 covered maintained source files.
- The `guest-toolset`, `guest-ssh`, `ubuntu-guest-unit` and
  `storage-configuration` Nix evaluation checks passed.
- Direct evaluation confirmed all three packages in the enrolled and base
  configurations for Overalls and Dungarees.
- Both default guest images built successfully. Read-only ext4 inspection of the
  Ubuntu result confirmed the locked `/usr/bin/direnv`, the
  `/usr/local/bin/devenv` link and target closure, its GC root and the populated
  Nix database.
- `devenv shell -- prek run --all-files` passed every structured-logging, Ruff,
  Ruff-format and ty hook; the changed Elixir guest probe also passed
  `mix format --check-formatted`.
- The `zfs-guest` and `ubuntu-guest` real Firecracker checks could not execute in
  this VM: evaluation requires the `nested-kvm` system feature, while the builder
  advertises only `kvm` and `nixos-test`. This is not counted as guest runtime
  acceptance.

## Follow-up work

Run the updated `zfs-guest` and `ubuntu-guest` Firecracker checks on a builder
with the `nested-kvm` feature before changing ADR-0094 from partial to
implemented.
