# Localization feature catalogs and handbook boundary

This review covers Marshall and Porsche changes from `97809b51f`, under
ADR-0201 and ADR-0161. Catalog partitioning preserves the accepted localization
architecture: explicit native Gettext domain/context/source/plural identities,
Localize formatting and validated locale preferences. It introduces no Ash
domain, durable authority, protocol, listener or dependency changes.

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

Direction lookup now caches only immutable, bundled CLDR-derived metadata under
one fixed key per application. It validates against the supported locale policy
and does not create keys from request input. This removes repeated full CLDR
matching during interpolated rendering without changing direction semantics or
introducing durable state. A focused run passed **55 tests** in22.2seconds,
including the unchanged100-case handbook authority property within its existing
60-second timeout. Twelve standalone migration regressions also passed.

Porsche's full `mix precommit` passed:114tests in180.3seconds, four Covenant
obligations, native extraction freshness and forced Dialyzer with zero errors or
skips. Later focused catalog checks cover command-token preservation and exact
invariant reviews; their result is recorded separately when complete.

Strict catalog coverage passed for all28locales after the final prose and exact
invariant reviews: no empty non-English entries, fuzzy flags, invalid bindings
or unreviewed source-equal forms remain. English retains native source fallback.
The independent documentation audit covers3,528units across28locales, including
protected commands, code, links, headings and parsed emphasis/list structure.
These results establish catalog coverage and structural validity, not independent
native-speaker review. Invalid translated HTTP-header, repository-identity,
integration-name and email examples were restored to valid machine syntax with
exact per-message technical reviews.

The first broad Marshall run was invalidated by a concurrent alias-triggered
recompilation of its test artifacts. It is not passing-suite evidence. The
unchanged operator-boot property subsequently passed100cases in91.5seconds
(seed564864) without compilation. Its normal test now has a finite180-second
aggregate budget for those100real BEAM subprocess boots, retaining all cases
and assertions. A clean integrated precommit run remains required.

Validation is in progress. Historical Bombadil settings evidence remains scoped
to its original 25 locales and revision; it does not establish current 28-locale
browser acceptance, all-route presentation, native SSH or linguistic review.
