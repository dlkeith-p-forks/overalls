# Open in Overalls

For the user-facing installation flow, open `/docs/browser-extension` on your
Overalls server. The guide links to the Chrome/Chromium and Firefox archives and
explains the developer-install steps; its source is
[`marshall/priv/docs/browser-extension.md`](../marshall/priv/docs/browser-extension.md).

The Chrome and Firefox extensions open the current GitHub, GitLab, Codeberg or
Bitbucket Cloud HTTPS page in Overalls. Clicking an unconfigured toolbar opens
settings. Set the Overalls server origin explicitly; HTTPS is required except for
HTTP loopback development. The provider page's origin and path are carried in the
fragment of `/launch/entry`, where Marshall validates and stages the repository
launch before sign-in. The extension discards source queries and fragments before
transmission; they do not identify a checkout and may contain secrets. The toolbar
distinguishes known supported and unsupported hosts; Marshall can still refuse an
unsupported repository route.

When the browser withholds the page URL until permission is granted, the toolbar
stays available. Clicking grants access to the current tab; the extension then
checks that its URL belongs to a supported provider before opening Overalls.
Unsupported clicks show a temporary grey `!` badge and **Unsupported page** title.

Install unsigned developer archives from `/bin/chrome.zip` or `/bin/firefox.xpi`.
Extract Chrome's ZIP and choose **Load unpacked** at `chrome://extensions` with
Developer mode enabled. Firefox supports temporary installation through
`about:debugging` → **This Firefox** → **Load Temporary Add-on**. Permanent Firefox
installation requires Mozilla signing or an explicitly managed browser policy.
This package does not submit either extension to a store.

`/bin/browser/manifest.json` publishes archive lengths, SHA-256 digests, version,
source digest and unsigned status. `/bin/browser/sha256/chrome.zip` and
`/bin/browser/sha256/firefox.xpi` return their corresponding digests. Marshall's
`services.marshall.browserPackage` selects the immutable Nix package; `null`
disables these downloads.

The toolbar icon is a bordered square with a `K` glyph, generated at build time:
filled black with a white glyph on supported pages, an outlined grey square on
other pages. The settings page follows the Monospace Web presentation (ADR-0161)
with system monospace fonts, the four colour tokens in light and dark schemes,
and no external resources.

Run `devenv shell browser-build`, `devenv shell browser-check` or
`devenv shell browser-watch` from the repository. Build and checks use native
modules with strict JSDoc checking, Node tests, Mozilla's standalone linter and
real Chromium extension loading. `nix build .#browser` builds the unsigned
archives offline from hash-verified tools; `nix build .#checks.x86_64-linux.browser`
runs the same tests in the sandbox. The package contains archives in `bin/`, its
manifest at the root, and unpacked extensions in `share/overalls-browser/`.

`package.json` is the version authority. ZIP entries use sorted names, fixed UTC
timestamps, mode 0644 and pinned compression; `SOURCE_DATE_EPOCH` defaults to the
ZIP epoch (1980-01-01), not the wall clock. Source digests cover maintained browser
inputs, excluding `dist/` and `node_modules/`. Native assets and generated metadata
are distributed; no dependencies or test tools enter the archives.

This implementation was studied from
[`antithesishq/weaver` browser sources](https://github.com/antithesishq/weaver/tree/b211e71b9c86aeca507323baab7650218688e9c9/browser)
and adapted to Overalls' authentication and immutable release boundaries.
