# One account settings page (2026-10-18)

Scope: [ADR-0196](../decisions/0196-single-account-settings-page.md). The
Profile, Security and SSH keys LiveViews merge into `MarshallWeb.AccountLive`
at `/settings`; the three old routes are removed without redirects; the
sidebar collapses to one Account entry with AI usage beneath it. Reviewed
against the final diff, the contracts on the former pages and the tests,
probes and machine tests that name the pages.

## Findings

1. **Authorization surface is unchanged or stricter (no action).** The former
   Security page mounted through `{LiveUserAuth, :security}`; SSH keys and
   Profile through `:live_user_required`. Both run the same clause, so merging
   under `:security` changes no admission rule while the name keeps its pin
   (`account-page-strict-mount-pin` asserts the exact lifecycle ids and the
   route). Every mutation still goes through the socket actor: `User`'s
   `:security` generic action, `Marshall.SSH.add_key/remove_key` and
   `User.set_time_zone`. `safe_return/2` and its contract moved verbatim.
2. **Privacy tag widened (accepted).** `AuthenticationPrivacy` tagged only
   `/settings/security` and `/settings/ssh-keys`. It now tags every
   `/settings` request because one LiveView carries the passkey ceremonies and
   pasted key material; the profile section is tagged along with it, which
   only redacts more.
3. **Fragments carry no authority (no action).** The step-up redirect is
   `~p"/settings?return_to=…" <> "#security"`; Phoenix verified routes refuse
   a fragment after an interpolated query, so the fragment is appended as a
   literal. `return_to` keeps the `/overview`, `/admin/*`, `/machines*` and
   validated `/launch` allowlist.
4. **Machine tests and workloads rewritten blind (gap).** Thirty-one URL
   references in `nix/verification/tests/machines/*/browser.py`, the Porsche
   fleet browser test, `passkey_browser_probe.py` and the Antithesis access
   workload were changed by inspection (`/settings`, `**/settings?**`,
   `/settings?return_to=%2Fadmin%2Fusers#security`). Element ids they consume
   are retained (`#passkey-list > div`, `article` with the fingerprint,
   "Public key" label). None were executed here.
5. **Events unchanged (no action).** No `defevent` entry is added or removed;
   the page emits nothing itself. The trace schema is unchanged.

## Checks run

- `mix compile --warnings-as-errors`, `mix format`, `mix monospace.check`,
  `mix contracts.check`, `mix covenant.check --static …` in `marshall/`;
  `mix compile --warnings-as-errors` and `mix test test/ssh_onboarding_test.exs`
  in `protocol/`.
- `mix test --max-cases 4` over `account_live_test.exs`,
  `local_time_live_test.exs`, `ssh_approval_live_test.exs`,
  `logged_out_access_test.exs`, `remember_me_login_test.exs`,
  `magic_link_flow_test.exs`, `auth_controller_test.exs`,
  `authentication_privacy_test.exs` and the `web_surface` Covenant test.
- `ruff format`, `ruff check` and `prek` over the changed Python.
- `elixir scripts/check_adrs.exs`, `elixir scripts/check_hldd.exs`,
  `elixir scripts/hldd_coverage.exs --check`, `elixir scripts/hldd_views.exs --check`,
  `elixir scripts/check_conflict_markers.exs`.
- Browser probe against the synthetic fixture: results and screenshot paths
  are recorded in the commit report; the probe still stops later at the
  pre-existing thread-page findings (`#thread-workspace` off-grid and the
  `[data-appearance]` timeout), which this change does not touch.

Results of each gate are stated in the change summary; a gate listed here is
not a claim that it passed.

## Follow-up

- Run the `credential-self-service`, `mfa-login`, `admin-account`,
  `account-lifecycle`, `control-room`, `git-mirrors`, `job-history`,
  `maintenance-evacuation`, `repository-launch`, `default-oss`,
  `team-resources` and fleet Porsche NixOS browser checks against the merged
  page and record their results in the scenario ledger.
- Re-run the Antithesis access workload so its `/settings` mount and
  `credential` rename refusal are exercised.
