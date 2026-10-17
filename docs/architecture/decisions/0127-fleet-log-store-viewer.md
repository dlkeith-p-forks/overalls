# ADR-0127: Fleet diagnostic log store and Control room viewer

- ID: ADR-0127
- Date: 2026-09-26
- Status: superseded
- Implementation: partial
- Components: Fluent Bit, VictoriaLogs, HAProxy, WireGuard fleet network, Marshall, NixOS
- Supersedes: none
- Superseded by: ADR-0149

## Context

[ADR-0149](0149-independent-observability.md) replaces application diagnostic
transport, persistence and presentation, with Lilly v4 and Ziggy v2 documents.
It carries forward unrelated authority, isolation, transactional audit/accounting
and recovery requirements. The original rationale and historical evidence follow.

Administrators and read-only administrators need to inspect application and
operational diagnostics from inside Marshall's Control room. Today no in-app
read path exists: diagnostics leave each application only as structured JSON on
stderr, land in the host journal, and are consumed by the optional per-host
Fluent Bit collector decided in [ADR-0042](0042-host-observability.md) — which
is written, tested, but enabled on no fleet host, retains no queryable local
copy, and only exports off-host. "No central log forwarding machine" and
"diagnostic delivery is not business audit persistence" constrain any redesign;
restricted evidence (auditd records, native Firecracker logs, guest console
content) must stay outside an in-app viewer.

The user authorized this feature with an explicit requirement set: fleet-wide
scope (Marshall and worker hosts), text search, live tail, NixOS machine tests
and property tests as evidence, implemented in a dedicated worktree and shipped
to production, with new secrets generated as needed.

Observed facts from a live spike against the pinned toolchains: pinned nixpkgs
(nixos-26.05, c3eea5b) provides VictoriaLogs 1.52.0 and Fluent Bit 5.0.7 as
native packages and NixOS modules. Fluent Bit's `native` `http` output delivers
normalized envelopes losslessly into VictoriaLogs `/insert/jsonline` with
`_msg_field=message`, while the same build's `opentelemetry` output loses record
attributes under its YAML pipeline mode (and its YAML loader rejects inputs
carrying more than ten conditional routes), so the last hop uses the native
JSON-lines transport: basic auth, verified TLS and text-search mapping verified
end to end locally. Setting `logs_body_key` discards sibling attributes and is
not used.

## Decision

Deploy one **fleet diagnostic log store** as a terminal destination of the
existing per-host Fluent Bit pipeline, and expose it read-only in the Control
room.

1. **Store.** VictoriaLogs runs on the control-plane host (overalls) as a
   hardened systemd service with loopback-only backend binding, a configured
   retention period, and a minimum-free-disk guard. It is a queryable
   destination, not a forwarding relay; per-host bounded queues absorb its
   outages and backfill afterward, so delivery never depends on it and guest
   execution is unaffected.

2. **Internal entry point.** HAProxy terminates TLS and basic authentication on
   the WireGuard fleet address `10.90.0.1` as `logs.fleet.internal` and enforces
   path-scoped authority: insert credentials admit only `/insert/*`, reader
   credentials admit only `/select/*` and health endpoints; every other path is
   denied. The backend is loopback-only VictoriaLogs with no public listener, no
   relay service and no fleet-firewall change; only pinned WireGuard peers can
   route to the address at all.

3. **TLS identity.** A dedicated log-store CA signs the `logs.fleet.internal`
   leaf; its private key is recovery-only ciphertext, its public certificate is
   committed and installed on every fleet host, and Fluent Bit verifies the
   chain explicitly (`tls.ca_file`). The shared internal service CA is not used
   because its private key is recovery-only and cannot sign new leaves during
   routine work.

   Store retention is 30 days with a minimum-free-disk guard; on the
   control-plane host a ZFS quota bounds the state dataset.

4. **Producer configuration.** Fleet hosts enable `services.overallsLogging`
   with one `native` `http` output named for this destination: explicit
   `sources` selecting application and operating-system classes and **never**
   `audit`, `firecracker` or guest console content; per-class queue bytes inside
   the existing host budget assertion; `uri` carrying the normalized-envelope
   `/insert/jsonline?_msg_field=message` endpoint; host credentials injected
   from root-only runtime files through the existing `credentialFiles`
   mechanism. The logging module's shape (trusted classification, envelope,
   budgets, verified-TLS and credential assertions) is unchanged.

5. **Viewer.** Marshall queries the store with a dedicated read-only typed
   client: closed query structure (hosts, sources, levels, event names, text,
   since cursor, entry cap), closed-enum interpolation and escaping for the
   store query language, duplicate absorption via the envelope `event_id`, and
   explicit empty/unavailable states. `MarshallWeb.Admin.LogsLive` renders the
   result with filters and a polled live tail under the existing
   `LiveAdminAuth` read boundary: Cedar `admin_read` admits administrators and
   read-only administrators identically, all viewer events are read-only, and
   log content enters no telemetry or domain state.

6. **Secrets.** Insert credentials live in per-host SecretSpec/SOPS documents
   (`<host>-logstore`) and the reader credential in an `overalls-logstore`
   document, generated through the repository `nix run .#secrets` workflow;
   the log-store CA private key is a recovery-only document. No plaintext or
   Nix-store credential paths.

The user's explicit feature authorization and the verified spike establish
acceptance; evidence obligations below gate `partial`/`implemented` status.

## Alternatives

- **In-process Marshall ring buffer (ETS) viewing only control-plane logs:**
  no fleet scope, volatile across restarts, and a new capture surface inside the
  strictly sandboxed Marshall unit; rejected.
- **Lilly pulls host journals over the provisioner channel:** no history for
  disconnected hosts, new cross-repository protocol/mailbox surface, and it
  reimplements classification outside the reviewed Lua envelope; rejected as
  the primary design.
- **Loki as the store:** compactor-based retention and a larger configuration
  and resource footprint for identical viewer needs; rejected.
- **Query CloudWatch Logs Insights:** couples Marshall's application code to AWS,
  contradicting ADR-0042's neutral-envelope rule, and live cloud delivery
  remains an open gap; rejected.
- **Public-address source-restricted relay (fleet API pattern):** adds public
  perimeter surface with no compensating need; the WireGuard address already
  enforces peer membership. Rejected.
- **Single store credential for insert and read:** conflates write authority
  into every host and into Marshall's read path; rejected in favor of
  path-scoped separation at the entry point.

## Consequences

Enabling the collector changes each host's baseline: persistent journal caps
(1 GiB use, 2 GiB keep-free), bounded per-source filesystem queues within the
host budget, and a root collector unit with fixed memory/CPU allowances.
Central custody concentrates sanitized diagnostics on the control-plane host;
the store's compromise reads historical diagnostics but cannot alter delivery,
journal custody remains host-local, and restricted evidence classes stay
excluded at the producer. Viewer freshness is bounded by collector flush and
viewer polling (seconds), and duplicates are possible after queue backfill and
absorbed in the viewer. Store upgrades ride the nixpkgs pin. Read-only
administrators gain the same diagnostic visibility as administrators, which is
the accepted product requirement.

The pinned Fluent Bit 5.0.7 YAML parser rejects more than ten conditional
routes per input (reproduced with stock and patched builds); the journal reader
chunks the selected source surface into at most eight routes per input with
distinct cursor databases, and tail inputs route only their own source. Growing
the source surface therefore raises per-host reader processes, never a wider
per-input route list.

## Invariants and verification

- The store listener is unreachable off the fleet overlay; insert and read
  credentials are path-scoped and distinct; TLS is verified against the
  committed CA by producers and Marshall.
- Producers never select `audit`, `firecracker` or guest sources for this
  destination; envelope origin fields cannot be overridden by payload content.
- Viewer events are read-only; unknown or mutation events halt; no credential,
  token, terminal byte or payload enters any logging sink.
- NixOS machine test: a real catalogued event on one host reaches the store
  through the collector and renders in an authenticated browser view; queue
  backfill after a store stop is observed.
- Property tests pin query-language escaping and duplicate absorption in the
  Marshall client; LiveView tests pin admission of both admin roles and
  refusal of non-administrative users.
- A store outage must not stall the collector beyond queue bounds and must
  surface as viewer state, not error logs loops.

## Implementation evidence

[Log-store module](../../../nix/domains/system/log-store/default.nix) with its
[entry template and contracts](../../../nix/domains/system/log-store/haproxy.conf.template)
establishes the WG-addressed path-scoped entry (insert/reader/userlist ACLs,
TLS from runtime credentials) and hardened bounded VictoriaLogs backend;
[fleet wiring](../../../fleet/fleet-network.nix) binds `logs.fleet.internal`,
installs the committed CA and admits peer-only 8443;
[overalls](../../../fleet/hosts/overalls/services.nix) and
[dungarees](../../../fleet/hosts/dungarees/configuration.nix) enable the
collector with the reviewed source list and runtime-file credentials; the
store client (`marshall/lib/marshall/logs/store.ex` at overalls revision `a99f74f0`, repository deleted) and
viewer (`marshall/lib/marshall_web/live/admin/logs_live.ex` at overalls revision `a99f74f0`, repository deleted) implement
closed query compilation, bounded narrowing, event-identity dedup and the
read-only admin surface.
Store tests (`marshall/test/marshall/logs/store_test.exs` at overalls revision `a99f74f0`, repository deleted) and
viewer tests (`marshall/test/marshall_web/admin_logs_live_test.exs` at overalls revision `a99f74f0`, repository deleted)
pass (13 checks including 2 properties); the
[log-store machine test](../../../nix/verification/tests/machines/log-store/default.nix)
executes the full native path including backfill; the
[review](../reviews/2026-09-26-fleet-log-viewer.md) records exact assertions
and remaining gaps (browser journey, CA rotation, production acceptance), so
implementation is partial.

## Open questions

- Exact retention and disk-guard values sized from measured fleet rates
  (initial: 30-day retention with a minimum-free-space guard).
- Fluent Bit version coverage for `logs_uri`/`_msg_field` composition is proven
  at 5.0.7; machine tests must re-prove it after any collector upgrade.
- Insert-credential rotation cadence follows the existing bundle rotation
  workflow; no automated renewal exists for the log-store CA leaf (10-year
  horizon recorded, consistent with existing internal service certificates).

## Related decisions

- [ADR-0042: Host-local observability and restricted diagnostic evidence](0042-host-observability.md)
- [ADR-0075: Fleet overlay and source access](0075-fleet-overlay-and-source-access.md)
- [ADR-0111: Verifiable private-service certificate names](0111-private-service-tls-names.md)
- [ADR-0123: Remembered browser authentication and revocation](0123-remembered-browser-authority.md)
- [ADR-0032: SSH-derived age identities](0032-ssh-derived-age-identities.md)
