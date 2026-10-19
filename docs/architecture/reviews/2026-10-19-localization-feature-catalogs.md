# Localization feature catalogs, rendering and handbook boundary

This review covers Marshall and Porsche changes from `97809b51f`, under
ADR-0201, ADR-0161 and ADR-0207, plus the incoming Android display integration
under ADR-0206. Catalog partitioning preserves the accepted localization
architecture: explicit native Gettext domain/context/source/plural identities,
Localize formatting and validated locale preferences. Partitioning introduces no
Ash domain, durable authority, protocol or listener changes. The integrated diff
also bundles script fonts and repairs incoming browser dependency packaging as
described below; those asset changes are distinct from catalog organization.

Marshall assigns rendering calls to feature domains; reusable navigation and
components use `shared`. Porsche separates onboarding, help, management and
sessions. Identical source wording used by different features has independent
domain identities. Catalogs remain in native locale/LC_MESSAGES directories;
there is no new message-key registry. Both applications retain their existing
Gettext backend compilation configuration.

The previous documentation extractor scanned both public guides and handbook
chapters, contradicting the user's explicit scope. Extraction now selects only
public guides and command summaries. Handbook chapter titles and bodies render
from English source with explicit English/LTR attributes, including generated
command references. Reader controls remain localized. This preserves the
authenticated section boundary and does not publish handbook material.

ADR-0207 replaces only ADR-0161's exclusive-typeface clause. JetBrains Mono remains
the primary Latin/grid font; eight local Noto faces cover CJK, Arabic/Urdu,
Devanagari, Bengali, Telugu, Tamil, extended Latin used by Hausa and interface
symbols. Complete fonts retain shaping and
language-specific tables, with pinned upstream sources, OFL notices and output
hashes. CSS Unicode ranges select the applicable local face. Layout boxes retain
the character grid while script text uses native shaping. Colour tokens, themes,
semantic HTML, resource origin, hooks and terminal renderer boundaries remain
unchanged. Static font integrity and character coverage are separate from
packaged browser shaping and legibility; current rendering evidence remains
pending until its exact script, theme and route scope is recorded.

The incoming trunk Android display client imported noVNC without its required
Pako files and used a bundle format that could not retain upstream top-level
await. The integration restores noVNC 1.7.0's exact dependency files and licence
notices from commit `63107bd06d9e1f6136ff21aeda8cd62cbf0d433e`, with a
[provenance and hash manifest](../../../marshall/assets/vendor/novnc/upstream.json).
The application bundle uses `--format=esm` and the root layout loads it with
`type="module"`. There are no patches to vendored upstream files or runtime CDN
imports. This repairs packaged browser dependency loading; it does not establish
native Android display, Firecracker or controller-authority acceptance.

The migration uses a scratch baseline, exact identities and deterministic native
templates. It rejects unexplained translation loss and ambiguous mappings, moves
per-form invariant reviews to their owning domains, and proves removed handbook
identities against source prose. Fresh source identities remain translation gaps
until filled; moving a catalog does not establish linguistic completeness.

The final source audit found a dynamic error-heading path with no extraction
markers and error-page language attributes built from missing assigns. Explicit
native lookups now cover the pinned Plug error status headings; active validated
locale and central direction determine error-page attributes. Machine status
codes and successful protocol responses remain unchanged.

A read-only source audit found all 74 literal TerminalLive message identities
and all 43 literal ErrorHTML identities in their native templates. Across all
28 locales, terminal and error catalogs match their templates' 124 and 67
identities, respectively. Android display labels retain explicit feature-domain lookups.
The handbook compiler has no locale dependency, its content wrappers declare
English/LTR, and documentation extraction selects public guides only. This
establishes source/catalog identity and the handbook boundary, not browser or
native display execution.

Direction lookup now caches only immutable, bundled CLDR-derived metadata under
one fixed key per application. It validates against the supported locale policy
and does not create keys from request input. This removes repeated full CLDR
matching during interpolated rendering without changing direction semantics or
introducing durable state. A focused run passed **55 tests** in 22.2 seconds,
including the unchanged 100-case handbook authority property within its existing
60-second timeout. Twelve standalone migration regressions also passed.

Porsche's full `mix precommit` passed: 114 tests in 180.3 seconds, four Covenant
obligations, native extraction freshness and forced Dialyzer with zero errors or
skips. Later focused catalog checks cover command-token preservation and exact
invariant reviews; their result is recorded separately when complete.

Strict catalog coverage passed for all 28 locales after the final prose and exact
invariant reviews: no empty non-English entries, fuzzy flags, invalid bindings
or unreviewed source-equal forms remain. English retains native source fallback.
The independent documentation audit covers 3,528 units across 28 locales, including
protected commands, code, links, headings and parsed emphasis/list structure.
These results establish catalog coverage and structural validity, not independent
native-speaker review. Invalid translated HTTP-header, repository-identity,
integration-name and email examples were restored to valid machine syntax with
exact per-message technical reviews.

The first broad Marshall run was invalidated by a concurrent alias-triggered
recompilation of its test artifacts. It is not passing-suite evidence. The
unchanged operator-boot property subsequently passed 100 cases in 91.5 seconds
(seed 564864) without compilation. Its normal test now has a finite 180-second
aggregate budget for those 100 real BEAM subprocess boots, retaining all cases
and assertions. A clean integrated precommit run remains required.

Validation is in progress. Historical Bombadil settings evidence remains scoped
to its original 25 locales and revision; it does not establish current 28-locale
browser acceptance, all-route presentation, native SSH or linguistic review.
