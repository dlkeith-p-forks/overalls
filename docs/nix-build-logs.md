# Compact Nix build logs

The native implementation now lives in the public
[ghuntley/nix-compact](https://github.com/ghuntley/nix-compact) repository.
This repository consumes its pinned flake through `flake.lock` and `devenv.lock`.

- [Standalone usage and flake interfaces](https://github.com/ghuntley/nix-compact/blob/7b4205856cd01b2c356197689daabcca19baa7af/README.md)
- [Logging, retrieval, retention and replay manual](https://github.com/ghuntley/nix-compact/blob/7b4205856cd01b2c356197689daabcca19baa7af/MANUAL.md)
- [Implementation design and verification boundaries](https://github.com/ghuntley/nix-compact/blob/7b4205856cd01b2c356197689daabcca19baa7af/DESIGN.md)

`devenv shell` uses the standalone package factory with this repository's pinned
development package set. The fleet's NixOS adapter uses the stable host package
set. Both require the supported Nix version rather than silently using another
toolchain. Hosts enable compact output through the public
`programs.nix-compact.enable` option. Explicit NixOS package choices retain
ordinary precedence.

Existing package/check names remain available:

```sh
nix build .#nix-compact .#nix-compact-host
nix build .#checks.x86_64-linux.nix-compact-core \
  .#checks.x86_64-linux.nix-compact-native \
  .#checks.x86_64-linux.nix-compact-native-host \
  .#checks.x86_64-linux.nix-compact-configuration
```

The first three checks delegate to the standalone factories; configuration
checks remain here to verify this repository's compatibility adapter. Direct
imports used by existing NixOS fixtures resolve the external source from the root
flake lock through `nix/packages/nix-compact/source.nix`, without another source
pin. Update the flake and devenv inputs together when upgrading the dependency.

Native compact logging, stable `L#`/`D#` references, bounded retrieval, Hegel
properties and build-result guarantees are maintained upstream. No implementation
copy is retained here. See [ADR-0087](architecture/decisions/0087-compact-nix-build-logs.md).
