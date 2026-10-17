# Browser extension presence review

## Scope and architecture impact

The approved browser extension setup change renames the public guide to
`/docs/browser-extension`, updates Chrome and Firefox packages, and adds a
presentation-only installed signal. This affects browser permission scope and
Marshall's public navigation, but does not add a server listener, persistence
resource, machine authority, or authentication path. ADR-0156 remains the
controlling decision; its implementation status is partial until both browser
runtime setup-visibility checks are recorded.

The extension requests optional host access only for the normalized Overalls
origin that the user explicitly saves. A packaged content script sets
`document.documentElement.dataset.overallsBrowserExtension="installed"` on that
origin. Marshall reads the marker in the page and hides setup affordances only
when the positive signal is present. A page marker is spoofable and can become
stale, so it cannot authorize a user, thread, machine, terminal, editor, or
repository launch. The existing stored login, Cedar decisions and launch
admission remain authoritative.

When configuration is missing, the origin permission is denied or withdrawn,
registration fails, or the detector cannot run, setup remains visible. Changing
origins registers the new exact origin before removing the old registration;
startup reconciliation restores the configured detector. A failed change keeps
the last working configuration. These failure paths avoid both silent loss of
setup guidance and broad host observation.

## Source review and evidence boundary

The implementation surface is the maintained browser module and typed browser
API (`marvin/common/extension.mjs`, `marvin/common/options.mjs`,
`marvin/common/presence.mjs`, and `marvin/types/api.d.ts`), generated Chrome and
Firefox manifests, and Marshall's presentation marker observer. The focused
presence unit tests and package assertions cover exact-origin matching,
permission and registration failures, origin changes, startup restoration, and
asset/manifest inclusion. The existing package and launch tests retain their
source privacy and deterministic archive scope.

No runtime result is claimed in this review until the implementation and both
browser probes are executed. In particular, unit or package tests do not prove
browser permission prompts, Firefox content-script registration, stale-marker
recovery, or deployed TLS behavior. A later Chromium and Firefox setup journey
must verify that setup is visible without the marker and hidden only after the
positive marker, across light/dark and mobile layouts. Native machine,
production download, store-signing and extension-to-authentication journeys
remain separate gaps.

## Security and operational disposition

- **Identity and authorization:** the marker conveys no identity or Cedar role;
  every protected route and launch operation rechecks current stored authority.
- **Transport and isolation:** exact-origin optional access prevents unrelated
  page observation. The content script sees only the current Overalls document;
  it sends no page content, credentials or telemetry.
- **Storage and recovery:** detector registration is browser-local. Marshall
  stores no presence state, and a missing or stale marker fails open to visible
  setup. Configuration failure preserves the previous working origin.
- **Deployment:** no new service, listener, database table, or fleet role is
  introduced. Existing package download controls continue to govern archive
  availability.

The reviewed change therefore preserves the existing launch and machine
boundaries while making the exact optional permission and spoofable UI signal
explicit. Remaining acceptance work is bounded to the browser runtime and
public deployment paths described above.
