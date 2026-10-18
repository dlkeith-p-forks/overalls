# User time zones architecture review

## Decision and scope

[ADR-0195](../decisions/0195-user-time-zones.md) adds a per-user display time
zone, a `/settings/profile` page, viewer-zone rendering of every browser
timestamp and each person's local time beside their email on team, machine
access, thread sharing and Control room pages. The change touches persistence
(a nullable `users.time_zone` column and migration), authorization (a new
public generic action and an internal update gated to the compute actor), the
projections that disclose other users, the release build (a new compiled-in
dependency and its fixed-output hash) and the Monospace Web presentation, so
it is a substantive review. It amends the "no profile capability" position
inherited from ADR-0158 through ADR-0159 for display preferences only.

## Source and authority reviewed

- **Storage and time authority.** Only a nullable text column is added. No
  stored instant, `Ledger.now/0` comparison, SQL deadline, CSV export, JSON API
  or SSH wire view changes; `Marshall.Accounts.TimeZones.shift/2` converts for
  display and falls back to UTC rather than raising. The `tz` database is
  selected through `config :elixir, :time_zone_database`, so every
  `DateTime.shift_zone/2` in the release resolves against compiled tables.
- **Write path.** `User.set_time_zone` (policy `actor_present()`) runs
  `Marshall.Accounts.Profile`, which locks the actor's own row through
  `Security.lock_user!/1` (refusing retired accounts) inside
  `Ledger.transaction`, validates with `TimeZones.valid?/1`, writes through the
  internal `store_time_zone` update (policy `Checks.InternalLookup`, validation
  `ValidTimeZone`) and rolls back with `invalid_time_zone`. The action has no
  target argument; Ash rejects a forged one. The post-commit event carries only
  `user_id`; the catalog has no string type, so the zone text cannot be logged.
- **Viewer resolution.** `LiveUserAuth.assign_time_zone/1` reads the browser
  zone from the connect params once during a connected mount, keeps it in the
  socket's private state, validates it and never persists it; the dead render
  uses only the saved zone or UTC. Required and security mounts attach the
  fresh-login hook before the minute tick hook, so persisted revocation or
  expiry halts the refresh before it updates the clock. Optional/public mount
  behavior is unchanged. This corrects the imported ordering to preserve
  ADR-0022's existing authority boundary; it grants no new authority.
- **Disclosure boundary.** `time_zone` is added beside `email` in the team
  member/transfer, machine grant, thread grant, admin user, admin grant, admin
  SSH-key and admin workload projections, all of which already read `User`
  through `:internal_lookup` under the compute actor after their existing
  Cedar decision. `Views.view/2` adds `owner_email`/`owner_time_zone` only
  when the caller is not the owner and already holds read access; the SSH
  `ls`/`show` wire view drops both. Sharing owner/grants and team members omit
  `time_zone` at their SSH projection boundaries, preserving their prior JSON
  envelopes and fields (exact-map assertions in `commands_test.exs`). `<.person>` renders the local-time line
  only from a saved zone passed by the caller.
- **Presentation.** `TimeComponents` emit semantic `<time>` and `<span>`
  elements styled in grid units (`.person`, `.local-time`, `.local-clock`,
  `.account-clock`), with no colour literal and no external resource; the
  profile page uses `UI.panel`, `.kv`, `.input type="select"` and
  `.console-button`. Existing ids, hooks and data attributes are unchanged;
  new ids (`#nav-profile`, `#time-zone-form`, `#profile_time_zone`,
  `#save-time-zone`, `#clear-time-zone`, `#time-zone-status`,
  `#profile-local-clock`, `#account-local-clock`, `#machine-owner-person`,
  `#thread-grant-owner-person`, `#team-member-<id>`, `#machine-owner-<vm>`)
  are consumed by the LiveView tests and the browser probe.
- **Release build.** `tz ~> 0.28.4` joins `mix.lock`; the Marshall fixed-output
  dependency hash was refreshed by letting Nix report the mismatch and the
  release was rebuilt offline with the new hash (see verification).
- **Thread filters.** today/week/month compare calendar days in the viewer's
  zone and still reject future instants; the filters still narrow only the
  already authorized page (`activity-filter-scope`).

## Verification and remaining gaps

Checks run in this worktree (branch `user-time-zones`, based on trunk
`41e6f831c`), inside `devenv shell`:

- Targeted Marshall tests (`mix test --max-cases 4`): the new
  `time_zones_property_test.exs` (five Hegel properties), `time_zone_test.exs`
  (one property, four tests), `time_components_test.exs`,
  `profile_live_test.exs` (ten LiveView tests), `overview_live_test.exs` and
  `ssh/commands_test.exs`: 65 of 65 passed (seed 235164 before the connect-param fix; the profile file re-ran 10 of 10, seed 869210).
- Affected page and projection tests (teams, machines, threads, admin pages,
  sharing, pins, control room, editor workspace, terminal, usage, git,
  SSH keys, security): 159 tests, 158 passed on the first run (seed 700247); the one failure was `threads_sharing_test.exs` asserting the exact grant key set, updated to include `time_zone`, after which the thread and machine sharing files passed 27 of 27.
- Covenant: `mix covenant.check --static` (30/30 obligations statically
  present) and `mix test test/contract --warnings-as-errors` (30 passed),
  including the new `marshall.identity_authorization.I7`/`I8` and
  `marshall.web_surface.I9`.
- `mix precommit` in `marshall/`: not completed — every pre-test stage passed, then the full suite was killed mid-run on the shared host (known OOM); targeted time-zone, profile, component, security-header, pin and contract tests pass (67) after rebasing onto trunk, and Dialyzer has not run on this tree.
- `elixir scripts/check_adrs.exs`, `check_conflict_markers.exs`,
  `check_hldd.exs`, `hldd_coverage.exs --check`, `hldd_views.exs --check` and
  the diagnostics trace schema `--check`: all passed (`ADR check passed (192 decisions)`, `No merge-conflict markers in 8260 files`, `HLDD Ash and deployment views are current`, trace schema regenerated and checked, receipts recorded after review).
- `nix build .#marshall`: the placeholder hash made Nix report `sha256-hG8upeVol3Id0N/mkfxGdMrEnSWIW5S1dfpBSQ58bUo=` for the Marshall dependency fetch; with that hash recorded the release built offline in 218 seconds (`/nix/store/vzbzp6qcjc030inarww7ld3fsrw0m00d-overalls-marshall-0.1.0`) and its `lib/tz-0.28.4/ebin` carries the compiled `Tz.PeriodsProvider`.
- Browser probe (`monospace_browser_probe.py` against the synthetic fixture):
  the route loop passed in light and dark at desktop and 390 px, including the new `check_profile` (browser-zone preselection, GMT-offset labels, saving Adelaide, the ACST/ACDT local clock, the overview timestamp ending in ACST/ACDT with a UTC title, clearing) and `check_grid` on `/settings/profile`; the run then failed with `TimeoutError at probe line 541`, the `[data-appearance]` select inside `check_thread_views`, which matches the pre-existing threads timeout reported for trunk and was not re-run on a trunk worktree here. Profile screenshots were reviewed..

Subsequent integration with incoming `9e7f6bd3223db57517b46c786464b53048bab6a3`
corrected required/security hook ordering to preserve ADR-0022. A regression
mounts the real profile, verifies its persisted token, revokes that exact token,
checks the durable refusal, sends only the clock tick and requires a sign-in
redirect. It failed against the imported ordering (seed 416420, no redirect),
then passed after the correction. The existing clock test now asserts the
rendered instant actually advances. Pinned compilation with warnings as errors
and 49 focused profile, security, time-component, time-zone action/property and
new pin LiveView/backend tests passed (seed 10891, 10.5 seconds) with four
schedulers and default Hegel exploration. This entry records those focused
checks, separately from the
historical branch results above and the required complete merged gate.

Final integration review found two additional violations of the accepted display
contract. The imported sharing/team SSH paths returned browser projection maps
directly, adding `time_zone` to their JSON. They now delete only that field from
share owner/grants and team members. The regression first verifies that actual
database projections contain saved zones, then checks the complete prior wire
maps, membership count and unchanged team envelope. The two-line thread activity
timestamp now retains its UTC hover title; operational route/certificate
expirations render through the shared zone-aware timestamp component. These
restore ADR-0195's existing boundaries without changing authorization or time
authority. The running full suite compiled before these final corrections;
their focused compilation/tests and typing retain separate execution scope.

The complete merged Marshall gate then passed **1,757 tests with 4 exclusions**
(seed `254814`, default Hegel exploration and distributed mode), followed by
Monospace and forced Dialyzer with zero errors. After the final formatter rewrite,
the focused projection/timestamp run passed **63 tests** (seed `161214`, 8
cases), contracts, logging, Monospace, workspace typing and forced Dialyzer
with zero errors. The focused run covers the new share/team exact-map
regression, thread UTC title, operational expiration conversion and profile
time-zone behavior; it is separate from the full gate's pre-correction test
phase. The generated contract coverage now records 32/32 active Marshall
obligations.

Evidence is BEAM-level: Hegel properties drive `TimeZones` over every curated
zone and random instants including DST edges; the action property and tests
run against local PostgreSQL; LiveView tests cover resolution order, the dead
render, the profile page and people on every page; Covenant pins the
validation and provenance obligations. No NixOS machine test exercises the
profile page or the connect param in the packaged browser. Local-time lines
inside LiveView streams refresh when the list is re-read, not on the minute
tick. The browser probe inherits two pre-existing failures on trunk (an
off-grid `check_grid` assertion and a threads `[data-appearance]` timeout);
the new profile checks are isolated so they can be evaluated separately.

## Findings

- No violation of an accepted decision was found. ADR-0158/0159's no-profile
  clause is amended by ADR-0195 rather than silently rewritten; guest
  identity, email and authority are untouched.
- Accepted requirement explicitly unimplemented: packaged-browser evidence for
  the connect param and the profile journey (ADR-0195 stays partial).
- Open choice recorded in ADR-0195: whether a user may hide their local time
  from collaborators while keeping it for themselves.

## Affected records

ADR-0195 (new, accepted/partial); ADR-0158 and ADR-0159 unchanged in status
with their no-profile clause amended by reference; ADR-0010 and ADR-0042
unchanged; ADR-0161 unchanged. HLDD chapters 03, 08, 19, 20 updated.
