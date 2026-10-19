# ADR-0230: WebAssembly compilation for the terminal image decoder

- ID: ADR-0230
- Date: 2026-10-19
- Status: accepted
- Implementation: partial
- Components: marshall, MarshallWeb
- Supersedes: none
- Superseded by: none

## Context

[ADR-0084](0084-browser-terminal-workspace.md) accepts xterm.js with addons for
terminal fidelity, including sixel and iTerm2 inline images, and the recorded
terminal workspace verification rendered 10,000 sixel images in the browser.
The vendored image addon
(`marshall/assets/vendor/xterm/addons/addon-image.mjs`) decodes sixel with a
bundled WebAssembly module that it compiles through `WebAssembly.Module`,
`WebAssembly.Instance` and `WebAssembly.instantiate`.

[ADR-0194](0194-marshall-http-security-headers.md) later fixed the production
Content-Security-Policy at `script-src 'self'`. Chromium refuses WebAssembly
compilation unless `script-src` carries `'wasm-unsafe-eval'` (or
`'unsafe-eval'`). ADR-0194 did not consider the image decoder. Observed effect:
the `porsche-fleet` machine test's "verified terminal v2 sessions, sharing and
reconnect across three Marshall machines" subtest completed every functional
stage and then failed its `assert not self.browser_errors` with 55 `wasm`
page errors, so production terminals cannot decode sixel images.

## Decision

Production `script-src` is `'self' 'wasm-unsafe-eval'`. The keyword admits
WebAssembly compilation and instantiation by scripts that the policy already
allows, which are same-origin only. It does not admit JavaScript `eval`,
`Function`, string timers, inline script, `data:`, `blob:` or any foreign
script origin. The development-tooling relaxation of ADR-0194 is unchanged and
still compile-time only. All other ADR-0194 directives, including the form
origins added by [ADR-0205](0205-overview-newsletter.md) and
[ADR-0202](0202-github-com-owner-integration.md), are unchanged.

This amends only ADR-0194's `script-src` clause; it does not supersede that
decision. Authorization: the Mila plan's verification requires `porsche-fleet`
to pass, and this restores ADR-0084's accepted image rendering with the
narrowest relaxation that does so.

## Alternatives

- **`'unsafe-eval'`:** also admits WebAssembly but re-enables JavaScript string
  evaluation. Rejected as strictly broader.
- **Drop sixel (`ImageAddon({sixelSupport: false})`) or the addon:** keeps
  `script-src 'self'` but withdraws ADR-0084's accepted sixel rendering and
  invalidates its recorded verification. Rejected without a decision to retire
  that capability.
- **A JavaScript sixel decoder:** the vendored addon ships no non-WebAssembly
  decoder; maintaining a fork is a larger supply-chain and correctness cost than
  the keyword.
- **Hash-based WebAssembly allowance:** CSP has no per-module hash source for
  WebAssembly compilation in current browsers.

## Consequences

- Terminals render sixel images again under the production policy.
- A script that already executes from Marshall's origin may compile arbitrary
  WebAssembly. That script already holds full page authority, so the keyword
  adds no new injection path; `script-src` still refuses inline, evaluated and
  foreign JavaScript.
- Tests and probes that assert the exact `script-src` string change with it.

## Invariants and verification

- Production `script-src` MUST equal `'self' 'wasm-unsafe-eval'` and MUST NOT
  contain `'unsafe-eval'`, `'unsafe-inline'`, `data:`, `blob:` or another origin
  ([security headers test](../../../marshall/test/marshall_web/security_headers_test.exs),
  [web surface contract test](../../../marshall/test/contract/marshall/web_surface_contract_test.exs),
  obligation `marshall.web_surface.I7`).
- The development policy MUST still add its sources only through the
  compile-time `development_tooling` flag.
- Browser evidence: the fleet terminal probe MUST record no `wasm` page errors
  while replaying sixel output; the
  [Monospace browser probe](../../../marshall/scripts/monospace_browser_probe.py)
  checks the served `script-src`.

## Implementation evidence

- [`MarshallWeb.SecurityHeaders`](../../../marshall/lib/marshall_web/security_headers.ex)
  serves the amended `script-src` and keeps the contract
  `production-csp-no-inline-script`.
- The BEAM tests above check the exact production and development strings.
- The `terminal-fleet` NixOS machine test passed under the amended policy on
  trunk `bcd52e95` plus this change (script 446.0 s): "verified terminal v2
  sessions, sharing and reconnect across three Marshall machines" (304.0 s)
  printed "Verified HTTPS browser sharing, terminal effects and revocation
  passed", so its final `assert not self.browser_errors` held, including the
  binary-sequence and sixel replay stage. On trunk's `script-src 'self'` the
  same subtest failed that assertion with 55 `wasm` page errors.
- Remaining gap: a complete `porsche-fleet` run under the amended policy is not
  yet recorded.

## Open questions

None.

## Related decisions

[ADR-0084](0084-browser-terminal-workspace.md) accepts the image-capable
terminal; [ADR-0194](0194-marshall-http-security-headers.md) is amended in its
`script-src` clause only; [ADR-0205](0205-overview-newsletter.md) and
[ADR-0202](0202-github-com-owner-integration.md) amend other ADR-0194 clauses.
