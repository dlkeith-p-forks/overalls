# ADR-0240: Three account machine creation presets

- ID: ADR-0240
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: Marshall Accounts, Compute, MarshallWeb
- Supersedes: none
- Superseded by: none

## Context

Machine creation had separate hard-coded browser defaults. The user requested
account settings for image, CPU, RAM, disk and profile, then explicitly selected
three independent presets: `/launch` starts with OSS, `/machines/new` and Threads
start with Work. Work denotes the existing `standard` execution profile; it
does not introduce a new wire value or change its networking and tool policy.

## Decision

Accepted under the user's request to implement these presets and publish the
change on the current branch. Store three complete groups of nullable image and
shape preferences on the Accounts User resource. Persist profile defaults of
OSS for launch and Standard for machine/thread creation. Present these choices
as OSS and Work in `/settings#machine-defaults`. Customer and Inception remain
explicit choices in the machine form, outside the saved preset choices.

Saving requires the actor's current stored login and locks only that account.
Validate the enabled durable image, ordinary profile/image compatibility,
execution shape limits, whole MiB/GiB units and image minima before writing.
Launch additionally requires a row-bound source2/workspace-capable image.
The update accepts no target user identifier and changes only one preset.

Resolve each preset against the current eligible catalog. A missing or unusable
saved image falls back to the configured usable image, then an ordinary usable
catalog image. An invalid saved shape falls back to rounded image minima. No
available image leaves creation subject to ordinary refusal; saved preferences
do not reserve capacity or override admission. Explicit machine URL values and
subsequent form edits take precedence and do not update account preferences.
Threads keep their existing Work collaboration mode, separate from VM profile.

A first repository launch uses the launch preset. Replaying an admitted visit
reads only the actor's original admission shape, including archived history and
pre-resize sizes, then repeats ordinary Compute admission with the same source
and key. Changing preferences or catalog availability cannot change that request.
The existing actor/source/visit key, source checks and completion receipt remain
authoritative. A concurrent first submission with changed preferences can conflict;
retry then resolves the committed original request.

This amends only the default-selection clause of ADR-0147, ADR-0157's fixed OSS
launch clause and ADR-0196's section list. Porsche/CLI defaults remain unchanged.
Existing machine identity, isolation, tool policy, capacity and launch source
protocols retain their accepted boundaries.

## Alternatives

- One shared preset would couple three entry points contrary to the requested
  independent choices.
- Browser-only storage would lose preferences across devices and would not place
  validation under account authority.
- Re-resolving an admitted launch from current settings would cause idempotency
  conflicts after a preference or catalog change.
- A new `work` machine profile would change protocols and policy unnecessarily;
  the requested behavior maps to existing Standard permissions.

## Consequences

An additive migration must run before dependent Marshall code starts. Older
replicas ignore the new columns. Defaults affect future admissions only and
are advisory; host eligibility and current account policy still decide creation.
The new Compute request projection is owner/key scoped and grants no mutation.
Settings add no credentials, external resources, services or host placement.

## Invariants and verification

- Preset updates preserve the other two groups and every other account.
- Malformed sizes, unavailable images, forbidden profiles, foreign targets and
  revoked logins cannot persist a change.
- Machine URL drafts and thread edits survive refresh; machine request keys and
  explicit one-off Customer/Inception choices retain their existing behavior.
- Launch defaults to OSS and machine/thread defaults to Standard. A saved launch
  profile/shape is used once; replay retains original admission identity.
- Source-incapable images cannot be saved for launch and stale selections fall
  back safely. Transactional admission remains the final image/capacity check.

## Implementation evidence

[User resource](../../../marshall/lib/marshall/accounts/user.ex),
[save coordinator](../../../marshall/lib/marshall/accounts/machine_defaults.ex),
[migration](../../../marshall/priv/repo/migrations/20261020000000_user_machine_defaults.exs)
and [resolver](../../../marshall/lib/marshall_web/machine_defaults.ex) implement
account persistence and validation. [AccountLive](../../../marshall/lib/marshall_web/live/account_live.ex)
provides the forms; the three creation LiveViews consume them.
[Compute views](../../../marshall/lib/marshall/compute/views.ex) preserve replay
inputs. [Focused tests](../../../marshall/test/marshall_web/machine_defaults_test.exs)
exercise settings, isolation, refusals, form seeding and launch replay.
The [profile property](../../../marshall/test/marshall_web/default_profile_history_test.exs)
retains generated refresh/reload/admission exploration. The
[native browser helper](../../../nix/verification/tests/machines/default-oss/browser.py)
now saves an OSS preset before its existing guest policy journey.
Execution results and limits belong to the
[review](../reviews/2026-10-20-account-machine-presets.md).

## Open questions

Native machine execution of the revised preset journey, independent linguistic
review and production migration/rollout remain separate acceptance work.

## Related decisions

[ADR-0147](0147-standard-profile-name.md),
[ADR-0157](0157-multi-provider-authenticated-repository-launch.md),
[ADR-0196](0196-single-account-settings-page.md),
[ADR-0174](0174-user-threads.md),
[ADR-0201](0201-localized-human-surfaces.md).
