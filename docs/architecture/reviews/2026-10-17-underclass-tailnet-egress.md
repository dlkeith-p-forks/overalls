# Underclass tailnet exit-node egress review (2026-10-17)

## Scope

This review covers the change that implements
[ADR-0185](../decisions/0185-underclass-tailnet-exit-egress.md). The change routes
Underclass provider traffic, and only that traffic, through the user's
Australian Mac Mini exit node. The base is `origin/main` at `5910bdd79`. Changed
areas:

- `services.underclass.egress` in `nix/domains/system/underclass.nix`;
- update consumers and health units in `nix/domains/system/auto-update/default.nix`;
- stage-1 enablement in `nix/platform/hosts/profile.nix`;
- the `underclass-configuration` and `enrollment-configuration` evaluation
  checks;
- the new `underclass-egress` machine check.

The review dimensions are isolation, authorization, network transport, deployment
health, recovery and verification.

## Findings

1. **Exit-node selection is node-wide (design input, resolved).** Selecting
   `mac-mini` on a host's main `tailscaled` would move every service's egress
   to Australia. The change uses a second userspace node instead. The machine
   check asserts that the host has no `tailscale0` link, still has exactly the
   three default `ip rule` entries, and that the host's own traffic keeps its
   direct source address.
2. **A userspace proxy with no exit node dials directly (high, mitigated).** If
   the preference is absent, the egress proxy leaks from the host's own address.
   The privileged start gate re-asserts the exit node and refuses to start
   without it. The check covers refusal before login and re-assertion after the
   preference is cleared.
   - Residual gap: root clearing the preference while Underclass is running
     leaks until the next start. This is recorded in ADR-0185 as an operator
     action, not an isolation boundary.
3. **Proxy bypass by Underclass code (medium, mitigated).** The environment
   proxy alone relies on every client in Underclass honouring it. The cgroup
   filter `IPAddressDeny=any` / `IPAddressAllow=localhost` makes bypass
   impossible. The check runs a probe inside `underclass.service`'s cgroup:
   direct HTTPS fails, and proxied HTTPS succeeds with the exit node's address.
4. **Exit node loss (high, verified fail-closed).** Stopping the exit node's
   `tailscaled` makes proxied HTTP and HTTPS fail. The destination's access log
   contains no request from the host's address, both before and after an
   Underclass restart while the exit node is offline.
5. **Deployment health ordering (high, addressed by staging).** Underclass is an
   updater health unit. Requiring an exit node before the egress node is logged
   in would roll back the deployment. The profile ships stage 1 only, and the
   enrollment check asserts that `exitNode` is null. Stage 2 is a separate
   change.
6. **LAN access through the exit node (design input).** The user enabled "allow
   LAN access" on the Mac Mini. That setting affects only a client using an exit
   node, so it is inert on the exit node itself. The egress node keeps
   `--exit-node-allow-lan-access=false`. An early test run sent its destination
   on the host's own subnet and timed out, which showed the egress node handles
   local subnets differently. The final check uses a routed public-style address
   (`203.0.113.10`), matching provider APIs.
7. **DNS location.** The proxied name `upstream.test` resolves only at the exit
   node (the host's own resolver fails it), and the proxied request succeeds.
   This shows the egress node resolves names at the exit node.

No accepted decision is contradicted. ADR-0102's loopback listener,
independent pools, credential boundaries and Tailscale Serve publication are
unchanged.

## Checks run

On 2026-10-17, on the dev host, from base `5910bdd79` plus this change:

- `nix build .#checks.x86_64-linux.underclass-configuration`: all 11 cases
  passed, including `egressOptIn`, `egressNodeIsolated`, `egressRouted` and
  `egressNodeRequired`.
- `nix build .#checks.x86_64-linux.underclass-egress`: all 11 subtests passed;
  the test script finished in 87.71 s.
- Both `overalls` and `dungarees` evaluate `underclass-egress.service`. Port 1055
  was free on both hosts.

Earlier iterations of the machine check failed on test-harness issues:

- IPv6 source addresses (the nodes now match the IPv4-only fleet);
- missing exit-node DNS;
- a local-subnet destination;
- reboot driver usage.

None of these failures was a module defect.

## Unresolved and follow-up

- Log in both egress nodes, check tailnet policy for the new identities, then
  activate stage 2.
- Observe one provider request from the Mac Mini's address on each host.
- Decide on key expiry and tagging for the egress identities, and whether a
  dedicated "exit node offline" alert is worth adding.
- The machine check does not cover the production Tailscale control plane, a
  macOS exit node, provider TLS or throughput.
