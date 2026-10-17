# The character grid

- A cell is `1ch` by `var(--line-height)`. Text, borders and boxes land on the
  grid when every vertical size is a multiple of the line height and every
  border is subtracted from padding: a bordered box uses
  `padding: calc(var(--line-height) - var(--border-thickness)) calc(2ch - var(--border-thickness))`.
- Widths snap to whole cells with `round(down, 100%, 1ch)`; the main column
  and prose containers use `calc(min(80ch, round(down, 100%, 1ch)))`.
- Headings: `h1` is 2rem over two lines, uppercase; `h2`–`h6` are 1rem,
  bold. Identifiers (machine names, hostnames) use `h1.ident`, which keeps
  case and one line. Buttons are uppercase, so identifiers never go in buttons.
- Controls (`input`, `select`, `textarea`, `button`, `.console-button`) are two
  lines tall. Compact in-table buttons (`.console-button.compact`) are one line
  and underlined.
- Tables sit half a line down (`top: calc(var(--line-height) / 2)`) so their
  borders fall on grid lines; `th`/`td` padding compensates for the border.
  Mark narrow columns `.width-min` and one growing column `.width-auto`.
- Vertical rhythm: upstream applies `* + * { margin-top }`. Marshall scopes it
  to `.stack`, `.prose` and `.panel-body` so renderer-owned DOM (xterm rows,
  the topbar, flash overlays, dialogs, LiveView stream containers) keeps its
  own geometry. Block elements keep explicit margins.
- Off the grid by design: the xterm renderer (its own cell height), SVG
  diagrams, overlays (`#flash-group`, `dialog`) and LiveView wrappers. The grid
  check skips them.
- Media: `assets/js/grid.js` pads images and video so their boxes end on a
  grid line (`adjustMediaPadding`), ported from upstream `index.js`.
- Debugging: `window.overallsGrid.debug(true)` draws the grid and outlines
  off-grid elements; `window.overallsGrid.check()` returns
  `[{selector, offset}]`. The probe asserts an empty list on the workspace
  routes.
