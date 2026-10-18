# Mila guidance

Mila is the Overalls client for iOS, Android and Linux (Linux is for testing).
Read [ADR-0220](../docs/architecture/decisions/0220-mila-client-over-porsche-ssh.md)
to [ADR-0228](../docs/architecture/decisions/0228-strict-host-certificates-in-mila.md)
and [CONTRACTS](CONTRACTS) before changing it.

## Layout

| Path | Responsibility |
| --- | --- |
| `packages/mila_core` | Pure Dart: command encoding, reply decoding, routes, host certificates, state machines. |
| `packages/mila_transport` | Pure Dart: Porsche SSH connector, device keys, trust pinning, `mila-probe`. |
| `app` | Flutter presentation, platform channels (`MilaPlatform`), localization. |

## Working rules

- Enter `devenv shell`; it pins Flutter 3.47.0 and links the patched dartssh2 at
  `packages/mila_transport/.nix/dartssh2`. Never point dartssh2 at pub.dev.
- Run `mila-check` (format, analyze with `--fatal-infos`, tests for all three
  packages). The Nix checks are `mila-core`, `mila-transport`, `mila-test`,
  `mila-lock-sync`; the machine test is `mila-porsche`.
- After changing dependencies, regenerate each `pubspec.lock.json` with
  `yq -o=json pubspec.lock`; `mila-lock-sync` refuses a stale one.
- Keep types strict: no `dynamic`, no unchecked casts of external data; decode
  through the validating decoders in `mila_core`.
- Presentation follows The Monospace Web (ADR-0226): colour literals only in
  `app/lib/ui/tokens.dart`, text glyphs only from `Glyph`, state as text.
  Use the [monospace-web skill](../.agents/skills/monospace-web/SKILL.md).
- User-facing text lives in `app/lib/l10n/app_en.arb` with every locale
  translated; follow the [localization skill](../.agents/skills/localization/SKILL.md).
- Property tests use pub.dev `hegel`; its engine comes from Nix
  (`nix/verification/hegel/libhegel-dart.nix`) in sandboxed builds.
- Wire formats shared with Elixir have fixtures under `protocol/test/fixtures`;
  change both sides and the fixture together.
- The iOS and Android native code cannot be built in Nix; say so when it is
  changed without a device build.
