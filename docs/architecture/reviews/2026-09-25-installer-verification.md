# Installer verification improvement 002

This is the historical verification record for the fingerprint implementation at
`18761e4f`. [ADR-0124](../decisions/0124-unified-ssh-host-ca.md) supersedes that
model. The [CA review](2026-09-25-unified-ssh-host-ca.md) records the adapted
properties and native installer assertions; the execution below does not verify
the later CA implementation.

## Scope and architecture impact

The verification campaign preserves ADR-0118's operator-authenticated fingerprint,
strict management SSH and refusal semantics. ADR-0046's Porsche/Marshall authority
and the retained client-account requirements of ADR-0096/ADR-0110 remain unchanged.
No production API, schema, configuration option or domain boundary changes.

The generated installer properties vary canonical and malformed SHA256 pins,
plain/hashed hosts, conflicting and revoked entries beside existing matching
trust, entry order and trailing newlines. Malformed scans occur before and after
valid keys. Refusal must preserve the prior known_hosts, installed CLI and SSH
configuration and skip account proof. OpenSSH performs real key parsing; artifact
delivery and account execution are controlled property-test fixtures.

The exported `installer-trust` NixOS check boots separate control and client
machines with runtime-generated credentials. Marshall serves the real installer,
packaged Lyra and digest over verified HTTPS. Porsche proves a registered key
against actual Marshall/PostgreSQL authority. It exercises missing pin refusal,
first install, hashed repeat install, conflicting/revoked trust and retained client
state. The client uses an ordinary local account whose name differs from the
Marshall guest username. No guest is provisioned; the installer's final guest SSH
fails deliberately after account configuration. The test asserts completed configuration events, saved settings, the account
profile and registered identity directly and independently performs strict proof.

## Validation

- `MIX_TEST_PARTITION=verify002 mix test test/marshall_web/kittens_installer_test.exs`
  passed 15 checks (3 properties, 12 tests), seed 381931, in the pinned
  development shell. The generated trust-refusal properties passed.
- `nix eval .#checks.x86_64-linux.installer-trust.drvPath --raw` passed.
- `nix build .#checks.x86_64-linux.installer-trust --no-link --max-jobs 2 -L`
  passed, including the composed driver's type and lint checks. The two-machine
  Linux installer-trust check passed in 45.93 seconds with actual KVM-backed NixOS
  machines. The exact tested derivation is
  `/nix/store/wg7x10axwz93al61rbhj1121mjn87hfw-vm-test-run-kittens-installer-trust.drv`.
  It tested this improvement on base
  `253cdcaa1e7b3c8e7a2039583cbc30d8f6ba1e14`; subsequent evidence/receipt edits do
  not change its runtime assertions.
- Marshall's full suite reported 1016 passed (87 properties, 929 tests), plus two
  explicit host/capacity exclusions. The pinned Elixir 1.20.4 formatter counts
  passed checks separately from exclusions; distributed checks were included,
  seed 961492.
  Full `mix precommit` passed, including browser/JavaScript/type checks and forced
  Dialyzer with zero errors and zero unnecessary skips.
- `devenv shell -- prek run --all-files` passed Python formatting, linting and
  type checking plus logging/HLDD hooks. ADR structure, HLDD references, generated
  options, coverage and views, and the Nix `hldd` check passed before final
  execution-evidence receipts were recorded.

## Contract review and remaining gaps

The trust renderer and script contracts, strict Lyra proof, canonical key identity,
gateway custody, real-package fixture and documented evidence scope were reviewed.
No contract changes weaken trust or substitute a mocked management service in the
machine journey. Synthetic keys and gateway credentials remain private fixture
state; only public keys and fingerprints cross test-machine setup boundaries.

Native macOS, arbitrary existing local SSH configurations, production rollout and
the final guest connection remain outside this focused check. Existing Audi fleet
journeys provide their own guest evidence. ADR-0118 stays accepted and partial.
