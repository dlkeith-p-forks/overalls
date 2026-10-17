# Kittens developer console redesign

## Scope and decisions

The redesign preserves ADR-0018, ADR-0022 and ADR-0049. It adds an authenticated
`/machines/new` action before the parameterized detail route and redirects `/`
to `/machines`. There are no new dependencies, migrations, backend APIs or domain
boundaries. Kittens uses the existing Phoenix/Tailwind bundles with shared console
navigation, controls and neutral light/dark tokens. Public HTML documentation stays
outside the session pipeline; its appearance preference uses browser storage.

## Contract review

[Machine pages](../../../marshall/lib/marshall_web/live/machines_live.ex) retain
current-login hooks for events, parameters and polling. Provisioning, lifecycle
and sharing still call their existing Ash domains with the current actor. List
and grant refreshes replace bounded streams. Ownership remains protected and
deletion retains explicit confirmation. Form changes retain allowed resource
values and the idempotency key in the URL through reload; these values never
replace transactional admission. A removed image remains visibly unavailable.

[Terminal markup](../../../marshall/lib/marshall_web/live/terminal_live.ex)
preserves the ignored hook subtree, IDs and session binding. The renderer and
input-authority implementation are unchanged. Its 80×24 viewport scrolls inside
the console at narrow widths. Generated component hooks remain registered.
[Appearance code](../../../marshall/assets/js/appearance.js) handles system changes,
saved overrides and unavailable browser storage. Public docs load the existing
bundle but do not connect LiveView without a CSRF token.

## Verification

The targeted machine, authentication, SSH approval/key, documentation, homepage
and terminal suite passed: 33 checks (32 tests and one property). The minified
asset build passed. An isolated SQL-sandbox browser fixture covers desktop and
390px mobile layouts in both themes, draft reload identity, public-doc cookie
absence, keyboard focus and viewport overflow. Screenshots are local artifacts
under `artifacts/web-redesign/`; synthetic terminal state does not establish real
guest execution.

The shared checkout's first `mix precommit` attempt stopped at a duplicate
`source-response-correlated` contract in unrelated Lilly work. A clean copy of committed base `bfc0025` plus only the redesign passed
Marshall’s complete `mix precommit` inside `devenv shell`: 389 checks (353 tests,
36 properties), distributed tests, browser-state tests, contract/ADR validation
and forced Dialyzer. Appearance checks also covered system changes, saved
overrides, cross-tab reset and unavailable storage. Unrelated source, migrations and staged changes are excluded from the
redesign commit. Deployment acceptance is separate from local checks.
