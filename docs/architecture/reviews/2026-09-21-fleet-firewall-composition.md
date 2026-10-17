# Fleet firewall composition recovery

## Scope

Review the production failure in which Dungarees' authenticated `fleet0` tunnel
could reach Overalls by ICMP but could not reach Marshall's fleet listener on
`10.90.0.1:5443`. This review covers the interaction between ADR-0075's broad
reviewed-source policy and the destination-scoped rules owned by the fleet
network module.

## Findings

- **Resolved, high:** `fleet-firewall.nix` used `lib.mkForce` for
  `extraInputRules` and `extraCommands`. On a complete fleet host this discarded
  `fleet-network.nix`'s interface, source, destination and port-specific Marshall
  admission rule. The WireGuard handshake and bidirectional ICMP remained
  healthy while the NixOS input chain dropped TCP 5443, leaving remote Lilly in
  `connecting` and preventing updater health verification.
- ADR-0075's broad public-source grants and suppression of global port, range and
  ordinary service-rule contributions remain unchanged. The authenticated fleet
  transport now contributes its interface/source/destination rules at the same
  explicit force priority. Other service rules remain suppressed.

## Changes

- `nix/domains/system/fleet-network.nix` marks its authenticated internal transport rules
  as an explicit exception only when the authoritative fleet perimeter is
  enabled; standalone consumers retain normal NixOS firewall composition.
- The `fleet-network-source-access` code contract continues to require suppression
  of ordinary service contributions while allowing explicit authenticated
  transport rules at force priority.
- `nix/verification/tests/evaluation/fleet-firewall.nix` composes the real fleet firewall and
  fleet network modules for both nftables and iptables, and requires both the
  broad reviewed-source rule and the narrow TCP 5443 rule to survive while an
  ordinary source-unrestricted TCP rule remains suppressed. Standalone cases
  verify normal rule composition remains available without the fleet perimeter.

## Verification

- `nix build .#checks.x86_64-linux.fleet-firewall-configuration --no-link`
  passed in a clean detached worktree containing only this change.
- `nix build .#checks.x86_64-linux.module-configuration --no-link` passed in
  the same worktree.
- Full `kittensDeployment` builds for both `overalls` and `dungarees` passed,
  covering complete host composition and the NixOS firewall assertions.
- Before the fix, production evidence showed a fresh authenticated WireGuard
  handshake and successful bidirectional ICMP, an active Marshall listener on
  `10.90.0.1:5443`, no matching NixOS firewall rule, and failed TCP admission.

## Remaining Work

- Deploy the corrected configuration serially, verify Dungarees reaches
  Marshall over `fleet0`, complete updater health verification, and confirm the
  expected nftables rule is present. ADR-0075 remains `partial` because its
  independent live Tailscale acceptance is still pending.

## Architecture Impact

ADR-0075 is affected but not changed or superseded. The patch reconciles its
existing host-firewall and fleet-overlay boundaries; no protocol, persistence,
secret-custody or authorization decision changes.
