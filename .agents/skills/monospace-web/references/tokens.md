# Tokens

All colour and rhythm values live in `marshall/assets/css/tokens.css`.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `--text-color` | `#000` | `#fff` | text, borders, inverse-video backgrounds |
| `--text-color-alt` | `#666` | `#aaa` | secondary text (`.muted`), placeholders, dashed borders |
| `--background-color` | `#fff` | `#000` | page, controls, dialogs |
| `--background-color-alt` | `#eee` | `#111` | hover, code blocks, selection in the terminal |
| `--font-family` | JetBrains Mono, ui-monospace, monospace | | every element |
| `--line-height` | `1.203125rem` (1.2rem rounded to a 1/64 px layout unit: 19.25px) | | the vertical grid unit |
| `--border-thickness` | `2px` | | every border; focus raises it to 3px |
| `--font-weight-normal/medium/bold` | 500 / 600 / 800 | | the vendored faces |

Theme selection: `:root` (light), `:root[data-theme="dark"]` (explicit dark),
and `@media (prefers-color-scheme: dark) :root:not([data-theme="light"])`
(system dark). `assets/js/appearance.js` sets `data-theme` from the
System/Light/Dark select, persists an explicit choice in `localStorage`
(`phx:theme`) and tolerates unavailable storage.

Contrast measured by the probe in both themes: text on either background at
least 7:1, alt text on either background at least 4.5:1.

Canvas consumers read the tokens through `readPalette()` in
`assets/js/palette.js`: the xterm theme and search decorations, the topbar
progress colour and Mermaid's `base` theme variables.

The only literal outside the token file is `dialog::backdrop { background:
rgba(0, 0, 0, .6) }`, because `::backdrop` cannot read page custom properties
in every engine. `print.css` forces the light values for paper.
