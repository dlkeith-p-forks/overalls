# ADR-0161: Monospace Web presentation for Marshall

- ID: ADR-0161
- Date: 2026-10-13
- Status: accepted
- Implementation: partial
- Components: Marshall Web, browser assets
- Supersedes: ADR-0114
- Superseded by: none

## Context

The user authorized, as this task, a redesign of the complete Marshall web
application around [The Monospace Web](https://owickstrom.github.io/the-monospace-web/)
(Oskar Wickström, MIT), in a new worktree, merged to `main` and pushed. The
user required that no external resource is loaded (fonts, stylesheets and
scripts are self-hosted), that light and dark modes both work, and that a
reusable skill records the design language. They selected removal of the CSS
toolchain, a strictly monochrome palette and text glyphs instead of artwork.

[ADR-0114](0114-overalls-workspace-design.md) recorded the Nekomo presentation:
bundled Klee One and Zen Maru Gothic fonts, SVG artwork, paper surfaces with
offset shadows, central colour tokens, Tailwind v4 with daisyUI and a
generated Mishka Chelekom component set. ADR-0116 and ADR-0119 replaced its
Overview-usage and Control-room-read clauses and carried the presentation
clauses forward unchanged. Observed facts before this change: application
templates called only `<.link>`, `<.input>`, `<.icon>`, `<.form>`, `<.flash>`,
`Layouts.action` and a few workspace helpers; the Mishka modules, daisyUI and
Cinder stylesheets were imported wholesale but unused; `terminals.js` already
asked for JetBrains Mono without bundling it; ADR-0010 retained the Mishka
development dependency only for an `igniter_js` Rustler constraint.

## Decision

The Monospace Web is Marshall's sole design language. Every page sits on a
character grid of `1ch` by `--line-height` (1.2rem): horizontal sizes in `ch`,
vertical sizes in line-height multiples, `--border-thickness` (2px) borders
subtracted from padding, widths snapped with `round(down, …, 1ch)`.

Presentation colour derives from exactly four tokens per theme, declared only
in `marshall/assets/css/tokens.css`: `--text-color`, `--text-color-alt`,
`--background-color`, `--background-color-alt` (light `#000/#666/#fff/#eee`,
dark `#fff/#aaa/#000/#111`). The existing System/Light/Dark preference
(`data-theme` on `<html>`, `localStorage` key `phx:theme`, storage-failure
tolerance, session-free public pages) is retained unchanged. State and
severity are conveyed by text labels such as `[running]`, weight or inverse
video, never by colour alone. The terminal theme, Mermaid diagrams and the
progress bar read the same tokens through `assets/js/palette.js`.

JetBrains Mono (weights 500, 600, 800 and 500 italic) is vendored as WOFF2
under `priv/static/fonts` with its OFL licence and is the only typeface. No
stylesheet, template or script references an external origin for any
resource; vendored upstream sources keep their notices but are never fetched.

Styling is one hand-written stylesheet bundled by esbuild (`css/app.css` as a
second entry point beside `js/app.js`) composed of `tokens.css`, `fonts.css`,
`monospace.css` (adapted from upstream `index.css`: no external import,
colours moved to tokens, the universal sibling margin scoped to flow
containers, `select` added to the control rules), `shell.css`,
`components.css`, `workspace.css` and `print.css`. Tailwind, daisyUI,
heroicons, Cinder, the Mishka Chelekom generator and its ~70 generated modules
are removed; the `igniter_js` override that ADR-0010 kept for Mishka goes with
it. Templates use semantic HTML plus a small helper vocabulary (`stack`, `row`,
`cols`, `grid`, `tree`, `width-min`, `width-auto`, `muted`, `inverse`,
`hidden`, `sr-only`, `panel`, `field`, `kv`, `table-flow`, `console-button`
tones, `status-label`). Icons are text glyphs through `<.glyph>`; the SVG
sprite, mascots and paw artwork are deleted; the favicon stays.

The signed-in shell is a sticky sidebar of navigation trees beside the main
column, collapsing to the existing focus-contained drawer below 800px. Public
pages use the upstream header table. Navigation destinations, the Control room
switch, the HLDD and Source code placement, every element id, `data-*` and
`aria-*` attribute and every LiveView hook name consumed by tests and browser
probes remain unchanged. Terminal bytes, geometry, clipboard consent and the
ignored renderer DOM remain governed by ADR-0084 as carried through ADR-0117,
ADR-0125 and ADR-0158; only terminal chrome is restyled.

Verification is structural and observed: `mix monospace.check` rejects utility
classes, colour literals outside the token file, external resource references
and JavaScript utility-class toggles; the Playwright probe
`scripts/monospace_browser_probe.py` drives every route in both themes at
desktop and mobile widths, measuring contrast, font availability, grid
alignment, drawer focus, draft identity, reduced motion, session-free docs and
the absence of any cross-origin request. The `monospace-web` skill documents
the language for future changes.

## Alternatives

Keeping Tailwind as a build tool while writing monospace rules would have left
two styling systems and the utility vocabulary in templates. Overlaying the
monospace stylesheet on the existing pipeline could not remove rounded
corners, shadows and framework classes reliably. A restrained accent palette
for status was offered and declined in favour of the upstream monochrome
scheme. Keeping the cat SVG artwork was offered and declined. Converting the
variable TrueType font would need extra tooling; the upstream static WOFF2
files are copied unchanged instead.

## Consequences

The visual language, component layer and all presentation CSS change; no
database migration, protocol, deployment topology, domain boundary,
authorization rule or runtime JavaScript framework changes. The CSS bundle
shrinks (about 47 kB) and four dependencies leave `mix.lock`, so the Marshall
fixed-output dependency hash in `nix/packages/dependency-hashes.json` changes
and the Nix build drops its Tailwind configuration line. The browser floor is
engines with CSS `round()` and `:has()` (current Chromium and Firefox). Open
tabs reload on reconnect after deployment because digested assets change.
Historical records that linked the deleted Nekomo stylesheet and probe now
describe them in prose.

## Invariants and verification

- No external resources: every request the probe observes targets the fixture
  origin; the structural gate rejects external `url()`, `@import` and
  script/style/font references.
- Exactly four colour tokens per theme; measured contrast in both themes is at
  least 7:1 for text and 4.5:1 for secondary text on either background.
- Zero off-grid elements on the workspace routes, excluding renderer-owned DOM
  (xterm, SVG), overlays and LiveView wrappers.
- Terminal transport, geometry, clipboard consent and the ignored renderer DOM
  are untouched (ADR-0084/0117/0125/0158); `terminal.check` passes unchanged.
- Hook names registered in `app.js`, element ids and `data-*`/`aria-*`
  attributes consumed by ExUnit, node and NixOS browser tests are unchanged;
  `#nav-hldd` is immediately followed by `a#nav-source-code`.
- Both themes render every workspace, machine, settings, handbook, admin and
  public route at desktop and 390px widths without horizontal overflow, with
  the drawer containing focus and restoring it.
- Marshall's precommit keeps every existing gate and adds `monospace.check`
  (`marshall-gate-preservation`).

## Implementation evidence

The stylesheet layers live in [assets/css](../../../marshall/assets/css/app.css);
[tokens](../../../marshall/assets/css/tokens.css) hold the only colours and
[the palette helper](../../../marshall/assets/js/palette.js) feeds the terminal,
Mermaid and topbar. [Layouts](../../../marshall/lib/marshall_web/components/layouts.ex),
[core components](../../../marshall/lib/marshall_web/components/core_components.ex)
and [workspace components](../../../marshall/lib/marshall_web/components/workspace_components.ex)
render the shell, glyphs, fields, tables and dialogs. Fonts and their licence
are documented in [the fonts README](../../../marshall/priv/static/fonts/README.md).
[The structural gate](../../../marshall/scripts/check_monospace.exs) runs as
`mix monospace.check`; [the probe](../../../marshall/scripts/monospace_browser_probe.py)
and [its fixture](../../../marshall/scripts/monospace_browser_fixture.exs)
supply browser evidence. The [monospace-web skill](../../../.agents/skills/monospace-web/SKILL.md)
records the language. The [presentation review](../reviews/2026-10-13-monospace-web-presentation.md)
records executed gates, probe results and remaining gaps; native NixOS browser
runs are listed there only when they executed.

## Open questions

None for the product decisions. Production deployment follows the push to
`main` through the existing auto-update path and is observed separately.

## Related decisions

[ADR-0010](0010-capacity-admission-transactions.md) (Mishka/igniter_js
retention clause now void), [ADR-0084](0084-browser-terminal-workspace.md),
[ADR-0114](0114-overalls-workspace-design.md), [ADR-0116](0116-overview-without-usage-summary.md),
[ADR-0117](0117-personal-terminal-machine-workspace.md),
[ADR-0119](0119-authenticated-control-room-reads.md),
[ADR-0122](0122-hldd-section-pages.md), [ADR-0158](0158-durable-guest-identities.md),
[ADR-0160](0160-privileged-administrator-step-up.md).
