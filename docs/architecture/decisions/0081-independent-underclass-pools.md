# ADR-0081: Independent Underclass pools over the fleet overlay

- ID: ADR-0081
- Date: 2026-09-20
- Status: superseded
- Implementation: partial
- Components: NixOS services, fleet networking, secret custody, host recovery
- Supersedes: none
- Superseded by: ADR-0102

## Context

The fleet needs Underclass, a Rust proxy that pools Codex and Copilot
subscriptions behind an OpenAI-compatible API. Underclass stores OAuth tokens,
minted application keys, health and sticky bindings in one plaintext SQLite file.
Its accepted storage design supports one process per data directory and provides
no replication, migration framework or active-active coordination.

The user selected independent pools on each fleet host, Tailscale-only access and
deployment before production backup setup. Underclass's original startup output
included API/admin tokens, which conflicts with the repository diagnostic
contract. The selected upstream revision removes that output and bounds durable
sticky bindings by the same 24-hour TTL and 10,000-entry cap as memory.

## Decision

The user's September 20, 2026 implementation instruction authorizes this
decision. Build one immutable Underclass revision with the fleet's pinned build
package set. Run one independently configured process on every current enrolled
production host; do not run it on base configurations or generic enrollment
hosts. A future host opts in with an explicit host-specific Underclass document. Each host receives distinct
proxy/admin keys through its own SecretSpec/SOPS document, rejects equal or
interchanged keys, and keeps a separate
`/var/lib/underclass/pool.db`. Never copy or concurrently mount that database.

Bind Underclass exclusively to IPv4 loopback. Publish its root through Tailscale
Serve HTTPS on the host's own tailnet identity. Run Serve in the foreground so
systemd observes publication loss and owns only this listener's lifecycle. Do not enable Funnel, direct
public listeners, service firewall openings, shared virtual-service load
balancing or HAProxy publication. Tailnet ACLs provide network admission, while
Underclass's proxy/admin bearer tokens remain mandatory application
authentication.

Run Underclass as a systemd dynamic user with a private state directory, strict
filesystem/device/kernel isolation and explicit CPU, memory, task and descriptor
bounds. Treat it as an independent developer service: monitor its daemon and
Tailscale publication and include both in host update health, but never couple
their failure to Marshall, Lilly, guest lifetime or host readiness.

Register Underclass state in the backup inventory, but do not enable production
backups as part of this change. Until encrypted backup and isolated restore pass,
database loss requires manual provider re-onboarding and there is no durability
or automated failover claim.

## Alternatives

A single pool on Overalls would simplify credential custody but was not selected.
Active-active instances over one SQLite file violate Underclass's single-process
assumption. Copying credentials between independently writable databases creates
rotation and stale-authority risks. Public HTTPS or source-IP-only access would
expand exposure of prompts and bearer keys. SSH tunnels have less network surface
but were not selected. Treating the database as disposable without registering
future backup scope would hide the accepted recovery gap.

## Consequences

Each host can continue serving when the other fails, but only with accounts that
were separately onboarded there. Quota state, stickiness and catalogs can differ.
Clients choose a host explicitly; the fleet provides no balancing or transparent
failover. Operators must maintain two provider pools and two application-key
pairs.

Tailscale enrollment, MagicDNS, HTTPS enablement and ACLs are operational
prerequisites. A conflicting root Serve configuration prevents publication and
deployment health. OAuth credentials remain plaintext at rest inside the
root-protected host database. The current absence of production backups is an
accepted temporary recovery gap, not evidence that the state is durable.

Provider subscription terms and live upstream behavior are external acceptance
obligations; source licensing does not establish permission to pool accounts.

## Invariants and verification

- Every current production host has exactly one host-specific encrypted
  Underclass key document and one local state directory; base and generic
  enrollment configurations have neither service activation nor credentials.
- The daemon command binds only `127.0.0.1`; no NixOS firewall port is opened.
- Remote publication uses `tailscale serve`, never Funnel, and requires both
  `tailscaled.service` and `underclass.service`; the foreground process remains
  supervised instead of leaving a health-stale detached configuration.
- API and administration endpoints retain separate host-specific bearer keys;
  startup rejects missing or equal values and each endpoint rejects the other key.
- Durable sticky bindings expire after 24 hours and retain at most 10,000 rows.
- Keys, OAuth tokens, authorization headers and prompt bodies never enter normal
  diagnostics, derivations or command arguments.
- Daemon/publication failure remains independent of applications and guests.
- Local evaluation and machine checks cover packaging, configuration, auth,
  loopback isolation, resource bounds, restart/reboot persistence and diagnostic
  redaction. Live tailnet/provider/recovery behavior remains separate.

## Implementation evidence

The [pinned package](../../../nix/domains/artifacts/underclass/default.nix),
[NixOS module](../../../nix/domains/system/underclass.nix), and
[enrolled host profile](../../../nix/platform/hosts/profile.nix) implement the package,
runtime and per-host secret wiring. The
[configuration check](../../../nix/verification/tests/evaluation/underclass.nix) and
[machine check](../../../nix/verification/tests/machines/underclass-service/default.nix)
cover the local invariants. Upstream commits `c7d07f1` and `18a7aa1` remove
credential diagnostics and transactionally prune SQLite sticky bindings. The
fleet pin at `a8e51a7` also includes validated cross-proxy request-ID propagation
from `a0ed73d`, preserving correlation without accepting arbitrary header values.
The newer upstream revision adds automatic Codex banked-reset redemption during a
live exhausted-pool request. It stores one account's pending credit and
idempotency key in the same host-local SQLite database and checks upstream usage
before returning the account to service. This remains inside the independent
pool boundary; provider credit behavior has not been verified on live accounts.
The current revision also stores one token-usage row per upstream attempt in
the same host-local database and exposes usage queries and a read-only monitor
through the existing admin-token boundary. Counts may be absent; full prompt
cache keys are retained in the database and available to administrators. The
ledger has no automatic retention limit, so its storage growth needs operational
measurement before changing the host resource bounds.
The fleet package exposes `underclass` and its `utop` monitor wrapper on enabled
hosts' PATH. The wrapper uses the existing admin-token-protected monitor API;
it does not receive the service's private environment file automatically.
[Operations](../../services/underclass.md) document onboarding,
failure behavior and acceptance boundaries.

Implementation remains partial pending live Tailscale Serve, ACL and provider
onboarding verification on both physical hosts, plus encrypted backup activation
and isolated restore.

## Open questions

Choose and verify the production tailnet ACL principals. Measure usage-ledger
growth and define a retention policy before treating its history as durable.
Enable a backup destination and test isolated restoration before making a recovery
claim. Measure resource use and concurrency before changing the initial systemd
limits.

## Related decisions

[ADR-0033](0033-nixos-machine-verification.md) defines local verification claim
boundaries. [ADR-0041](0041-declarative-fleet-users.md) defines secret recipient
custody. [ADR-0042](0042-host-observability.md) governs diagnostics.
[ADR-0070](0070-host-recovery-backups.md) governs future recovery.
[ADR-0075](0075-fleet-overlay-and-source-access.md) defines the overlay and
requires application authentication.
[ADR-0102](0102-local-underclass-monitor-socket.md) carries forward the
independent-pool decisions and replaces the monitor authentication boundary.
