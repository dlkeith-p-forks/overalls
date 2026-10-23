# ADR-0247: SOPS-held operator source grant

- ID: ADR-0247
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: fleet firewall, runtime firewall, fleet addresses, SOPS secrets
- Supersedes: none
- Superseded by: none

## Context

[ADR-0075](0075-fleet-overlay-and-source-access.md) originally granted Geoffrey
Huntley's personal IPv4 address access to every TCP and UDP listener on every
fleet host. On 2026-10-16 the user removed every personal address, so operators
reached hosts only through the tailnet. On 2026-10-20 the user asked for that
address to reach every fleet machine again, without its value appearing in the
public repository.

[ADR-0233](0233-fleet-addresses-from-sops.md) already keeps every fleet public
address in `secrets/fleet-addresses.enc.json`. Its runtime firewall chain admits
reviewed-source grants that name SOPS-delivered addresses, on both firewall
backends. The repository is public, and the address was committed in plaintext
in earlier history. Removing it from the current tree does not erase that history.

## Decision

The user's 2026-10-20 instruction authorizes this decision.

- Add the operator address as `GEOFFREY_HUNTLEY_IPV4` to the shared
  fleet-addresses SOPS document. Its logical name is `geoffreyHuntley` in
  [`fleet-addresses.nix`](../../../nix/policy/network/fleet-addresses.nix).
- Add a reviewed grant `geoffreyHuntley` with a required comment to
  [`allowed-hosts.nix`](../../../nix/policy/network/allowed-hosts.nix). The host
  profile maps every grant to `allowedHosts.*.addressFile`, so every enrolled
  fleet host that receives the document admits the source through the runtime
  chain. Its scope is the same as the other reviewed sources: all TCP and UDP
  ports, no other protocols.
- The address literal appears in no Nix expression, test, document or Nix store
  path. The current tree's earlier references were removed in this change.

## Alternatives

A static `address` literal would publish the value, which the user refused.
Tailnet-only access, the 2026-10-16 policy, was the arrangement the user asked
to replace. A grant limited to SSH ports was not requested; ADR-0234's
installer-source grant already covers that narrower case. Rewriting public
history to remove the old literal would require a force-push of trunk that
every other worktree and session depends on; it was not requested.

## Consequences

Every fleet host's listeners are reachable from this address without the
tailnet. A reassigned or compromised address gains that broad reach, so the
grant must be removed through the same SOPS document as soon as the address
changes owner. Source addresses are not identities: SSH, TLS and application
authentication still apply. A malformed value in the document closes the whole
runtime chain (ADR-0233), so a rotation must keep the value canonical. Hosts
without the document, such as base systems, do not admit the source.

## Invariants and verification

- `allowed-hosts.nix` contains only logical names, and every grant names an
  entry in `fleet-addresses.nix`. The `fleet-firewall-configuration` evaluation
  asserts both (`defaults`, `grantsNameFleetAddresses`).
- The repository's current tree contains no literal for this address.
- `nix run .#secrets -- check` accepts the re-encrypted document for its
  existing recipients.
- Live verification is still required: after activation, each host's
  `overalls-runtime` chain must hold the grant and a connection from the
  address must reach a host listener. Until then implementation is partial.

## Implementation evidence

The [fleet address policy](../../../nix/policy/network/fleet-addresses.nix) and
[source registry](../../../nix/policy/network/allowed-hosts.nix) name the
grant. The [host profile](../../../nix/platform/hosts/profile.nix) renders it
through the [fleet firewall module](../../../nix/domains/system/fleet-firewall.nix)'s
runtime chain. The [firewall evaluation](../../../nix/verification/tests/evaluation/fleet-firewall.nix)
checks that grants name SOPS-delivered addresses. No production packet-level
check has been recorded.

On 2026-10-23 the user authorized two further operator sources under this
decision, `geoffreyHuntleySecondary` (`GEOFFREY_HUNTLEY_SECONDARY_IPV4`) and
`geoffreyHuntleyTertiary` (`GEOFFREY_HUNTLEY_TERTIARY_IPV4`), after the operator's
egress address changed and the public origin became unreachable to them. They
use the same document, scope and runtime chain as `geoffreyHuntley`.

## Open questions

None.

## Related decisions

[ADR-0075](0075-fleet-overlay-and-source-access.md) defines the reviewed-source
registry; this record amends its 2026-10-16 removal of personal addresses.
[ADR-0233](0233-fleet-addresses-from-sops.md) defines the SOPS document and
runtime firewall chain used here. [ADR-0234](0234-installer-source-administrative-grant.md)
admits an installer source to administrative SSH ports only.
