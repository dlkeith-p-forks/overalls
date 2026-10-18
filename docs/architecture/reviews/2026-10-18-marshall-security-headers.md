# Marshall HTTP security headers, no-index and session cookies (2026-10-18)

Scope: [ADR-0194](../decisions/0194-marshall-http-security-headers.md). Two
commits on the browser endpoint: `feat(web): send noindex robots directives on
every Marshall response` and `feat(web): harden Marshall security headers, HSTS
and session cookies`. Reviewed against the actual diff, the plugs it replaces
and the tests and probe that exercise it.

## Findings

1. **Header coverage was partial (fixed).** Only the `:browser` and
   `:public_documentation` pipelines ran `put_secure_browser_headers`, with
   the minimal `base-uri`/`frame-ancestors` policy. Static files, health, the
   early `/api` refusals, the JSON agent API and error pages carried nothing.
   `MarshallWeb.SecurityHeaders` now runs at the endpoint immediately after
   privacy tagging; the pipeline plug is removed, so no response carries two
   policies. Severity: medium; consequence was clickjacking and content
   sniffing exposure on the uncovered surfaces.
2. **Inline styles are required by vendor renderers (accepted relaxation).**
   xterm.js (`createElement("style")` x3, `setAttribute("style")` x1) and
   Mermaid (`createElement("style")` x2, `setAttribute("style")` x6) cannot be
   covered by a nonce. `style-src` keeps `'unsafe-inline'`; `script-src` is
   `'self'` alone. A per-route relaxation was rejected because LiveView
   navigation keeps the first document's policy.
3. **Session cookie was plantable from user applications (fixed).**
   `_marshall_key` had no `secure` flag and no `__Host-` prefix, so any
   `*.apps.ghuntley.dev` origin could set a same-named cookie for
   `ghuntley.dev`. Production now uses `__Host-marshall` (Secure, HttpOnly,
   Path=/, no Domain, Lax, signed and encrypted) and the remember-me cookie is
   `__Host-remember_me`. `SameSite` stays `Lax` because magic-link landings are
   cross-site top-level navigations. CSRF tokens remain the CSRF control:
   user applications are same-site with Marshall. Separate registrable domain
   for applications recorded as the long-term fix (open).
4. **HSTS now covers subdomains.** `max-age=63072000; includeSubDomains`, no
   `preload`. Audit of `ghuntley.dev` names declared in `fleet/` and `nix/`:
   apex (HAProxy TLS, port 80 challenge and redirect only), `*.apps.ghuntley.dev`
   (Audi wildcard certificate, `308` to HTTPS, `421` for unknown hosts),
   `ns1`/`ns2.ghuntley.dev` (DNS only; Audi fails TLS closed and answers `421`
   over HTTP, so nothing user-facing breaks), apex ports 4443/5443 (service CA,
   non-browser). The apex zone is external: an HTTP-only name created there
   would be forced to HTTPS in browsers that visited the apex.
5. **Forged sessions in tests and machine probes (fixed).** The launch
   controller test and the credential-rotation release probe duplicated the
   cookie key and salts. Both now use `MarshallWeb.BrowserSession.options/0`;
   the probe writes `cookie_name` into its state and `fixture.py` validates and
   sends it. The credential-rotation and mfa-login NixOS machine tests were
   **not** re-run; the mfa-login driver copies cookies by name and value and
   should accept the `__Host-` names, but that is unverified.
6. **Probe instrumentation under strict CSP (fixed).** Playwright's
   `page.evaluate` and `wait_for_function` run `eval()` in the page's main
   world, which the production policy forbids. The probe now evaluates through
   the inspector (`Runtime.evaluate` on a CDP session), which is not page
   `eval`, so enforcement stays intact while the probe reads state; it fails
   on any `securitypolicyviolation` event or Chromium CSP console report and
   asserts the strict header on every navigation.
7. **Permissions-Policy feature names.** Chromium 151 does not recognise
   `ambient-light-sensor`, `battery` or `bluetooth` and logs console warnings
   for them; they were removed. The remaining list is recognised.
8. **Pre-existing probe failures (not caused by this change).** `check_grid` on
   `/threads` inside `check_thread_views` reports `div#thread-workspace` two
   pixels off the grid in both themes and widths, and `check_overflow` on
   `/threads/activity` at 1440px reports a `.field` element reaching 1459px.
   Both reproduce identically with `bypass_csp=True` (no CSP enforcement) and
   no CSP console report occurs, so they are thread-page layout issues
   independent of the headers. Left as findings for the thread workspace
   owners; the probe keeps its assertions.
9. **Intermittent probe step.** `select_option(theme, force=True)` on the
   appearance control at the start of `check_thread_views` timed out with
   "option being selected is not enabled" in two of four runs and passed in
   the others; a targeted diagnostic on the same control always succeeded.
   Not attributable to the headers; recorded as flakiness to investigate.

## Checks run

In `devenv shell` from `marshall/` unless stated. Results as observed on this
worktree with the shared Postgres started for it.

| Check | Result |
| --- | --- |
| `mix format`, `mix compile --warnings-as-errors` | pass |
| `mix test test/marshall_web/security_headers_test.exs test/marshall_web/browser_session_test.exs test/marshall_web/public_endpoint_test.exs test/marshall_web/remember_me_login_test.exs test/marshall_web/controllers/repository_launch_controller_test.exs test/marshall_web/magic_link_flow_test.exs --max-cases 4 --warnings-as-errors` | 30 passed |
| The six files above plus `health_test`, `fleet_endpoint_test`, `auth_controller_test`, `editor_controller_test`, `logged_out_access_test`, `hldd_live_test`, `sign_out_live_test`, `overalls_installer_test` and `test/contract`, `--max-cases 4 --warnings-as-errors` | 93 passed |
| `mix covenant.check --static --contracts contracts --test-path test/contract --root .`; `mix test test/contract`; `mix covenant.check --no-run` | the Contract holds statically; the Contract holds (I7 and I8 added) |
| `mix contracts.check`, `mix monospace.check`, `mix architecture.check` | pass |
| `mix dialyzer` (development build) | 0 errors, passed |
| Full `mix test` | not run in this session (the suite is known to exhaust memory on this host); the targeted set above was run instead |
| `ruff format --check`, `ruff check`, `ty check --python <playwright python>` on `marshall/scripts/monospace_browser_probe.py` | pass (0 diagnostics) |
| `ruff format --check`, `ruff check` on `nix/verification/tests/machines/credential-rotation/fixture.py` | pass; standalone `ty` shows the same pre-existing driver-fragment diagnostics as the committed baseline minus one (fragments are type-checked as the composed NixOS driver) |
| Browser probe `scripts/monospace_browser_probe.py` against `scripts/monospace_browser_fixture.exs` (partition `monospace_browser`, Chromium 151, Playwright 1.59) | strict CSP header asserted on every visited route; zero CSP violations recorded through the owner routes in both themes and the thread views; the run did not reach its final evidence line because of findings 8 and 9 |
| Root: `elixir scripts/check_adrs.exs` (191 decisions), `elixir scripts/hldd_coverage.exs --write` then `--check`, `elixir scripts/hldd_views.exs --check`, `elixir scripts/check_hldd.exs` after recording receipts, `elixir scripts/check_conflict_markers.exs` | pass |

No NixOS machine test was run for this change; none asserts these headers,
HSTS or cookie attributes over the production TLS path yet.

## Follow-up

- Add a NixOS browser machine assertion for the header set, HSTS and the
  `__Host-` cookies over the packaged release and TLS proxy.
- Re-run `credential-rotation` and `mfa-login` machine tests after the cookie
  rename.
- Fix the `/threads` two-pixel grid offset and the appearance-select
  flakiness in the probe.
- Decide on a separate registrable domain for user applications; then revisit
  `SameSite` and HSTS preload.
