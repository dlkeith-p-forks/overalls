# ADR-0114: Overalls workspace navigation and Nekomo presentation

- ID: ADR-0114
- Date: 2026-09-24
- Status: superseded
- Implementation: implemented
- Components: Marshall Web, browser assets
- Supersedes: ADR-0018
- Superseded by: ADR-0116, ADR-0119, ADR-0161

## Context

[ADR-0161](0161-monospace-web-presentation.md) replaces the Nekomo presentation
clauses (fonts, artwork, paper surfaces, colour tokens and the Tailwind/Mishka
toolchain) with The Monospace Web; the navigation and authorization clauses
remain carried forward by ADR-0116 and ADR-0119.

[ADR-0119](0119-authenticated-control-room-reads.md) replaces the administrator-only
read restriction and carries forward the other requirements below.

[ADR-0116](0116-overview-without-usage-summary.md) replaces the Overview usage
summary requirement. The remaining navigation, authorization, presentation and
refresh decisions carry forward.

The user authorized an isolated-worktree redesign of the complete Marshall web
application using the Nekomo stationery and cat aesthetic, with existing
functionality preserved. They explicitly retained the Overalls product name and
selected an Overview dashboard as the signed-in home. Existing horizontal
navigation omitted the Git browser and administrative Git mirrors.

This decision supersedes only ADR-0018's machine-list default landing location.
Its persisted sharing, bounded views, current authorization and idempotency
requirements remain in force, together with their subsequent decisions.

## Decision

Add authenticated `/overview` to the existing required-login LiveView session.
Default sign-in, the authenticated root redirect, the brand link and security
verification's fallback lead there. Explicit authorized return destinations and
pending MFA retain precedence. Anonymous root requests still lead to sign-in.
Existing machine, terminal, agent, administration, documentation and export URLs
remain valid.

Overview composes existing actor-authorized Compute and Inference actions. Its
machine preview requests a page limit of six and makes no global count or
recency claim; the existing action retains its single pagination lookahead.
Usage aggregates the returned thirty-day owner-attributed history;
incomplete reports remain explicit. Catalog headroom remains observational and
never replaces admission. Refresh replaces data, at most once a minute while
visible, or on explicit refresh. Failed panels display unavailability independently.

One responsive sidebar provides ordinary workspace navigation and an
administrator-only Control room mode. Current domain/Cedar checks remain the
authority for every action. Machine details prioritize connection and resources,
then sharing and advanced operations. Destructive actions retain confirmation.

Use locally bundled Klee One and Zen Maru Gothic fonts, reusable SVG artwork,
central CSS color tokens, asymmetric paper surfaces and hard offset shadows.
Canvas colors derive from the CSS theme. Preserve System/Light/Dark browser
preferences, including storage failure and public session-free documentation.
Keep technical states and actions explicit. Use typed browser helpers and an
additional workspace type check in Marshall's precommit gate.

## Alternatives

Keeping the machine list as home was available; the user selected a separate
overview. A backend aggregate/cache or new persistence model is unnecessary for
the bounded preview and existing usage summaries. External font/style CDNs would
break the existing self-contained application bundle convention. Replacing the
terminal renderer would introduce transport and capability changes unrelated to
the requested visual work.

## Consequences

The default post-login destination changes; deep links continue to work. The
overview adds bounded machine reads and existing usage queries while open.
Bundled font assets increase static artifact size. Presentation changes span all
application-owned web screens but introduce no database migrations, protocol
changes, deployment topology or new runtime JavaScript framework.

## Invariants and verification

- Current login, MFA, domain and Cedar checks remain required at their boundaries.
- Shared machine access does not grant owner accounting access.
- Missing or failed readings do not become zero or manufactured capacity.
- Terminal bytes, attachment geometry, clipboard consent, hook names and ignored
  renderer DOM boundaries remain governed by ADR-0084.
- Public HTML documentation remains session-free; Markdown/export routes retain
  their semantics.
- Browser checks cover both themes, mobile overflow, keyboard drawer focus,
  appearance persistence, draft identity and every navigation destination.
- Marshall precommit retains its existing gates and adds browser helper typing.

## Implementation evidence

[Overview](../../../marshall/lib/marshall_web/live/overview_live.ex) composes the
authorized projections. [Layouts](../../../marshall/lib/marshall_web/components/layouts.ex)
provides navigation. The Nekomo workspace stylesheet, colour tokens, font files
and browser probe that implemented the presentation were removed by ADR-0161;
their last revision is commit `235cd9df`. [Overview tests](../../../marshall/test/marshall_web/overview_live_test.exs)
cover actor visibility, boundedness and revocation. The historical owner-accounting
panel and its test were removed by ADR-0116. The
[completion review](../reviews/2026-09-24-kittens-nekomo-redesign.md) records the
passing Marshall precommit, browser and Python checks and the functionality map
at that revision. Synthetic browser data does not establish live guest execution.

## Open questions

None for the product decisions. Production deployment is outside this change.

## Related decisions

[ADR-0018](0018-persisted-sharing-and-user-machine-access.md),
[ADR-0062](0062-interactive-monitoring-dashboards.md),
[ADR-0065](0065-passkey-administration.md),
[ADR-0084](0084-browser-terminal-workspace.md).
