# Mila

Mila is the Overalls client for iOS and Android, with a Linux desktop build for
testing. It manages machines over one SSH connection to a deployment's Porsche
gateway, signs in by approving a per-deployment device key in the browser, and
opens `overalls://` links.

```sh
devenv shell
mila-check                                   # format, analyze and test everything
cd mila/app && flutter run -d linux --dart-define=MILA_DEMO=true   # in-memory demo
nix build .#tool-mila-linux                  # Linux bundle
```

iOS and Android builds run outside Nix with Flutter 3.47.0 (`flutter build ipa`,
`flutter build appbundle`) after `devenv shell` has linked the patched dartssh2.

See [AGENTS.md](AGENTS.md) for the layout and working rules, and
[ADR-0220](../docs/architecture/decisions/0220-mila-client-over-porsche-ssh.md)
for the design.
