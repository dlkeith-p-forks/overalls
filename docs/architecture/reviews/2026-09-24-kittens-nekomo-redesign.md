# Kittens Nekomo redesign review

## Scope and architecture impact

The user authorized the complete Marshall presentation redesign in a new
worktree, retained the **Kittens** name, and selected Overview as the authenticated
home. The implementation is on `codex/marshall-nekomo`, based on `2070058b`.

[ADR-0114](../decisions/0114-overalls-workspace-design.md) records the new home,
navigation and shared presentation. Its limited supersession of
[ADR-0018](../decisions/0018-persisted-sharing-and-user-machine-access.md)
changes the default landing location; persisted sharing, admission, bounded
projections and idempotency remain in force. Initial and final impact assessments
found no new domain, persistence, protocol, infrastructure or authorization
boundary. No database migration or runtime framework was introduced.

The [Overview LiveView](../../../marshall/lib/marshall_web/live/overview_live.ex)
uses the existing Compute and Inference actions with the authenticated actor. It
requests a machine page limit of six; the existing domain action reads one extra
row for pagination. The preview makes no total-count or recency claim. Accounting
remains owner-only, uses the thirty-day chart and keeps unknown reports explicit.
Catalog headroom is observational. Each panel handles failures independently;
hidden pages pause minute refreshes. The required-login hook checks current stored
authority at mount and before events, parameters and refresh messages.

## Functionality and navigation map

| Area | Presentation and flow | Preserved boundary / evidence |
| --- | --- | --- |
| Entry and Overview | `/overview` is the authenticated root and fallback after login; bounded machine preview, usage and headroom | Login, MFA and explicit return paths remain authoritative; [Overview tests](../../../marshall/test/marshall_web/overview_live_test.exs), auth and security tests |
| Machines | Numbered creation sections; connection/resources, sharing, advanced actions on detail | Original field names, events, draft request keys, provisioning, start/stop/delete, clone, relocation, resize and SSH downloads; [machine tests](../../../marshall/test/marshall_web/machines_live_test.exs) |
| Terminals and agents | Shared machine tabs; themed terminal chrome and conversation layout | Existing ignored renderer DOM, stream/input/geometry and clipboard paths; [terminal tests](../../../marshall/test/browser/terminals_test.mjs), [agent tests](../../../marshall/test/marshall_web/agent_threads_live_test.exs) |
| Integrations and teams | Grouped routing/ownership options, clear team selection | Existing credential clearing/redaction, attachment and membership handlers; [integration tests](../../../marshall/test/marshall_web/integrations_live_test.exs), [team tests](../../../marshall/test/marshall_web/teams_live_test.exs) |
| Git, usage and account | First-class Git navigation, themed usage, security and SSH screens | Existing actions and paths, accounting visibility, WebAuthn and SSH authority |
| Control room | Fleet overview, fleet usage, node maintenance, workloads, jobs, platform status, users, access authority, Git mirrors and audit | Existing administrative checks and mutation handlers; all ten destinations exercised in browser |
| Public pages | Coordinated authentication, HTML docs and error presentation | Docs remain session-free; Markdown/exports unchanged; errors expose only standard status and fixed recovery guidance |

The shared [layout](../../../marshall/lib/marshall_web/components/layouts.ex),
[components](../../../marshall/lib/marshall_web/components/workspace_components.ex)
and [theme](../../../marshall/assets/css/tokens.css) provide responsive navigation,
paper surfaces, asymmetric corners, hard shadows and reusable SVG cats/paws.
Fonts are local WOFF2 assets with their OFL licenses. System/light/dark preference
and storage-failure behavior remain browser-local. Canvas palettes read the same
CSS variables. The new browser helpers use the repository's existing pinned
TypeScript installation through `mix workspace.check`.

## Findings and contract review

No unresolved blocking finding was found in the inspected diff. The review
traced the changed views, their domain calls, login hooks, navigation consumers,
canvas palette consumers, and public error rendering. Repository, Marshall,
web, asset and test directory contracts were checked alongside local notes.
Contracts for bounded authorized Overview reads, drawer focus, theme palette
ownership, public errors and disposable browser evidence were added. Structural
contract success is separate from this source review and the executed tests.

The review preserves [ADR-0022](../decisions/0022-browser-terminal-and-live-login-checks.md),
[ADR-0062](../decisions/0062-interactive-monitoring-dashboards.md),
[ADR-0065](../decisions/0065-passkey-administration.md) and
[ADR-0084](../decisions/0084-browser-terminal-workspace.md). Existing DOM action
identifiers and authorization handlers remain in place. No logging, terminal
transport or domain-authority changes were needed.

## Executed verification

- Pinned `devenv shell`, Marshall `mix precommit`: **934 passed** (73 properties,
  861 tests), two existing capacity-test exclusions. Distributed tests were
  included. Runtime, ADR, contract, compiler and formatting gates passed.
- The same precommit run passed **17 terminal browser-state tests**, **4 chart
  tests**, workspace TypeScript checking and forced Dialyzer: zero errors,
  zero skipped findings and zero unnecessary exclusions.
- `mix assets.deploy` completed with the compressed font sources.
- `devenv shell -- prek run --all-files`: logging catalogs, Ruff, Ruff formatting
  and ty passed. The browser probe validates external fixture JSON before use.
- The Playwright probe (`marshall/scripts/nekomo_browser_probe.py`, replaced by the
  Monospace Web probe under ADR-0161; last revision `235cd9df`) passed
  against the isolated fixture (`marshall/scripts/nekomo_browser_fixture.exs`, likewise replaced)
  in its own PostgreSQL test partition: 13 workspace destinations in both themes,
  ten workspace mobile screens in both themes, all ten admin destinations,
  empty Overview, mobile focus containment/Escape/navigation, appearance
  persistence, reduced motion, creation draft identity after reload and
  session-free public docs. Token contrast checks require 4.5:1 for the selected
  body/accent text pairs and 3:1 for input borders.
- Screenshots were saved under ignored `artifacts/nekomo/`; desktop Overview,
  mobile dark Overview and machine details were visually inspected after the
  final styling changes. Earlier fixture runs were discarded after sandbox
  expiration and a stale temporary context file; the completed run used a
  fixture-only unlimited ownership timeout and a stable asset build.

## Limits and follow-up

Browser fixtures contain synthetic machines and accounts. These checks establish
UI rendering and interaction, and do not prove real guest execution, SMTP
delivery, physical isolation or production deployment. Real terminal transport
and host acceptance evidence remains with the existing platform reviews.
Contrast sampling is not a complete assistive-technology audit. Full CJK font
coverage is retained; WOFF2 reduces bundle size but cold-cache performance on
slow connections was not benchmarked. No product decision remains unresolved.
