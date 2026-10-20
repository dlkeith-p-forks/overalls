# ADR-0189: Publish fleet store paths to Overalls Cachix

- ID: ADR-0189
- Date: 2026-10-17
- Status: accepted
- Implementation: partial
- Components: Overalls and Dungarees NixOS hosts, Cachix
- Supersedes: none
- Superseded by: none

## Context

The fleet builds closures that are consumed by hosts and guests. The Nix read
configuration in ADR-0188 does not publish newly built paths. Cachix's
`watch-store` agent can publish paths continuously using a scoped cache token.

## Decision

Enable `services.cachix-watch-store` on Overalls and Dungarees with cache name
`overalls`. Deliver `CACHIX_AUTH_TOKEN` through the existing host-recipient SOPS
bundle at `/run/overalls-secrets/cachix/token`; the agent starts only after that
bundle is prepared. The token is never embedded in Nix or an image.

## Alternatives

Manual `cachix push` is incomplete and operator-dependent. A shared plaintext
token or image-baked token violates host secret custody. Publishing from guests
would widen credential scope and is unnecessary.

## Consequences

Successful store paths become available to all configured readers. The agent
adds Cachix availability and token validity as operational dependencies; failed
uploads are retried by the service without affecting local builds.

## Invariants and verification

Both fleet hosts enable the agent for exactly the `overalls` cache, require the
SOPS preparation unit, and expose no token through evaluated configuration. Host
inventory recipients include the encrypted document. Module evaluation and the
secret-custody checks verify structure; live publication remains unverified.

## Implementation evidence

Host declarations are in [Overalls](../../../fleet/roles/control-plane/configuration.nix)
and [Dungarees](../../../fleet/hosts/dungarees/configuration.nix), with the encrypted document at
`secrets/overalls-cachix.enc.json` and inventory
entries in both `host.json` files. The NixOS module supplies the watch agent.

## Open questions

None.

## Related decisions

[ADR-0188](0188-signed-overalls-cachix-substitution.md) defines the read trust
boundary and [ADR-0032](0032-ssh-derived-age-identities.md) defines host-secret
custody.
