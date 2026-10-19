# Verification

Structural (fast, run before every commit from `marshall/`):

```sh
mix monospace.check     # utility classes, colour literals, external references, JS toggles
mix workspace.check     # tsc over palette.js, grid.js, handbook.js, workspace.js, …
mix terminal.check      # terminal hook unit tests (hidden/unread class contract)
mix test test/marshall_web
```

Browser evidence with the disposable fixture (synthetic accounts and machines;
proves rendering and interaction, never guest execution):

Prefer Bombadil for new browser scenarios. For localized pages, inspect actual
bundled-font loading and representative joining, combining marks and
language-specific CJK forms, along with clipping and overflow in both themes,
LTR/RTL and desktop/mobile layouts. Cover locale autonyms as well as translated
messages. A character-map check establishes glyph presence, not correct shaping
or legibility. Retain the exact locale, revision and route scope of every run.

The existing broad route probe can also use the disposable fixture:

```sh
export PGHOST=… PGPORT=…                       # scratch Postgres
MIX_ENV=test MIX_TEST_PARTITION=monospace_browser mix ash.setup
MIX_ENV=test MIX_TEST_PARTITION=monospace_browser MONOSPACE_BROWSER_PORT=4123 \
  MONOSPACE_BROWSER_CONTEXT=$SCRATCH/context.json \
  mix run --no-start scripts/monospace_browser_fixture.exs &
CHROMIUM_PATH=$(command -v chromium) python3 -I scripts/monospace_browser_probe.py \
  $SCRATCH/context.json $SCRATCH/artifacts
```

The probe visits every workspace, machine, settings, handbook and admin route
in light and dark, at desktop and 390px widths, and asserts: no horizontal
overflow, JetBrains Mono available, token contrast, zero off-grid elements on
the workspace routes, drawer focus containment and Escape, draft identity
across reload, reduced-motion compliance, session-free public docs, no
utility classes on the sign-in page, and that no request left the fixture
origin. Its final line is the evidence string quoted by the handbook ledger.

Native evidence: the NixOS browser machine tests (`hldd-browser`,
`control-room-browser`, …) render the packaged release in a real browser.
Record only runs that actually executed, with their scope and duration.
