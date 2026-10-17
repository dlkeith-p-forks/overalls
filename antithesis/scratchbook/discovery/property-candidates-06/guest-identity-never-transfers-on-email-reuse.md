# guest-identity-never-transfers-on-email-reuse

Priority: P0. Confidence: high in intended persistent identity rule, medium in current physical guest acceptance scope; no new hosted run. Type: safety, with continuity/progress observations.

## Guarantee and proposed assertions

Retiring a User UUID permanently fences its GuestAccount UUID/UID/home and guest credentials. A newly registered User UUID, even with the same released email spelling, must receive a distinct UID and must not read or write the old user's guest home through SSH, terminal or editor. An email edit on the original *active* User UUID must preserve that user's account and access to its own home. Proposed `Always(no_retired_guest_identity_reassignment_or_effect, "Retired guest identity and home never transfer to a replacement account")` over persisted identities and guest-side file owner/read witnesses. Proposed `Sometimes(active_email_edit_retains_home_access, "Active guest account reaches its same home after email change")` and `Sometimes(replacement_reaches_distinct_home, "Replacement guest account reaches its distinct home")` are nontrivial progress states, each with a unique message. All planned assertions are missing in `../../existing-assertions.md`. A matching name in a UI or a denied API reply is not physical home isolation evidence.

## Source and decision trail

- ADR-0158 (`docs/architecture/decisions/0158-durable-guest-identities.md:24-50,59-64,112-128`) explicitly requires immutable User→GuestAccount UUID/UID/`u<uid>`/home mapping, permanent reservations and same-user email continuity. It records old-disk conversion and historical restore as separate gaps, so neither is claimed here.
- `marshall/lib/marshall/accounts/guest_accounts.ex:10-18,21-39,41-76,79-99` locks Users, reuses active accounts and allocates a noncycling UID in 200,000..999,999. `marshall/lib/marshall/accounts/account_lifecycle.ex:99-155,166-175` retires GuestAccount and User in the same transaction, while `:178-187` revokes login tokens and hints.
- `marshall/lib/marshall/editor/CONTRACTS:1-17` requires current stored login, write authority and permanent account/execution binding. `marshall/lib/marshall/editor/authority.ex:80-85,93-125,160-198,201-261` retains exact account identity through approval, cookie exchange, open and renewal, and refuses retired account. `marshall/lib/marshall/access/authorization.ex:11-23` rejects deleted owners.

Accepted decision and contracts are requirements to verify. Existing native scenario references in ADR-0158 are historical scoped evidence, not a new hosted or native run by this research. No present defect is asserted.

## Fault history, independent effect and progress witness

In a fresh owned fixture, create User U and a shared VM with real guest account provisioning. Write a unique marker under `/home/u<uid-U>` through authenticated SSH or terminal and record `stat` numeric UID and guest-side boot/disk identity. A controlled operator fixture may edit U's email through the documented internal `:security_state` action (`marshall/test/marshall/editor_test.exs:131-160`); there is no public email-edit API in ADR-0158. Repeat discovery/editor or terminal admission and require the same stored GuestAccount UUID/UID/home plus successful access to that marker. Retire U through the real administrative path after satisfying its owner-retirement preconditions, lose the response at both sides of commit and reconcile User/GuestAccount/UserDeletion rows. Register fresh User V with U's former email and provision an independent guest identity. Require distinct UUID/UID/home, successful V-owned marker creation, and guest-side refusal to read or mutate U's prior marker through each enabled access path. Old U's stored login/cookie/editor lease must no longer cause a guest effect. The existing native account-lifecycle driver retains the old home in a survivor-owned shared VM and checks the old marker and disabled old login (`nix/tests/machines/account-lifecycle/driver.py:1297-1329`); adapt that owned fixture. If a fixture instead deletes the disk, do not claim physical file isolation from mere absence.

Value menu: email local-part/domain/case edits; same-email replacement; concurrent discovery on two Marshall nodes; retirement response lost before/after commit; SSH, browser terminal and editor where image capabilities allow; NixOS and Ubuntu guest families; UID near configured sequence exhaustion only in a separately owned disposable DB fixture. Do not reset a shared UID sequence. Suggested replay marker: `GuestAccounts.ensure_all!/1` at reuse versus allocation and `AccountLifecycle.retire_guest_account!/1` at retirement, IDs/UIDs only, never email, token or terminal bytes. Hosted real services plus TCG guest can test software-emulated identity; native Firecracker SSH/editor and retained-disk claims need their own machine scope.

## Open Questions

- Which guest test configuration can exercise SSH, browser terminal and editor on one retained identity across both guest families, and which checks require separate capability-specific cases?

### Investigation Log

#### Which retirement flow preserves a controlled old-home witness?

- Examined: `nix/tests/machines/account-lifecycle/driver.py:1132-1174,1297-1329` and ADR-0158's retirement scope.
- Found: the existing native driver retires an invited user, registers a fresh same-email user, retains the old home in a survivor-owned shared VM, checks its old marker/UID and refuses both old-name and unshared fresh access before a fresh grant. This supplies a concrete fixture pattern without changing retirement behavior.
- Conclusion: resolved; use this pattern, while recording that historical script presence is not current hosted execution.
