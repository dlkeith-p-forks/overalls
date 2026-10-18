# ADR-0195: User time zone preference and local-time display

- ID: ADR-0195
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: Marshall Accounts domain, MarshallWeb, Marshall Compute/Access/Teams/Threads projections, Marshall release build
- Supersedes: none
- Superseded by: none

## Context

Marshall renders every timestamp on the server in UTC through about fifteen
separate helpers (`"%Y-%m-%d %H:%M UTC"` and similar), has no profile or
preference storage, no `/settings` index and no time-zone database. Other users
appear only as email addresses on team, machine access, thread sharing and
Control room pages. People collaborating across continents cannot tell what
time it is for a teammate, and every time they read must be converted by hand.

Observed facts:

- Stored instants are UTC (`utc_datetime_usec`) and the ledger reads database
  time (`clock_timestamp()`, [ADR-0010](0010-capacity-admission-transactions.md)).
- [ADR-0158](0158-durable-guest-identities.md), carried forward by
  [ADR-0159](0159-remove-legacy-compatibility.md), records that no profile
  username, public email-edit action or onboarding step is added; the HLDD
  repeats that no profile capability exists. That position concerned Linux
  guest identity and email, not display preferences.
- The release is built offline by Nix: Mix dependencies are a fixed-output
  derivation checked against `nix/domains/artifacts/dependency-hashes.json`,
  and the running release has no network path for reference data.
- Every projection that names another user already reads `User` through the
  `:internal_lookup` action under the compute system actor, and the browser
  presentation follows the Monospace Web ([ADR-0161](0161-monospace-web-presentation.md)).

Decided with the user: until someone saves a zone, their own display uses the
browser's zone (the Intl API via LiveView connect params); other users see no
local time for a person until that person saves one.

## Decision

Accepted on 2026-10-18 under the user's request for a per-user time zone,
local-time display and the difference from other users everywhere a person is
shown in the web UI.

1. **Storage stays UTC; conversion is display-only.** `User` gains a nullable,
   non-public `time_zone` attribute holding an IANA identifier. No stored
   instant, ledger comparison, SQL deadline, CSV export, JSON API or SSH wire
   view changes; the inference CSV export stays ISO 8601 UTC. Conversion
   happens in `Marshall.Accounts.TimeZones` and the `MarshallWeb.TimeComponents`
   function components, and every converted timestamp keeps the UTC instant in
   its `datetime` attribute and hover title.
2. **Offline zone data.** The `tz` hex package compiles IANA data into the
   release; `config :elixir, :time_zone_database` selects it. The dependency
   hash in `dependency-hashes.json` is refreshed and the release build proves
   the data is present. Nothing fetches zone data at runtime.
3. **A curated picker with current offsets.** `TimeZones.options/1` returns a
   curated list in the Rails `MAPPING` style (one city per IANA id), labelled
   `(GMT+09:30) Adelaide` from the offset in force at the given instant so
   daylight saving is reflected, sorted by offset then city. `valid?/1`
   accepts a curated id or any identifier the compiled database resolves, so
   browser zones outside the list are usable; everything else is refused.
4. **Self-only, validated writes.** A generic `set_time_zone` action on `User`
   (policy `actor_present()`) runs `Marshall.Accounts.Profile`, which locks the
   actor's own row inside `Ledger.transaction`, validates the zone, writes
   through the internal `store_time_zone` update (gated to
   `Checks.InternalLookup` and guarded again by `ValidTimeZone`), and refuses
   with the closed reason `invalid_time_zone`. A nil argument clears the zone.
   The post-commit event `account.time_zone_changed` carries only the user id;
   the zone text is never logged.
5. **Viewer zone resolution.** `MarshallWeb.LiveUserAuth` assigns `:time_zone`
   as the saved zone, else a valid browser zone from the connect params, else
   UTC, with `:time_zone_source` naming which applied, plus `:now` refreshed by
   a one-minute tick. Required and security mounts check the persisted login
   before that tick updates the clock, preserving ADR-0022; optional/public
   mount behavior is unchanged. The dead render uses only the saved zone or
   UTC. The browser zone is validated and never persisted by the hook.
6. **A profile page.** `/settings/profile` (with `/settings` redirecting to it;
   since [ADR-0196](0196-single-account-settings-page.md) the `#profile`
   section of `/settings`)
   shows the email read-only, the picker preselected with the saved or detected
   zone, Save and Clear, and the viewer's live local clock. The sidebar's
   "Your account" tree gains Profile above Security and the account menu shows
   the local clock under the email. ADR-0196 later collapses that tree to one
   Account entry; the clock link now points at `/settings#profile`.
7. **Other people's local time.** Team members and transfers, machine-access
   owner and grants, the owner of a shared machine in the machines list, thread
   owner and grants, and the Control room's users, access and workloads pages
   render each person with `<.person>`: the email and, only when that person
   has saved a zone, `3:42 PM ACDT local time · 2h 30m ahead of you` relative
   to the viewer. Projections carry `time_zone` beside `email`; the machine
   view carries `owner_email`/`owner_time_zone` only for non-owners, and the
   SSH `ls`/`show` wire view drops both; `share show` and `team show` omit
   `time_zone` from owner, grant and member projections. Terminal viewers show Linux guest
   names, not accounts, and stay unchanged.
8. **Disclosure boundary.** A saved zone is disclosed to users who share a
   team, machine or thread with its owner and to Control room readers, in the
   same projections that already disclose the email. It carries no authority
   and never enters Cedar or any policy decision.
9. **Thread activity filters** (today, week, month) compare calendar days in
   the viewer's zone instead of rolling UTC seconds.

This amends the "no profile capability" position inherited from ADR-0158
through ADR-0159 for display preferences only: there is still no username,
public email edit or onboarding step, and guest identity is untouched.

## Alternatives

- **Client-side conversion with JavaScript.** Every timestamp would need a
  hook and the dead render would still be UTC; other people's local time
  requires the server to know their zone anyway. Rejected for one server-side
  path that also serves the browser-zone fallback.
- **Storing the browser zone automatically.** Silent persistence would show a
  traveller's hotel zone to teammates and hide that a choice was made.
  Rejected: the browser zone is used only for the viewer's own display until
  they save one.
- **A free-text zone field or the full IANA list.** Six hundred ids are hard
  to scan; a curated city list with live offsets matches the user's example.
  Non-curated but resolvable ids remain valid so browser zones work.
- **A separate Profile resource.** One nullable column on `User` is the
  smallest change and keeps the existing lookups; a resource can follow if
  more preferences arrive.
- **Fetching tzdata at runtime (`tzdata` package).** Its updater needs the
  network and a writable directory, which the offline Nix release does not
  provide. Rejected for compiled-in `tz` data refreshed by dependency bumps.

## Consequences

- Every page shows times in the viewer's zone with the zone abbreviation; the
  UTC instant stays one hover away, so support conversations can still cite
  UTC. Operators reading screenshots must note the abbreviation.
- Projections that name users return one more field; shared-machine views
  perform one bounded owner lookup per row. SSH JSON contracts are unchanged.
- The release gains the `tz` dependency and its compiled tables; zone rule
  changes arrive through dependency updates and a hash refresh, never at
  runtime.
- A saved zone is a small new disclosure to collaborators and administrators,
  in the same places that already show the email.
- Browser-zone display is per-connection: a user without a saved zone who
  travels sees local times change with the browser; collaborators see nothing
  until a zone is saved.

## Invariants and verification

- Picker labels equal the zone's `utc_offset + std_offset` at the instant,
  formatted `±HH:MM`, including half-hour and 45-minute zones; options are
  sorted and free of duplicate ids (`time-zone-options-current-offset`, Hegel
  property, Covenant `marshall.identity_authorization.I8`).
- `difference/3` is antisymmetric, zero on itself and its text direction
  follows the sign (`time-zone-difference-antisymmetric`, Hegel property).
- Arbitrary text is refused unless the database resolves it; shifting with an
  unresolvable zone renders UTC rather than raising
  (`time-zone-validation-closed`, `time-zone-shift-fails-to-utc`, Hegel
  property, Covenant I7).
- `set_time_zone` round-trips valid zones, refuses invalid ones with
  `invalid_time_zone`, changes only the actor's row, clears on nil and refuses
  non-user or retired actors; the event carries no zone text
  (`time-zone-self-only`, `time-zone-validated`, `time_zone_test.exs`).
- The viewer zone resolves saved → browser → UTC and the dead render ignores
  the browser (`viewer-time-zone-resolution`, `account_live_test.exs`).
- Required and security clock refreshes retain the persisted-login check of
  ADR-0022. Revoking the connected profile's actual token makes its next clock
  tick redirect before updating the clock (`clock-tick-rechecks-login`,
  `account_live_test.exs`).
- Converted timestamps keep UTC provenance (`timestamp-utc-provenance`,
  Covenant `marshall.web_surface.I9`); a person's local time renders only from
  a saved zone (`person-local-time-saved-only`).
- SSH `ls`/`show`, `share show` and `team show` gain no keys
  (`commands_test.exs`); sharing and team exact-map assertions retain identity,
  email and role while excluding the browser-only preference.
- The browser probe opens the profile page, saves Adelaide and checks a
  timestamp on the overview ends in ACST/ACDT in both themes.

## Implementation evidence

- Zone data and conversion: [`time_zones.ex`](../../../marshall/lib/marshall/accounts/time_zones.ex),
  [`config.exs`](../../../marshall/config/config.exs) (`Tz.TimeZoneDatabase`),
  [`mix.exs`](../../../marshall/mix.exs) (`tz`),
  [`dependency-hashes.json`](../../../nix/domains/artifacts/dependency-hashes.json).
- Storage and action: [`user.ex`](../../../marshall/lib/marshall/accounts/user.ex)
  (`time_zone`, `store_time_zone`, `set_time_zone`),
  [`profile.ex`](../../../marshall/lib/marshall/accounts/profile.ex),
  [`valid_time_zone.ex`](../../../marshall/lib/marshall/accounts/valid_time_zone.ex),
  migration `20261018132813_user_time_zone.exs`,
  [`events.ex`](../../../marshall/lib/marshall/events.ex) (`account.time_zone_changed`).
- Viewer resolution and presentation: [`live_user_auth.ex`](../../../marshall/lib/marshall_web/live_user_auth.ex),
  [`app.js`](../../../marshall/assets/js/app.js) (`timezone` connect param),
  [`time_components.ex`](../../../marshall/lib/marshall_web/components/time_components.ex),
  [`layouts.ex`](../../../marshall/lib/marshall_web/components/layouts.ex),
  [`account_live.ex`](../../../marshall/lib/marshall_web/live/account_live.ex)
  (the profile section; formerly `profile_live.ex`),
  [`router.ex`](../../../marshall/lib/marshall_web/router.ex),
  [`threads_live.ex`](../../../marshall/lib/marshall_web/live/threads_live.ex)
  (viewer-day filters) and the converted admin, git, usage, overview, SSH-key
  and thread timestamps.
- People projections: [`coordinator.ex`](../../../marshall/lib/marshall/teams/coordinator.ex),
  [`access/sharing.ex`](../../../marshall/lib/marshall/access/sharing.ex),
  [`threads/sharing.ex`](../../../marshall/lib/marshall/threads/sharing.ex),
  [`admin_users.ex`](../../../marshall/lib/marshall/accounts/admin_users.ex),
  [`access/admin_actions.ex`](../../../marshall/lib/marshall/access/admin_actions.ex),
  [`ssh/admin_actions.ex`](../../../marshall/lib/marshall/ssh/admin_actions.ex),
  [`admin_views.ex`](../../../marshall/lib/marshall/compute/admin_views.ex),
  [`views.ex`](../../../marshall/lib/marshall/compute/views.ex) (`owner_view/2`),
  [`ssh/commands.ex`](../../../marshall/lib/marshall/ssh/commands.ex) (wire drop).
- Tests: [`time_zones_property_test.exs`](../../../marshall/test/marshall/accounts/time_zones_property_test.exs),
  [`time_zone_test.exs`](../../../marshall/test/marshall/accounts/time_zone_test.exs),
  [`time_components_test.exs`](../../../marshall/test/marshall_web/time_components_test.exs),
  [`account_live_test.exs`](../../../marshall/test/marshall_web/account_live_test.exs)
  (profile section) and [`local_time_live_test.exs`](../../../marshall/test/marshall_web/local_time_live_test.exs)
  (people's local time; both formerly `profile_live_test.exs`),
  [`commands_test.exs`](../../../marshall/test/marshall/ssh/commands_test.exs),
  Covenant obligations `marshall.identity_authorization.I7`/`I8` and
  `marshall.web_surface.I9`, and the profile checks in
  [`monospace_browser_probe.py`](../../../marshall/scripts/monospace_browser_probe.py).
- Review: [2026-10-18 user time zones](../reviews/2026-10-18-user-time-zones.md)
  records the checks actually run and their results.

Remaining: no NixOS machine test exercises the profile page or the browser
connect param in the packaged browser; the synthetic browser probe covers
presentation only and inherits the pre-existing off-grid and thread
`[data-appearance]` failures recorded in the review. Local-time lines inside
LiveView streams (machine grants, thread grants) refresh when the stream is
re-inserted, not on the minute tick.

## Open questions

- Whether a user should be able to hide their local time from collaborators
  while keeping it for themselves. Today saving a zone discloses it.
- Whether the curated list should grow a search box once it exceeds what a
  `<select>` shows comfortably.

## Related decisions

[ADR-0196](0196-single-account-settings-page.md) moves the profile page into the
`#profile` section of `/settings`.
- [ADR-0158](0158-durable-guest-identities.md) and
  [ADR-0159](0159-remove-legacy-compatibility.md): the no-profile position this
  record amends for display preferences only.
- [ADR-0010](0010-capacity-admission-transactions.md): database time
  authority and UTC storage, unchanged.
- [ADR-0022](0022-browser-terminal-and-live-login-checks.md): persisted-login
  checks remain required before authenticated clock refreshes.
- [ADR-0042](0042-host-observability.md): the catalogued event without zone text.
- [ADR-0161](0161-monospace-web-presentation.md): presentation of the
  components and the profile page.
- [ADR-0191](0191-elixir-hegel-property-verification.md): the Hegel properties.
