# ADR-0241: SOPS-delivered automatic Tailscale joining

- ID: ADR-0241
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: host profile, secrets inventory, Tailscale
- Supersedes: none
- Superseded by: none

## Context

[ADR-0075](0075-fleet-overlay-and-source-access.md) runs the Tailscale daemon on
every fleet host but forbids an embedded authentication key, so every new or
reinstalled host waits for an operator to run `tailscale up` and approve a login
link. Reprovisioning Dungarees and installing Panterloons on 2026-10-20 needed
that step on each host. The operator asked for automatic enrollment and supplied
a Tailscale authentication key for SOPS custody.

## Decision

The operator directed this on 2026-10-20.

- One shared SOPS document, `secrets/fleet-tailscale.enc.json`, holds
  `TAILSCALE_AUTH_KEY` (SecretSpec project `overalls-tailscale`). Like any host
  document, it is sealed to the recovery users and to every host whose
  declaration names the `fleet-tailscale` credential.
- An enrolled host naming that credential decrypts the key into
  `/run/overalls-secrets/tailscale/auth-key` and sets
  `services.tailscale.authKeyFile`. The upstream `tailscaled-autoconnect` unit
  runs after `overalls-secrets-tailscale.service` and presents the key only
  while the daemon needs a login, so a host already in the tailnet is unchanged.
- A base system holds no host credentials and still joins only through an
  explicit operator action.
- The key never enters the Nix store, the repository in plaintext, or logs.

## Alternatives

- **Operator `tailscale up` per host (ADR-0075):** works, but repeats a manual
  login on every installation and reinstallation.
- **Key in the base installation:** a base system has no enrolled identity, so
  the key could only arrive as plaintext through the installer.

## Consequences

- An enrolled host rejoins the tailnet after a reinstall or a lost login
  without operator interaction.
- Compromise of any recipient host exposes the key; its Tailscale reach is
  bounded by the key's own settings (reusability, expiry, tags), which the
  operator manages in the Tailscale console. Rotating it is an
  `encrypt fleet-tailscale --replace` followed by the ordinary update.
- An expired or revoked key leaves the autoconnect unit retrying; the host is
  otherwise unaffected and remains reachable by its other paths.

## Invariants and verification

- `enrollment-configuration` checks that a host with the credential gets the
  runtime key path, the bundle output and the unit ordering, and that a host
  without it gets no key, bundle or autoconnect unit.
- `secrets check` confirms the document's recipients.

## Implementation evidence

- [`profile.nix`](../../../nix/platform/hosts/profile.nix) (`fleet-tailscale-mesh`).
- [`enrollment-configuration.nix`](../../../nix/verification/tests/evaluation/enrollment-configuration.nix).
- Overalls and Salopettes declare the credential.
- Remaining gap: no machine test performs a real join; the first production
  join is a reinstalled host.

## Open questions

None.

## Related decisions

Amends [ADR-0075](0075-fleet-overlay-and-source-access.md) (automatic joining
for enrolled hosts). Uses the host-document custody of
[ADR-0233](0233-fleet-addresses-from-sops.md).
