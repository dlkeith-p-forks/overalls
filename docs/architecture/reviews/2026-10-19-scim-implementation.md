# SCIM implementation review — 2026-10-19

## Scope

This review covers the new `ash_scim` dependency boundary, the public
`/scim/v2` endpoint, persisted configuration, bearer digest authentication,
magic-link fencing, user/team lifecycle fields, and the Control Room route.

## Findings

- **Implemented boundary:** endpoint discovery, User and Group mappings,
  relationship PATCH handling, OIDC browser callback/session issuance, and
  durable user/team retirement coordinators are present. Native database and
  NixOS execution evidence remains environment-dependent.
- **Dependency compatibility:** `ash_scim` 0.1.0 currently requires a stable
  AshAuthentication 5.x range while Marshall uses `5.0.0-rc.14`; the exact
  package source is vendored with only that constraint widened.
- **Retirement boundary:** native teams are archived and mutation-fenced on
  enable; Oban cleanup revokes attached team authority before machine deletion
  and final archival.

## Validation

`mix compile --warnings-as-errors`, ADR checks, HLDD checks, and generated view
checks pass. Database-backed tests could not run because the local PostgreSQL
socket was unavailable; NixOS execution remains unrecorded in this environment.

## Affected decisions

ADR-0229, ADR-0066, ADR-0077 and ADR-0201.
