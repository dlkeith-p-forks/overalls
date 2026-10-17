# Handbook section pages

## Scope and architecture impact

ADR-0122 supersedes ADR-0121's single-page presentation after the user reported
browser memory exhaustion and requested separate pages. It carries forward the
current-login boundary, mandatory maintenance, strict local diagrams and scoped
security evidence. No domain authority, schema or guest behavior changes.

## Review

The index assigns only section metadata. Section lookup uses a closed compiled
catalog; route input never becomes a filename or atom. The existing login hook
revalidates parameter changes. A section-specific article identity replaces the
old ignored article and hook, so LiveView navigation cannot accumulate chapters.
Disposed hooks stop before starting additional diagrams. Source links compile to
section URLs; catalog order supplies previous/next links.

The security diagram retains all seven layers with concise labels and ordered
links. Diagrams retain a minimum width and scroll inside their container on mobile.
The adjacent table retains detailed requirements.

## Validation

The source of `c2b165afc521cbe13395ea4596dda43ffc08324b` passed:

- Marshall `mix precommit`: 999 cases (80 properties, 919 tests), with the standard
  two exclusions. Forced Dialyzer reported zero errors, skipped findings or
  unnecessary skips. JavaScript tests and type checking passed.
- Nix `hldd`, `hldd-browser` and `marshall-release`. The native browser visited
  every section separately, checked exactly one chapter and only its diagrams,
  and exercised direct entry, previous/next navigation, browser back, themes,
  mobile containment, print and public-route isolation over verified fixture TLS.
  Desktop and mobile screenshots were inspected.
- Python `prek run --all-files`, skill validation, ADR structure, source review
  receipts, code-contract format and discovery. Semantic review traced catalog
  selection, source links, authentication hooks, article replacement and renderer
  ownership; no substantive contract mismatch remains in these paths.

The first native section run found a cold-load race: Mermaid's default window-load
scan could consume diagram source before the LiveView hook mounted. The renderer
now disables automatic scanning during module initialization, before window load.
The passing rerun includes the previously failing direct section visit. The
earlier readability-only results do not substitute for these navigation checks.

## Deployment and remaining limits

The initial handbook commit `330102773d9b45ce8881f5ec76c7245a20c458b2` was pushed
and observed healthy on Overalls. At the user's request, section commit `55a8ee59`
was published while its remaining checks continued; the startup-race correction
followed as `c2b165af`. Overalls reported that exact correction revision healthy.
Public readiness returned HTTP 200, and `/hldd/system` redirected anonymous
requests to sign-in. These observations establish service activation, not every
signed-in production journey.

Tests must prove absence of off-page content and old diagrams. They cannot claim
measured browser heap limits, acceptance on every client, or closure of the
handbook's platform security and recovery gaps.

## Reader authority evidence correction

The original native fixture left installation bootstrap incomplete, so the first
magic-link reader became administrator. Any inference that this native result
established ordinary-user access is withdrawn; section rendering, teardown,
navigation and anonymous/public-route refusals retain their executed scope.
Session revocation in this revision was application-test evidence only. The
[reader authority review](2026-09-25-handbook-reader-verification.md) records the
corrected installed-system fixture and new native session refusal checks.
