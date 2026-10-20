# Thread redaction architecture review

## Scope

Marshall now sanitizes prompt text at admission and provides bounded historical
scrubs for retained agent events. The scanner is text-only; attachment bytes are
outside the feature. Historical workers select only threads bound to paused or
stopped machines and process bounded batches with a profile digest fence.

## Decisions and evidence

- PostgreSQL remains authoritative for run state and event content. Oban is only
  the durable dispatcher; worker retries are idempotent.
- Scanner work happens outside write transactions. Updates are short and keyed
  by event identity, while profile metadata prevents repeat scans.
- Admin requests are authenticated through the existing admin LiveView boundary
  and recorded in `Marshall.Administration.AuditEvent`; structured events carry
  identifiers and outcomes only.
- Prompt admission redacts before storing the turn and prompt event. Historical
  processing covers already-retained event JSON text and defers active machines.

## Verification and gaps

Scanner unit coverage establishes marker replacement, recursive JSON handling,
idempotence and attachment exclusion. HLDD views and handbook workflow/domain
sections were updated. Full Marshall compilation remains blocked in this
workspace because the offline Nix Cargo cache lacks `cedar-policy`; the normal
`mix precommit`, database migration, concurrent worker and packaged admin browser
journeys still require execution in an environment with the complete dependency
cache.
