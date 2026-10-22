# ADR-0254: Isolated artifact content origin

- ID: ADR-0254
- Date: 2026-10-21
- Status: accepted
- Implementation: partial
- Components: Marshall web, HAProxy, ACME, NixOS deployment
- Supersedes: none
- Superseded by: none

## Context

Artifacts (ADR-0253) are arbitrary agent-authored HTML, scripts and SVG. Serving
them from Marshall's origin would expose the session cookie, CSRF tokens and
LiveView sockets to that content. The user required the content subdomain to be
locked down by content security and cookie policy. No separate registrable
domain is available yet; the default host is `usercontent.ghuntley.dev`, which is
same-site with Marshall.

## Decision

Serve artifact content only from a dedicated host (`MARSHALL_ARTIFACT_CONTENT_HOST`,
Nix `artifactContentHost`) through `MarshallWeb.ArtifactContentEndpoint`, a
separate Bandit listener with no session, socket or body parsers. It accepts
only `GET`/`HEAD /v/<ticket>/[path]`; everything else is 404.

Marshall renders `<iframe sandbox="allow-scripts" credentialless
referrerpolicy="no-referrer">` with a short-lived view ticket: 32 random bytes,
only the SHA-256 stored, bound to artifact, version and user, valid five minutes,
an `issued → expired | revoked` state machine. Every content fetch rechecks
Cedar read and that the artifact is active.

`MarshallWeb.ArtifactContentHeaders` overwrites headers on every response:
`sandbox allow-scripts` CSP with `default-src 'none'`, no connect, worker, frame,
form or base targets and `frame-ancestors` limited to Marshall; COOP same-origin;
CORP same-site; COEP require-corp; a deny-all Permissions-Policy; nosniff;
no-referrer; `private, no-store`; and HSTS without `includeSubDomains`. The
endpoint never sets cookies and strips any `set-cookie`. HAProxy's content
frontend removes request `Cookie`, `Authorization` and `Proxy-Authorization`,
removes response `Set-Cookie`, refuses other methods and misdirected hosts.
Marshall's own cookie keeps the `__Host-` prefix so it is never sent to the
content host, and Marshall's CSP `frame-src` names only the content origin.

MIME types come from a closed extension allowlist; others are attachments.
Markdown is rendered with raw HTML escaped. Storage reaches artifacts only through
a validated `postMessage` bridge that the LiveView authorizes with Cedar.

## Alternatives

Serving from Marshall's origin with a CSP alone leaves cookies and same-origin
APIs reachable. `srcdoc` iframes inherit Marshall's origin unless sandboxed and
cannot stream large content. A separate registrable domain is stronger (no
same-site cookie or `SameSite` exposure) and is the upgrade path once available.

## Consequences

Artifact pages run with an opaque origin and no credentials even on direct
visits. Operators provision a second hostname, certificate and listener port.
Same-site exposure remains until a dedicated registrable domain is configured.

## Invariants and verification

No content response carries `Set-Cookie`; every response carries the exact
lockdown headers; tickets are never logged or placed in query strings; revoked
access fails on the next fetch. NixOS machine test `artifact-origin` exercises
the proxy, headers, cookie stripping, method refusal and host isolation.

## Implementation evidence

- [Content endpoint](../../../marshall/lib/marshall_web/artifact_content_endpoint.ex) and [headers](../../../marshall/lib/marshall_web/artifact_content_headers.ex).
- [Tickets](../../../marshall/lib/marshall/artifacts/tickets.ex) and [runtime configuration](../../../marshall/lib/marshall/operations/runtime_config.ex).
- [Machine test](../../../nix/verification/tests/machines/artifact-origin) and [Marshall NixOS module](../../../nix/domains/system/marshall.nix).

## Open questions

When a dedicated registrable content domain will be provisioned.

## Related decisions

[ADR-0253](0253-artifacts-domain.md) defines the content served here.
