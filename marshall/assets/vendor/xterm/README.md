# xterm.js 6.0.0 with a local accessibility layout correction

Vendored from the official `@xterm/xterm` npm package (MIT).
Source: https://github.com/xtermjs/xterm.js/releases/tag/6.0.0
Tarball: https://registry.npmjs.org/@xterm/xterm/-/xterm-6.0.0.tgz

Verified tarball integrity:
`sha512-TQwDdQGtwwDt+2cgKDLn0IRaSxYu1tSUjgKarSDkUM0ZNiSRXFpjxEsvc/Zgc5kq5omJ+V0a8/kIM2WD3sMOYg==`

The compiled ESM, CSS and license derive from this release. The ESM source-map comment
is removed because its map is not shipped. Addons are recorded in [addons/README.md](addons/README.md); no runtime CDN is used.
Import these files through the existing app bundles. Review upstream security
changes, verify a new tarball against npm integrity and rerun the browser terminal
checks when updating.

## Reviewed local correction

The bundle includes the [accessibility layout patch](accessibility-layout.patch).
This is a local correction, not an unmodified upstream release. A native fifty-shell,
10,000-image terminal journey spent most sampled CPU time in repeated accessibility
row geometry reads. The patch completes row text/height/transform writes, reads all
natural widths, then applies each row's scale. It preserves row text, column mappings,
ARIA positions, selection geometry, focus/scroll behavior and refresh scheduling.
The [review](../../../../docs/architecture/reviews/2026-09-25-terminal-workspace-verification.md)
records the measured defect and acceptance scope.

[accessibility-layout.json](accessibility-layout.json) records official tarball,
original ESM/source, CSS/license and patched ESM hashes plus exact bundle replacements.
The readable TypeScript diff describes the same three edits. Reproduce from the
official tarball in a disposable location, from the repository root:

```sh
curl --fail --location https://registry.npmjs.org/@xterm/xterm/-/xterm-6.0.0.tgz -o /tmp/xterm-6.0.0.tgz
python3 scripts/patch_xterm.py --tarball /tmp/xterm-6.0.0.tgz --output /tmp/xterm-patched.mjs
cmp /tmp/xterm-patched.mjs marshall/assets/vendor/xterm/xterm.mjs
python3 scripts/patch_xterm.py --check
```

The reproduction tool verifies integrity before writing. The terminal precommit gate
checks the shipped hashes and runs the actual vendored accessibility methods against
mixed-width, blank, partially refreshed and resized rows. CSS and license remain
byte-for-byte upstream. No containment or debounce timing experiment is included.
On upgrade, review both affected call sites and focus/selection consumers, replace
the recorded hashes and minified symbols deliberately, rebuild app assets, and rerun
the focused regressions and full terminal fleets. Remove the patch only after the
replacement runtime passes the regression and native accessibility/graphics checks.
