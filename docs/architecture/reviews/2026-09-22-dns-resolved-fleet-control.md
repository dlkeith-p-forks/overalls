# DNS-resolved fleet control and production Audi certificates

## Scope

This review covers removal of the Overalls and Dungarees `/etc/hosts` aliases
for `overalls.dev`, the replacement route to Marshall's authenticated fleet API,
same-provider-subnet routing for Audi's Overalls address, and promotion of both
Audi deployments from the Let's Encrypt staging issuer to production. It also
records the live NixOS and Ubuntu OSS-profile endpoint exercise that exposed the
routing defects.

## Findings

- **Resolved, high — hidden control-plane routing:** removing the aliases made
  Audi resolve `overalls.dev` to its public address, while Marshall listened only
  on loopback and the retired overlay address. Control exchange failed and Audi
  withdrew guest DNS records. This was an implementation defect in the deployed
  fleet path, not an authentication bypass. ADR-0095 replaces the hidden alias
  with a source-restricted systemd socket relay that binds only
  `136.243.69.55:5443`, preserves TLS bytes, and forwards to Marshall's existing
  `127.0.0.1:5443` listener. Marshall remains the TLS and service-token authority.
- **Resolved, high — provider-subnet neighbour discovery:** Dungarees could not
  reach the Overalls Audi address `136.243.69.37` directly and returned `No route
  to host`. The reviewed host declaration now routes that address as a `/32`
  through provider gateway `136.243.69.1`, matching the existing route for the
  Overalls primary address. ADR-0095 and the `public-service-peer-routing`
  contract make this provider behavior explicit.
- **Resolved in configuration, medium — staging trust:** both Audi roles had
  completed staging issuance but still selected the staging ACME directory and
  a staging-only CA bundle. They now select Let's Encrypt's production directory
  and the system public CA bundle. Live production issuance and ordinary HTTPS
  validation are deployment acceptance checks, not established by evaluation.
- **Resolved, high — updater rejected a newer enrollment receipt:** Dungarees'
  first activation reached resource preflight, where a retained ADR-0050 journal
  compared the whole enrollment receipt and rejected its legitimately newer
  authenticated revision as storage drift. Replaying the journal would also
  have overwritten that revision with the older journal copy. Resource replay
  now validates only the nested storage evidence, preserves the current revision,
  rejects malformed receipt shapes, and reports the reviewed closed failure
  reason instead of generic `operation_failed`. This was an implementation
  defect in recovery behavior; it does not relax storage or native GUID checks.
- **Confirmed — authorization boundary:** ADR-0075's reviewed-source firewall
  limits access to the relay, but source address is defense in depth only. The
  relay does not terminate TLS, inspect credentials, bind a wildcard address, or
  expose Marshall's plaintext internals. Existing Marshall authentication and
  private-CA verification remain mandatory.
- **Confirmed — guest publication path:** Marshall endpoint policy was changed
  through the actor-authorized ingress API rather than direct database mutation.
  Both OSS-profile guests served their distinct responses locally and through
  Audi under staging TLS before production promotion.

## Affected decisions

- [ADR-0095](../decisions/0095-dns-resolved-fleet-control-origin.md) is new and
  accepted/implemented after live deployment acceptance.
- [ADR-0090](../decisions/0090-second-audi-dns-replica-on-worker.md) is amended
  by ADR-0095 so the worker replica may use the authenticated physical control
  path after the overlay alias is removed.
- [ADR-0075](../decisions/0075-fleet-overlay-and-source-access.md) continues to
  define the reviewed source perimeter; no global fleet API opening is added.
- [ADR-0091](../decisions/0091-fleet-perimeter-public-listeners.md) continues to
  govern Audi's anonymous public listeners.
- [ADR-0050](../decisions/0050-usage-based-overcommit.md) retains its journaled
  resource-transition decision; implementation evidence now covers independent
  enrollment-revision preservation during replay.

## Verification performed

- Provisioned one NixOS and one Ubuntu Firecracker VM with the `oss` profile.
  First-connect and strict-known-host SSH succeeded as `root` on both guests.
- Started transient port-80 services and verified `Hello world from NixOS` and
  `Hello world from Ubuntu` locally and through Audi with staging TLS.
- Reproduced Dungarees' failed direct-neighbour route and verified the explicit
  gateway `/32` route restored access to both published endpoints.
- Built the complete Overalls and Dungarees NixOS closures after the declarative
  changes. Evaluated production issuer selection, public CA trust, absence of
  the stale host aliases, and the rendered Dungarees route.
- Ran `elixir scripts/check_adrs.exs`, the full code-contract checker and its 19
  regression tests, and `git diff --check` successfully before this review.
- The focused `host-planning` check passes with resource-journal replay and
  closed-diagnostic regressions. The broader `auto-update` VM check remains
  blocked before execution by eight pre-existing type errors in its composed
  test driver; those diagnostics do not originate in the changed files.
- Overalls activated `0aefbe0`; the relay listened only on
  `136.243.69.55:5443`, carried live control traffic to `127.0.0.1:5443`, and
  `/etc/hosts` contained no stale alias. Dungarees activated `e6195a0`, reported
  healthy updater state, resolved `overalls.dev` publicly, and routed both `.55`
  and `.37` through `136.243.69.1`; its gateway and DNS readiness sockets both
  returned `ready: true`.
- Both authoritative DNS addresses returned the active `.37` gateway for the
  Overalls-hosted VMs. Ordinary HTTPS returned each expected page with a
  system-trusted Let's Encrypt certificate expiring December 21, 2026. Strict
  host-key SSH revalidation returned `user=root os=nixos` and
  `user=root os=ubuntu` from the two Firecracker guests.

## Remaining work

- The broader auto-update VM check needs its pre-existing composed-driver type
  errors repaired before it can provide an additional end-to-end regression
  signal. Focused typed checks and live activation cover this repair.
- Exercise operational route failover for host-local VMs independently; the two
  DNS replicas correctly publish the currently active Overalls gateway, so a
  direct request to Dungarees `.32` is not an expected route for these guests.

## Architecture impact

The change replaces machine-local hostname rewriting with an explicit,
source-restricted, TLS-preserving network path and documents the provider's
required route semantics. It changes fleet networking and certificate trust but
does not change application protocols, credential authority, guest isolation,
or endpoint authorization.
