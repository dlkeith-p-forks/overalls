# ADR-0245: Underclass egress node tag

- ID: ADR-0245
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: Underclass, Tailscale, NixOS services
- Supersedes: none
- Superseded by: none

## Context

[ADR-0185](0185-underclass-tailnet-exit-egress.md) gives Underclass a dedicated
userspace Tailscale node (`underclass-egress.service`) that an operator joins
with `sudo underclass-egress up`. Joined that way, the node is owned by the
joining user, so tailnet policy cannot tell it apart from the operator's own
devices. The operator asked on 2026-10-20 that the Underclass Tailscale services
use the tag `underclass`.

## Decision

The operator directed this on 2026-10-20.

- `services.underclass.egress.tags` lists the egress node's Tailscale ACL tags,
  defaulting to `[ "tag:underclass" ]`.
- `underclass-egress up` and `underclass-egress login` always pass
  `--advertise-tags` with those tags; other subcommands pass through unchanged.
  Tags are set only on joining because `tailscale set` cannot change them.
- `underclass-tailscale-serve.service` publishes through the host's own
  Tailscale node, so it is not tagged; tagging it would retag the whole host.

## Alternatives

- **Tag the host node:** would change the identity and ACLs of every service on
  the host.
- **Apply tags in the start gate:** `tailscale up` must restate every non-default
  flag and may force re-authentication, which could stop Underclass at start.

## Consequences

- Tailnet policy can grant or restrict the egress node as `tag:underclass`.
- The tailnet policy must let the joining identity own `tag:underclass`, or
  joining is refused.
- A node joined before this decision keeps its user ownership until an operator
  joins it again (for example `sudo underclass-egress up --force-reauth`).

## Invariants and verification

- `underclass-configuration` checks the default tag and that the join command
  advertises it.
- The `underclass-egress` machine test asserts that the joined node carries
  `tag:underclass`. Its stand-in control server is headscale 0.28, which
  refuses client-requested tags on auth-key joins and takes tags only from the
  key, so the test joins through the raw socket CLI with a key tagged
  `tag:underclass`. Production uses Tailscale, which accepts `--advertise-tags`
  from an owner of the tag; the wrapper's flag is verified by evaluation only.

## Implementation evidence

- [`underclass.nix`](../../../nix/domains/system/underclass.nix) (`egress.tags`
  and the `underclass-egress` command).
- [`underclass.nix` evaluation](../../../nix/verification/tests/evaluation/underclass.nix)
  and the [`underclass-egress` machine test](../../../nix/verification/tests/machines/underclass-egress/default.nix).
- Remaining gaps: production egress nodes are retagged only when an operator
  joins them again, and no test joins Tailscale itself with the wrapper.

## Open questions

None.

## Related decisions

Amends [ADR-0185](0185-underclass-tailnet-exit-egress.md).
