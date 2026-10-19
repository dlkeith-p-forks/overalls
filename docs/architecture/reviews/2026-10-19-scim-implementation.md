# SCIM implementation review — 2026-10-19

## Scope

This review covers the new `ash_scim` dependency boundary, the public
`/scim/v2` endpoint, persisted configuration, bearer digest authentication,
magic-link fencing, user/team lifecycle fields, and the Control Room route.

## Findings

- **Partial implementation:** endpoint discovery and user mappings compile, and
  team retirement now has a durable Oban worker that records deadlines and
  submits machine deletion intents. Group synchronization, OIDC runtime
  connections, and native machine execution remain incomplete.
- **Dependency compatibility:** `ash_scim` 0.1.0 currently requires a stable
  AshAuthentication 5.x range while Marshall uses `5.0.0-rc.14`; the exact
  package source is vendored with only that constraint widened.
- **Retirement boundary:** native teams are archived and mutation-fenced on
  enable; attached-resource cleanup requires the remaining Oban coordinator.

## Validation

`mix compile` passes after the dependency and resource changes. Database-backed
tests could not run because the local PostgreSQL socket was unavailable. NixOS
execution and HLDD generated checks remain outstanding.

## Affected decisions

ADR-0208, ADR-0066, ADR-0077 and ADR-0201.
