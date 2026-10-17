# ADR-0116: Overview without a usage summary

- ID: ADR-0116
- Date: 2026-09-25
- Status: superseded
- Implementation: implemented
- Components: Marshall Web
- Supersedes: ADR-0114
- Superseded by: ADR-0117

## Context

[ADR-0117](0117-personal-terminal-machine-workspace.md) replaces the machine workspace, personal browser
account opening and roster profile portions where applicable. Other decisions
and historical rationale below remain in force.

ADR-0114 included a thirty-day usage summary and incomplete-report notice on
`/overview`. The user requested their removal. The separate usage destination
already presents usage details.

## Decision

The authenticated Overview does not fetch or display inference usage totals,
incomplete-report counts or a usage failure message. Keep its “Explore your
usage” link to `/usage`. Its bounded, actor-authorized machine preview, catalog
headroom, login checks, refresh behavior, navigation and visual design continue
under ADR-0114's other requirements.

The user's request to remove the quoted usage content from `/overview`
authorizes this replacement.

## Alternatives

Keeping the cards with different copy would retain content the user asked to
remove. Removing the `/usage` destination would make detailed usage harder to
find without being part of the request.

## Consequences

Overview no longer reads owner usage on mount or refresh. The dedicated usage
page and its domain action remain available. No data model, protocol or
authorization boundary changes.

## Invariants and verification

- Overview renders no usage summary, incomplete-report notice or usage error.
- Its usage destination remains available; machine and capacity panels keep
  their actor-authorized and unavailable-state behavior.
- LiveView tests cover the omitted content, retained link and refresh behavior.

## Implementation evidence

[Overview](../../../marshall/lib/marshall_web/live/overview_live.ex) omits the
usage fetch and presentation. [Overview tests](../../../marshall/test/marshall_web/overview_live_test.exs)
verify the content is absent while the usage link and refreshed machine preview
remain available.

## Open questions

None.

## Related decisions

[ADR-0114](0114-overalls-workspace-design.md).
