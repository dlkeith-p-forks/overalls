# ADR-0227: Flutter toolchain, patched dartssh2 overlay and Mila checks in Nix

- ID: ADR-0227
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: Mila, Nix
- Supersedes: none
- Superseded by: none

## Context

Mila must build reproducibly with the repository's pinned inputs. Its SSH
library, dartssh2, lacks OpenSSH host certificates, which Porsche presents
exclusively ([ADR-0124](0124-unified-ssh-host-ca.md)). Hegel's Dart binding
downloads its engine at build time, which the Nix sandbox forbids.

## Decision

1. Mila builds with `buildNixpkgs`' `flutterPackages.v3_47` (Flutter 3.47.0,
   Dart 3.13.0) in Nix and devenv alike.
2. dartssh2 4.1.0 is fetched from pub.dev by SHA-256 and patched by the overlay
   `nix/platform/dartssh2.nix` with
   `nix/platform/patches/dartssh2-host-certificates.patch`. `mila_transport`
   depends on it as the path `.nix/dartssh2`, linked to that store path by
   devenv and by every Nix build; nothing resolves dartssh2 from pub.dev. The
   upstream async `SSHIdentity` already supports hardware signers, so the
   patch covers host certificates only.
3. Hegel's engine is pinned by `nix/verification/hegel/libhegel-dart.nix` (the
   release and SHA-256 hegel 0.3.0 checks) and supplied through a pubspec
   `hooks.user_defines` entry.
4. Tests resolve packages offline from a pub cache made of the locked store
   paths, against committed `pubspec.lock.json` files that `mila-lock-sync`
   keeps equal to `pubspec.lock`.
5. Checks: `mila-core`, `mila-transport`, `mila-test` (analysis, tests and
   goldens), `mila-lock-sync` and the `mila-porsche` machine test. Packages:
   `tool-mila-linux`, `tool-mila-demo`, `tool-mila-probe`. iOS and Android
   release builds happen outside Nix with the same Flutter version.

Authorization: the approved Mila plan (2026-10-18), including the overlay.

## Alternatives

- **Vendoring dartssh2.** Rejected: the overlay keeps upstream pinned and the
  delta reviewable as one patch.
- **A git fork dependency.** Rejected: pub git sources need network and hash
  bookkeeping outside the existing lock flow.

## Consequences

Upgrading dartssh2 means re-pinning the archive and rebasing one patch.
Running sshd in the sandbox needs `nss_wrapper`, because the build user has no
login shell.

## Invariants and verification

- The patched library negotiates certificates only when asked, verifies the
  exchange signature with the certified leaf key and accepts a host only if
  the caller's blob callback does (`nix/platform/patches/CONTRACTS`).
- Lock JSON equals `pubspec.lock` for every package (`mila-lock-sync`).

## Implementation evidence

[`nix/domains/artifacts/mila/default.nix`](../../../nix/domains/artifacts/mila/default.nix), [`nix/platform/dartssh2.nix`](../../../nix/platform/dartssh2.nix), the
patch, [`nix/verification/hegel/libhegel-dart.nix`](../../../nix/verification/hegel/libhegel-dart.nix), [`flake.nix`](../../../flake.nix) checks and
packages, and the devenv `mila:dartssh2` task, `mila-check` script and
`mila-dart-format` hook. All Mila checks and packages build locally; the
checks carry `meta.ci`, so CI selects them. Gaps: `mila-porsche` is blocked by
the pre-existing Porsche release failure; there is no Android Nix build.

## Open questions

Whether an Android Nix build (androidenv, JDK 17) is worth its cache cost.

## Related decisions

[ADR-0124](0124-unified-ssh-host-ca.md),
[ADR-0191](0191-elixir-hegel-property-verification.md),
[ADR-0220](0220-mila-client-over-porsche-ssh.md),
[ADR-0228](0228-strict-host-certificates-in-mila.md).
