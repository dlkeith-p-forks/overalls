# Audi fleet enablement on Overalls and Dungarees

## Scope

Enable Audi's public plane — gateway role and authoritative DNS role — on both
physical fleet hosts, per the user's September 22, 2026 instructions: enable
Audi on both machines, publicly accessible through the firewall at all times,
with the delegated application zone under the public hostname `overalls.dev`.
This review initially covered the Marshall operator CLI, NixOS host configuration,
the fleet-firewall perimeter exception, secret document plumbing and the decision
records. The post-review evidence below records the later deployment and live DNS
behavior without changing the original review boundary.

## Findings

- **Resolved by decision, high:** ADR-0075's fleet perimeter suppressed all
  ordinary per-service firewall openings, making anonymous public ingress
  intentionally unavailable. The user's availability requirement conflicts with
  that accepted consequence. Resolved explicitly rather than silently:
  [ADR-0091](../decisions/0091-fleet-perimeter-public-listeners.md) amends the
  perimeter with a typed, reviewed `publicServices` registry
  (`nix/domains/system/fleet-firewall.nix`) admitting destination-scoped listeners
  from any source. Wildcard destinations, duplicate addresses/ports and empty
  port sets fail evaluation; ordinary per-service contributions remain
  suppressed (verified by the extended
  `nix/verification/tests/evaluation/fleet-firewall.nix`, where an ordinary `dport 9999`
  rule stays suppressed while public service rules survive composition).
- **Resolved by decision, high:** ADR-0047 requires at least two control-plane
  hosts for the DNS role; the fleet has one.
  [ADR-0090](../decisions/0090-second-audi-dns-replica-on-worker.md) amends
  the placement for a single-control-plane fleet: the worker replica keeps its
  unprivileged keyless unit, reaches Marshall only over the authenticated
  tunnel (ordered after `wireguard-fleet0`), the worker-only assertion stays
  intact, and the Overalls replica retains a tunnel-independent loopback
  control path. Consequence recorded: a control-plane outage still SERVFAILs
  both replicas by design; only host/tunnel failures are isolated.
- **Confirmed:** the zone must be a strict subzone. `apps.overalls.dev` is
  configured; Audi DNS serves no apex A record (`audi/lib/audi/dns/authority.ex`
  apex handling), so delegating `overalls.dev` itself would break the proxy's
  HTTP-01 issuance and Porsche's `publicOrigin`. Contracted in
  `overalls-audi-public-plane`.
- **Confirmed:** explicit-address binding. Overalls binds `136.243.69.37`
  (ADR-0085 reservation); Dungarees binds `136.243.69.32`, previously
  documented only as additional SSH on port 2222 — no port collision with Audi
  22/80/443/53. Both addresses were already in Lilly's `protectedCidrs`.
  ADR-0085's implementation evidence now records the Dungarees reservation.
- **Medium, accepted:** the committed SOPS documents carry nonfunctional
  placeholder tokens (documented in `secrets/README.md`, Ziggy precedent).
  Audi fails closed without valid credentials; activation requires the
  operator CLI rotation and document replacement per the
  [rollout runbook](../../operations/fleet-network.md#audi-public-plane-rollout). Real
  credentials must never be fabricated as defaults (ADR-0085 requirement).
- **Low, observation:** `services.marshall.ingress.zone` is now set on
  Overalls, which activates SSH-config downloads, known-hosts responses, web
  login callbacks and Galileo attachment URLs against `apps.overalls.dev`.
  These features previously stayed disabled with no zone configured.
- **Low, pre-existing:** ADR-0075 continues to make the public proxy's
  anonymous HTTP-01 validation unavailable; certificate renewal for
  `overalls.dev` is an existing condition outside this change. ADR-0091's open
  question records the DNS-01 alternative for a future decision.

## Affected decisions

- [ADR-0091](../decisions/0091-fleet-perimeter-public-listeners.md) (new,
  accepted/partial): perimeter public listeners.
- [ADR-0090](../decisions/0090-second-audi-dns-replica-on-worker.md) (new,
  accepted/partial): worker DNS replica placement.
- [ADR-0047](../decisions/0047-audi-ingress-and-authoritative-dns.md): amended
  by ADR-0090 via related links; decision text unchanged.
- [ADR-0075](../decisions/0075-fleet-overlay-and-source-access.md): amended by
  ADR-0091 via related links; decision text unchanged.
- [ADR-0085](../decisions/0085-inception-public-ingress.md): implementation
  evidence extended (Dungarees address, two configured endpoints, staging
  issuer).

## Checks actually run

- Marshall: full `mix precommit` passed — compiler (warnings-as-errors), the
  complete test/property suite, `mix contracts.check`, `logging.check` (122
  catalogued events) and Dialyzer (0 errors). The focused operations run
  covers custody, rotation, revocation, address and UUID validation, conflict
  rollback and retained output files
  (`marshall/test/marshall/operations/audi_test.exs`, 7 cases).
- `nix build .#checks.x86_64-linux.fleet-firewall-configuration --no-link` —
  passes with the new publicServices composition, rejection and suppression
  cases.
- `nix build .#checks.x86_64-linux.module-configuration --no-link` — passes.
- `nix run .#secrets -- check` — 31 documents validated including the four new
  ones.
- `nix eval .#nixosConfigurations.{overalls,dungarees}.config.system.build.toplevel.drvPath`
  — both hosts evaluate; module assertions cover explicit binds, Porsche port
  overlap, TLS nameserver count, administrative SSH 2222, Lilly/Audi host
  identity match and worker-only constraints. Rendered nftables rules verified
  to contain the destination-scoped public accepts for `.37` and `.32`.
- `elixir scripts/check_adrs.exs` — passes (89 decisions).

## Unresolved choices

None blocking. The Let's Encrypt staging-to-production issuer switch is an
explicitly deferred follow-up; inception enablement remains separate future
work that this change unblocks (two independent endpoints).

## Remaining work

- Operator rollout: external delegation, real credential rotation, document
  replacement, serial deployment, live dig/failover/reachability validation
  per the runbook.
- Production ACME issuer switch after staging validation.

## Post-review live correction

Live rollout found that Audi requested Let's Encrypt staging certificates but
validated the returned chains with the production CA bundle. Commit `9951321`
pins the four documented staging roots and scopes that trust exclusively to the
Audi roles; it does not add them to system or browser trust. The fresh Marshall
database also lacked the documented `audi-dungarees` gateway and
`audi-dungarees-dns` identities. Both were restored through Marshall's reviewed
operator actions. Dungarees then served the delegated zone, and Overalls returned
working known-host responses used by strict live guest SSH acceptance.

This corrects the earlier implication that configuration evaluation alone was a
successful staging rollout. Production issuer promotion remains deferred. Live
Overalls gateway, DNS and private readiness, Dungarees DNS service, distinct guest
known-host publication and NixOS/Ubuntu Audi sessions are recorded in the
[guest SSH review](2026-09-22-guest-ssh.md).

## Architecture impact

Two accepted decisions are amended through new linked records rather than
rewritten; no domain, protocol, persistence or authorization boundary changes.
New public exposure is exactly the declared destination/port pairs on `.37`
and `.32`, authenticated at the application layer per existing ADR-0047/0085
semantics. Marshall gains operator-only enrollment actions with the same
custody contracts as the Galileo precedent.
