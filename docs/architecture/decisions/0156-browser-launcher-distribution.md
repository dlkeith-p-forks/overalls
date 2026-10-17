# ADR-0156: Browser launcher build and public distribution

- ID: ADR-0156
- Date: 2026-10-10
- Status: accepted
- Implementation: implemented
- Components: browser, Marshall, Nix
- Supersedes: none
- Superseded by: none

## Context

The user asked to inspect and port Weaver's `browser/*`, serve it from `/bin`,
include GitHub, GitLab, Codeberg and Bitbucket, require explicit server
configuration and distribute unsigned developer packages. Weaver was inspected
at commit `b211e71b9c86aeca507323baab7650218688e9c9`; its launcher behavior informs
the port, while Overalls owns authentication and immutable package boundaries.

The CLI already has an installer/update manifest. Browser archives need separate
metadata and allowlisted paths without changing that existing CLI format.

## Decision

Maintain native browser modules with strict JSDoc/TypeScript interfaces, a shared
launcher core and generated Manifest V3 Chrome/Firefox assets. The user explicitly
configures a canonical server origin; require HTTPS except HTTP loopback development.
An unconfigured toolbar opens options. After an explicit click on a supported
HTTPS provider page, open the configured origin's `/launch/entry` with the source
provider origin and page path in the fragment. Discard source queries and fragments
before transmission; they do not identify a checkout and can carry credentials.
URL user information remains unsupported. A tab whose URL is withheld keeps its
action available for the explicit activeTab permission grant; it transmits nothing
before that click.
Known unsupported URLs disable the action, and every click still validates the
observed URL. Refused explicit clicks show a temporary fixed grey `!` badge and
unsupported title, then clear and refresh the tab state without URL feedback.
Host support does not imply that Marshall accepts every repository
route. The extension collects no page contents, credentials or telemetry.
Grant the fixed provider host permissions plus activeTab, synced settings and the
reviewed configuration context menu. Do not embed a production credential or
default server selection.

Use `browser/package.json` as the version authority, lockfile-pinned build tools,
hash-verified Nix npm inputs and no dependency install scripts. The ordinary release
build is offline. Build maintained assets and provenance into unpacked Chrome and
Firefox directories; generate deterministic ZIP/XPI entries with sorted names,
fixed UTC timestamps, modes and compression. The default source epoch is the ZIP
epoch, 1980-01-01. Source digests cover maintained browser inputs; generated
`dist/` and dependencies stay outside the source digest and archives.

Export `nix build .#browser` and `.#checks.x86_64-linux.browser`. Development commands
`browser-build`, `browser-check` and `browser-watch` in devenv invoke the same
maintained build/check source with pinned tools. The check performs strict typing,
Node tests, repeat packaging, Mozilla's standalone add-on linter, real Chromium
extension loading and archive integrity inspection. This launcher uses no image
generator, browser-store upload or signing service.

The immutable package has archives in `bin/`, a version1 distribution manifest at
its root and unpacked extensions in `share/overalls-browser/`. Its manifest records
unsigned status, release version, source digest and each artifact size/SHA-256.
Marshall's nullable `services.marshall.browserPackage` defaults to this package;
the wrapper removes inherited `OVERALLS_BROWSER_RELEASE` and supplies its selected
package after loading other environment files. Null supplies an explicit empty
value and disables downloads. Environment files cannot override package selection.

Public GET routes `/bin/chrome.zip` and `/bin/firefox.xpi` deliver developer
archives. `/bin/browser/manifest.json` and `/bin/browser/sha256/ARTIFACT` publish
their dedicated metadata. The controller permits only these two artifact names,
a canonical Nix-store root and `bin` parent that are actual directories, regular
bounded files and validated digest/length metadata. Symlink roots, parents or
artifact files refuse; declared lengths must match actual artifacts.
Invalid input or unavailable package returns 404. No caller chooses a
filesystem path. The CLI manifest, checksum and installer remain separate.

Chrome users extract the ZIP and use Developer mode's Load unpacked. Firefox
users temporarily load the XPI through about:debugging; permanent ordinary Firefox
installation requires Mozilla signing or managed browser policy. No browser store
submission or permanent-install claim is part of this decision.

## Alternatives

- Weaver's Cargo workspace version and automatic manifest/package synchronization
  do not supply Overalls' browser release version. Keep native modules, use the
  local package version authority and content-bound provenance.
- Folding browser entries into the CLI manifest would change its updater contract
  and mix distinct artifact consumers.
- A fixed production server or automatic origin detection conflicts with explicit
  configuration and can send source intent to an unintended server.
- Signed/store-published packages require publication/signing work the user did
  not request; developer archives meet the authorized distribution scope.

## Consequences

The browser package is a new source-built release dependency of Marshall's
deployment closure, with unchanged listeners, service identities and placement.
Users explicitly choose where source URLs are sent. Provider host permission
scope remains fixed, and browser-vendor compatibility must be tested independently.
Archive availability does not establish authenticated launch or guest checkout.

## Invariants and verification

- Unsupported HTTP/provider pages cannot launch; withheld URLs preserve the
  explicit activeTab grant without transmitting. Options validate and persist
  the configured server; no source transmission occurs before an explicit click.
- Source queries/fragments cannot enter the launch fragment or transmission.
  Preserve provider origin/path and refuse URL user information.
- Both target archives contain only reviewed assets and provenance. Identical
  inputs yield identical bytes and recorded SHA-256 descriptors.
- Downloads cannot traverse paths or serve another package/file; disabled or
  malformed roots and files refuse with 404.
- Chromium runtime and Firefox temporary installation/settings/provider toolbar
  probes are bounded package evidence. Public provider network, signed installation
  and real cross-tab authenticated guest journeys remain separate.

## Implementation evidence

[Maintained launcher](../../../browser/common/extension.mjs),
[build](../../../browser/scripts/build.mjs),
[packager](../../../browser/scripts/package.mjs),
[package tests](../../../browser/scripts/package.test.mjs) and
[Chromium smoke](../../../browser/scripts/chromium-smoke.mjs) implement the shared
extension and build checks. [Nix package](../../../nix/packages/browser/default.nix),
[devenv commands](../../../devenv.nix),
[Marshall module](../../../nix/modules/marshall.nix) and
[download controller](../../../marshall/lib/marshall_web/controllers/browser_download_controller.ex)
connect source-built artifacts to public downloads. The
[current review](../reviews/2026-10-10-browser-launcher.md) separates executed
checks from native/production and permanent installation gaps.
Implementation is implemented: the minimized immutable package/check, byte-identical
developer packages and actual Chromium/Firefox provider actions passed, including
query/hash sentinel removal. Packages preceding the privacy correction retain their
captured scope. Public deployment and external provider acceptance remain validation gaps;
unsigned developer installation is the accepted distribution scope.

## Open questions

Browser-store signing/publication, Firefox public-provider network and Android,
production download plus authenticated checkout acceptance remain outside the
recorded evidence.

## Related decisions

[ADR-0157](0157-multi-provider-authenticated-repository-launch.md),
[ADR-0030](0030-nixos-deployment-and-tls.md),
[ADR-0101](0101-browser-approved-agent-cli.md).
