# Fleet-wide structured logging and audit coverage

## Scope and architecture impact

Implement ADR-0042's structured-event requirements across all six Elixir
applications (Marshall, Lilly, Audi, Brady, Ziggy, Porsche) and add a
self-enforcing structural gate so the surface cannot silently regress.
`protocol/` is a pure validation library and deliberately emits nothing.
No domain boundary, API, persistence or authorization decision changes;
business audit history remains PostgreSQL-backed AshPaperTrail versions and
append-only receipts, and this change adds no migrations.

## Findings and implementation

The fleet survey found five whole domains in Marshall with zero logging
(ingress, fleet, administration, inference, authorization), failure-only
coverage across Lilly's lifecycle and transfer subsystems, no logging at all
in Ziggy, metadata-minimal-only diagnostics in Porsche and Brady, two
after-commit violations (Marshall drains and mail delivery), six atom-event
inconsistencies, and allowlist/catalog drift.

### Catalog-validated event emission

Each application now owns a reviewed event catalog
([Marshall](../../../marshall/lib/marshall/events.ex),
[Lilly](../../../lilly/lib/lilly/events.ex),
[Audi](../../../audi/lib/audi/events.ex),
[Brady](../../../brady/lib/brady/events.ex),
[Ziggy](../../../ziggy/lib/ziggy/events.ex),
[Porsche](../../../porsche/lib/porsche/events.ex)) built on a per-app
[shared catalog](../../../elixir/diagnostics/lib/overalls/diagnostics/events/catalog.ex)
macro module.
`emit/2` validates event names and metadata keys at caller compile time and
value shapes (UUID, fixed atom, bounded integer, pid) at runtime: violations
raise during development and tests and drop the field in production releases.
Message text is fixed by the catalog, and there is deliberately no
string-valued metadata type, so credentials, tokens, terminal bytes, command
arguments and payloads cannot structurally pass through event metadata.
Outcome events follow the outer transaction commit
(`unless Repo.in_transaction?()`), including the corrected Marshall drains and
mail-delivery paths.

224 catalogued events now cover: Marshall accounts (passkey verify failures,
MFA resets, admin role changes, account retirement), SSH gateway authority and
key lifecycle, ingress web-login approval/exchange denials, certificate
issuance, evacuation campaigns, relocation handoff with full placement/epoch
correlation, resize phases, clone and relocation admission outcomes, host
credential rotation/revocation, fleet ingestion and cache failures, inference
credentials, administrative job retries, Cedar evaluation errors, and API
request-id correlation on previously uncorrelated fleet/inference/ingress
endpoints, and the authenticated destination/source transfer-receipt exchanges and
provisioner API unauthorized coverage added alongside the multi-disk work
under ADR-0072, Galileo edge-authorization denials and integration
configuration changes, and team membership changes under the named edge
integrations work; Lilly VM launch/stop/delete/fail/adopt outcomes, privileged
systemd/jail/network execution, console authority transitions, ZFS dataset
destruction, control-exchange failures and the complete relocation transfer
subsystem; Audi control exchanges, web-login and SSH denials, ACME account and
host-key publication transitions; Brady cache/listener/metrics lifecycle;
Ziggy inference admission/completion/interruption, leases and durable spool
failures; Porsche SSH authentication outcomes and Marshall exchange failures.

### Privacy filters and formatters

`Ziggy.Privacy` and `Porsche.Privacy` gained reviewed-event pass-through
branches (the accepted Audi pattern): catalog events are reconstructed from
fixed text with shape-validated metadata; every other diagnostic remains fully
redacted. `Audi.Privacy` now reconstructs from `Audi.Events.__catalog__/0`.
Brady's custom formatter serializes catalog events with declared metadata only
while preserving the `runtime_event` redaction fallback, and its reason enum
gained `:transport`/`:closed` so mid-stream failures keep their classification.
The Marshall mailer filter keeps `user_id`/`actor_id` for catalogued events on
redacted authentication paths. Porsche's unobserved SSH proof telemetry now
feeds bounded aggregate counters.

### Structural gate

[scripts/check_logging.exs](../../../scripts/check_logging.exs) runs in every
application precommit (`logging.check` alias) and as seven per-application prek
commit hooks generated from [devenv.nix](../../../devenv.nix) with the pinned
release Elixir, firing on changed application Elixir sources, catalogs,
allowlists and the gate itself. It fails closed on direct
`Logger` diagnostics outside reviewed infrastructure, emit calls bypassing the
catalog, mutating modules that emit no catalogued event, and allowlist/catalog
key drift, with reminder text naming the fix. Five reviewed Marshall
exemptions remain, each documented in the script with its reason.

### Audit receipts

`ssh/admin_actions.ex` was confirmed to already write atomic
`Accounts.AdminEvent` receipts (no duplicates added), and the previously
untested `SSH.Key.Version` history gained secret-exclusion tests. Business
audit persistence remains unchanged per the accepted decisions.

## Verification

All six `mix precommit` gates pass (toolchain, ADR, contracts, compiler
warnings-as-errors, `logging.check`, tests, forced Dialyzer):
Marshall 701 tests (65 properties) plus browser/dashboard gates, Lilly 346,
Audi 143, Brady 55, Ziggy 28, Porsche 78. New tests assert post-commit
emission (including fault-injected rollback proving no premature drain
diagnostics), closed-atom reasons, correlation completeness on relocation
handoff, and marker-secret refutations across authentication, terminal,
credential, spool and SSH paths. `elixir scripts/check_adrs.exs` passes.

## Open gaps

Live cloud delivery remains unverified (ADR-0042's outstanding deployment
evidence). Porsche retains its identity-minimal posture: catalog events carry
closed atoms only, with correlation living in journal unit identity. The five
documented Marshall gate exemptions should collapse as those modules gain
native events. This review does not claim semantic sufficiency of any single
event, only the reviewed closed surface and its enforcement.
