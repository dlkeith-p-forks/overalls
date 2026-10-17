# Mandatory Ash domain and deployment views

## Scope and architecture impact

Extend ADR-0122's authenticated section handbook with the user's required visual
Ash business domains and deployment topology. Preserve existing application,
authority, persistence, transport and deployment contracts. No migration or new
runtime dependency is introduced. This is an additive documentation invariant,
not a replacement of a platform decision.

The source inventory finds fourteen Marshall domains and Lilly.Lifecycle. Their
resources remain inside their application boundaries. Evaluated fleet declarations
place one Marshall instance and PostgreSQL on Overalls; Dungarees remains a worker.
The three-Marshall machine fixture is deliberately distinguished from that fleet.

## Findings and resolution

- Receipt currency alone could permit removal of a required architectural view.
  The gate now checks generated ownership/placement, per-domain/host explanations,
  source-backed authority and verification prose, and maintained interaction diagrams
  after receipt validation. Refreshing a receipt cannot bypass these requirements.
- Nix module defaults cannot establish host placement. A separate public allowlist
  evaluates inventory hosts' enrolled/base configurations and checks enabled named
  services, Marshall instances, fleet addresses/peers and administrative SSH ports.
  The packaged Nix gate compares this evaluation with the committed snapshot.
- Domain extraction parses application source without executing it. Literal
  resources are deduplicated; dynamic resource declarations fail explicitly.
  Extension-generated resources and arbitrary aliases/macros are outside this
  inventory. Reviewers must extend discovery when those conventions change.
- Diagrams do not prove authorization, live health or physical failure behavior.
  Both sections preserve native/property test preference and explicit gaps. The
  scenario ledger retains the onion of security boundaries and scoped evidence.

## Verification

Marshall `mix precommit` exits zero: 1,010 cases passed (84 properties and 926
tests), with two native/host cases excluded from the ordinary suite. JavaScript
tests and type checks pass; forced Dialyzer reports zero errors, skips or unused
exclusions. ADR/link and contract checks, evaluated view comparison, skill
validation and all prek hooks pass, including ruff format, ruff and ty. Standalone
Dialyzer analysis of the view, gate and coverage modules against the pinned
Marshall PLT also reports no warnings.

The initial full run caught a test-discovery warning despite passing assertions.
The shared fixture now follows Mix's native `hldd_helper.exs` naming convention
and is explicitly required by both suites. No warning exclusion was added; the
complete corrected gate above retains warnings-as-errors.

The packaged `hldd` check passes. Native `hldd-browser` and `marshall-release`
checks pass on the final menu implementation in 297 seconds. The browser visits
all 22 sections, renders both required views on direct entry, and exports
domain/topology screenshots. Inspection of the desktop screenshot confirms HLDD
immediately below Field notes with matching styling and a Reference hint. This
tests the source-built release with fixture PostgreSQL and TLS, not physical
fleet availability. The subsequent helper correction changes test discovery only.

Revision `1df63b5ff2c18fe567f304ad2833c642c6c3ae03` is published to `origin/main` and
recorded healthy by the Overalls updater with no failure. Public readiness returns
HTTP 200; anonymous `/hldd/topology` returns HTTP 302 to `/sign-in`. The shared-menu
adjustment preserves current-login access and has no architecture impact.

## Remaining limits

The projection deliberately excludes credentials, private environments and runtime
data. Its role allowlist needs review when adding a service; source receipts cover
that change. Structural prose checks establish presence, not semantic correctness.
The native browser fixture cannot prove physical host availability, exhaustive
cross-domain authorization or resource limits on every browser.

No new platform design decision remains unresolved. Deployment acceptance above
is limited to revision health, readiness and the protected-route redirect; it
does not close physical-host failure, provider or recovery gaps.

## Reader authority evidence correction

The original native fixture promoted its first reader through incomplete
installation bootstrap. Its rendered-view and navigation results remain valid,
but any ordinary-user authority inference is withdrawn. Native session revocation
was absent from that run. The
[reader authority review](2026-09-25-handbook-reader-verification.md) records the
corrected fixture, persisted non-administrator assertions and new mounted and
fresh-request session refusals; the published deployment observations above retain
their original scope.
