# Monospace Web presentation review — 2026-10-13

## Scope and authority

The user authorized a redesign of the complete Marshall web application around
The Monospace Web (Oskar Wickström, MIT) in a new worktree on `origin/main`
(`235cd9df`), with no external resources, light and dark modes, a reusable
skill, and a merge to `main` followed by a push. They selected removal of the
CSS toolchain, a strictly monochrome palette and text glyphs instead of
artwork. [ADR-0161](../decisions/0161-monospace-web-presentation.md) records
the decision and supersedes the presentation clauses of
[ADR-0114](../decisions/0114-overalls-workspace-design.md).

## Architecture assessment

Initial and final assessments found no new domain, persistence, protocol,
authorization, isolation, capacity or recovery boundary. The asset pipeline
changes from Tailwind plus esbuild to esbuild alone with `css/app.css` as a
second entry point; `tailwind`, `daisyui`, `heroicons`, `cinder`,
`mishka_chelekom` and the `igniter_js` override leave `mix.exs`, so the
Marshall fixed-output dependency hash in `nix/packages/dependency-hashes.json`
changes and `nix/packages/default.nix` drops its Tailwind configuration line.
No migration, runtime JavaScript framework or deployment topology change is
introduced. The removed Mishka retention clause in ADR-0010 is marked
historical with a reciprocal link.

## Functionality and navigation map

| Area | Presentation | Preserved boundary / evidence |
| --- | --- | --- |
| Shell and navigation | Sidebar of navigation trees, `[ Workspace ] [ Control room ]` switch, inverse-video current entry, drawer below 800px, header table on public pages | Login, MFA and return paths unchanged; `#nav-hldd` directly followed by `a#nav-source-code`; drawer focus contract; `registration_test`, `docs_controller_test` |
| Overview | Panels with key/value headroom, machine preview table rows, `[state]` labels | Bounded actor-authorized reads; `#overview`, `#overview-machines-empty`, `DashboardVisibility` hook; `overview_live_test` |
| Machines | Machine table with `.width-min/.width-auto`, numbered creation chapters, `.grid` resource row, detail panels, sharing table, settings, clone ladder `[■] [▸] [ ]` | Original ids, events, draft keys, confirmations; `.clone-source`, `#clone-requests article`; `machines_live_test`, `clone_components_test` |
| Terminals and agents | Monochrome chrome: session list with `○/●` activity, text tool buttons, bordered search bar, native dialogs | xterm DOM, hook names, `data-terminal-*`, `hidden` toggles untouched; `terminal.check` 32 node tests, `terminal_live_test`; threads list as a tree, literal event text in `<pre>` |
| Integrations, teams, git, usage, account | Panels, field rows, tables, ASCII usage chart, glyph-free forms | Credential redaction, membership and ownership handlers, WebAuthn and SSH authority unchanged; `integrations/teams/git/security/ssh_keys/resize` tests |
| Control room | Tables for nodes, capacity pools, campaigns, timelines, jobs, users, audit, access, workloads, mirrors | Administrative checks and mutation handlers unchanged; `nav[aria-label=Administration] a[aria-current=page]`; admin ExUnit tests |
| Handbook and public docs | Prose on an 80ch measure, contents tree, Mermaid themed from the tokens | `.hldd-prose > section`, `pre.hldd-diagram`, section delivery boundary; `hldd_live_test` |
| Errors and launch | Header table, ASCII cat, bordered panel | Fixed public messages and retry semantics |

## Findings and contract review

Contracts added: `no-external-resources`, `four-token-theme`,
`grid-alignment` (assets), `monospace-component-boundary` (components),
`presentation-no-external-resources` and `monospace-browser-evidence` (probe).
`component-regeneration-boundary` and the Mishka generator contract were
removed with the generator; `component-untrusted-content`,
`canvas-theme-source`, `workspace-drawer-focus`, the navigation contracts and
`liveview-hook-and-csrf-registration` are preserved. Historical links in
ADR-0114 and two earlier reviews to deleted Nekomo files were converted to
prose with the last revision. The upstream universal `* + *` margin rule was
scoped to flow containers because it would have displaced xterm rows, the
progress bar, flash overlays and dialogs. The only colour literal outside the
token file is the dialog backdrop. Browser floor: engines with CSS `round()`
and `:has()`.

## Verification and evidence limits

Executed in the worktree on `origin/main` (`235cd9df`) inside the pinned
`devenv shell` against the scratch PostgreSQL:

- Marshall `mix precommit` passed in 1701 seconds on the final source (the
  formatter afterwards reflowed three files without semantic change): toolchain,
  ADR (159 records), HLDD receipts, contracts, logging, compile with warnings as
  errors, unused dependencies, format, the full suite including distributed
  tests, `terminal.check` (32 node tests), `workspace.check` (8 node tests and
  TypeScript over `palette.js`, `grid.js`, `handbook.js`, `workspace.js`,
  `appearance.js`, `tickets.js`, `repository_launch.js`, `admin_elevation.js`),
  the new `monospace.check`, and forced Dialyzer with zero errors, zero skips
  and zero unnecessary exclusions. An earlier complete suite run on the
  unformatted tree reported 1465 checks (237 properties, 1228 tests) with the
  two error-page heading failures that the public header fix then resolved
  (`error_html_test`, `registration_test`, `docs_controller_test` rerun: 9 passed).
- `node --test test/browser/admin_elevation_test.mjs` passed.
- The Playwright probe `scripts/monospace_browser_probe.py` passed against
  `scripts/monospace_browser_fixture.exs` in its own partition, printing
  "Monospace presentation passed: layouts, navigation, both themes, grid
  alignment, self-hosted font, no external requests, drafts and public
  documentation." It captured 70 screenshots: every workspace, machine,
  settings, handbook and administration route in light and dark at 1440 px,
  ten routes at 390 px in both themes, the drawer, the empty overview, dark
  public docs and mobile sign-in. It measured token contrast (text 7:1, alt
  text 4.5:1) in both themes, JetBrains Mono availability on every route,
  zero off-grid block elements on the overview, machines, create, machine,
  security, SSH-key and handbook routes, drawer focus containment and Escape,
  creation-draft identity across reload, reduced-motion compliance, session-free
  public docs, no utility classes on the sign-in page and no request to any
  origin other than the fixture. Screenshots were kept outside the repository.
- `nix build --builders '' .#marshall` succeeded in 249 seconds with the new
  dependency hash; the release stylesheet references only digested local font
  files.
- `prek run --all-files` passed ruff, ruff-format, ty, the logging catalogs,
  conflict markers and the handbook receipt check; `scripts/check_adrs.exs`,
  `check_hldd.exs`, `hldd_views.exs --check`, `hldd_coverage.exs --check` and
  `hldd_options.exs --check` passed from the repository root.
- Native NixOS browser machine tests were not rerun for this change; their
  recorded evidence keeps its original scope.

## Final diff assessment

The final diff touches Marshall assets, fonts, components, templates and
presentation JavaScript, the Marshall build configuration and Nix dependency
hash, the probe and structural gate, the architecture records, the handbook
chapter and ledger, the Marshall and root guidance and the new skill. It adds
no migration, protocol, domain, authorization or topology change. The three
navigation contracts, the drawer focus contract, the hook registration
contract and the terminal byte, geometry and clipboard contracts are
preserved verbatim.

## Limits and follow-up

The browser fixture holds synthetic accounts and machines; the probe
establishes rendering and interaction, not guest execution, SMTP delivery,
physical isolation or production delivery. Contrast sampling and the grid check
are not an assistive-technology audit. Native NixOS browser machine tests are
listed only where they executed.
