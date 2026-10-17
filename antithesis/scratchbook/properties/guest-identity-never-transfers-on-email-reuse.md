# guest-identity-never-transfers-on-email-reuse

Priority: P0. Confidence: high in intended persistent identity rule, medium in current physical guest acceptance scope; no new hosted run. Type: safety, with continuity/progress observations.

## Guarantee and proposed assertions

Retiring a User UUID permanently fences its GuestAccount UUID/UID/home and guest credentials. A newly registered User UUID, even with the same released email spelling, must receive a distinct UID and cannot inherit the old user's login, grants, credentials or file ownership. An email edit on the original *active* User UUID must preserve that user's account and access to its own home. Proposed `Always(no_retired_guest_identity_reassignment_or_effect, "Retired guest identity and home never transfer to a replacement account")` over persisted identities and guest-side numeric file-owner witnesses. Proposed `Sometimes(active_email_edit_retains_home_access, "Active guest account reaches its same home after email change")` and `Sometimes(replacement_reaches_distinct_home, "Replacement guest account reaches its distinct home")` are nontrivial progress states, each with a unique message. All planned assertions are missing in `../existing-assertions.md`. ADR-0158 does not promise confidentiality against a separately authorized guest writer with passwordless sudo; a matching name in a UI or a denied API reply is not physical home custody evidence.

## Source and decision trail

- ADR-0158 (`docs/architecture/decisions/0158-durable-guest-identities.md:24-50,59-64,112-128`) explicitly requires immutable User→GuestAccount UUID/UID/`u<uid>`/home mapping, permanent reservations and same-user email continuity. It records old-disk conversion and historical restore as separate gaps, so neither is claimed here.
- `marshall/lib/marshall/accounts/guest_accounts.ex:10-18,21-39,41-76,79-99` locks Users, reuses active accounts and allocates a noncycling UID in 200,000..999,999. `marshall/lib/marshall/accounts/account_lifecycle.ex:99-155,166-175` retires GuestAccount and User in the same transaction, while `:178-187` revokes login tokens and hints.
- `marshall/lib/marshall/editor/CONTRACTS:1-17` requires current stored login, write authority and permanent account/execution binding. `marshall/lib/marshall/editor/authority.ex:80-85,93-125,160-198,201-261` retains exact account identity through approval, cookie exchange, open and renewal, and refuses retired account. `marshall/lib/marshall/access/authorization.ex:11-23` rejects deleted owners.

Accepted decision and contracts are requirements to verify. Existing native scenario references in ADR-0158 are historical scoped evidence, not a new hosted or native run by this research. No present defect is asserted.

## Fault history, independent effect and progress witness

In a fresh owned fixture, create User U and a shared VM with real guest account provisioning. Write a unique marker under `/home/u<uid-U>` through authenticated SSH or terminal and record `stat` numeric UID and guest-side boot/disk identity. A controlled operator fixture may edit U's email through the documented internal `:security_state` action (`marshall/test/marshall/editor_test.exs:131-160`); there is no public email-edit API in ADR-0158. Repeat discovery/editor or terminal admission and require the same stored GuestAccount UUID/UID/home plus successful access to that marker. Retire U through the real administrative path after satisfying its owner-retirement preconditions, lose the response at both sides of commit and reconcile User/GuestAccount/UserDeletion rows. Register fresh User V with U's former email and provision an independent guest identity. Require distinct UUID/UID/home, successful V-owned marker creation, and unchanged numeric ownership of U's prior marker. Before an explicit new grant, V's access to the survivor-owned VM must refuse through each enabled path; after a grant, check identity/owner mapping without asserting secrecy against V's authorized sudo. Old U's stored login/cookie/editor lease must no longer cause a guest effect. The existing native account-lifecycle driver retains the old home in a survivor-owned shared VM and checks the old marker and disabled old login (`nix/verification/tests/machines/account-lifecycle/driver.py:1297-1329`); adapt that owned fixture. If a fixture instead deletes the disk, do not claim physical file isolation from mere absence.

Value menu: email local-part/domain/case edits; same-email replacement; concurrent discovery on two Marshall nodes; retirement response lost before/after commit; SSH, browser terminal and editor where image capabilities allow; NixOS and Ubuntu guest families; UID near configured sequence exhaustion only in a separately owned disposable DB fixture. Do not reset a shared UID sequence. Suggested replay marker: `GuestAccounts.ensure_all!/1` at reuse versus allocation and `AccountLifecycle.retire_guest_account!/1` at retirement, IDs/UIDs only, never email, token or terminal bytes. Hosted real services plus TCG guest can test software-emulated identity; native Firecracker SSH/editor and retained-disk claims need their own machine scope.

## Open Questions

- Which image capability matrix can include editor alongside SSH and terminal for the retained-home scenario? `(partial: account-lifecycle has a NixOS SSH/terminal identity journey; editor is conditional and has a separate native fixture, while one cross-family combined fixture was not found)`

### Investigation Log

#### Which retirement flow preserves a controlled old-home witness?

- Examined: `nix/verification/tests/machines/account-lifecycle/driver.py:1132-1174,1297-1329` and ADR-0158's retirement scope.
- Found: the existing native driver retires an invited user, registers a fresh same-email user, retains the old home in a survivor-owned shared VM, checks its old marker/UID and refuses both old-name and unshared fresh access before a fresh grant. This supplies a concrete fixture pattern without changing retirement behavior.
- Conclusion: resolved; use this pattern, while recording that historical script presence is not current hosted execution.

#### Which configuration covers SSH, browser terminal and editor across guest families?

- Examined: `nix/verification/tests/machines/account-lifecycle/driver.py:790-800,1000-1068,1180-1220,1297-1329`, `nix/verification/tests/machines/vscode-web/guest.exs:125-165`, and `nix/domains/artifacts/guest/default.nix:139-141,197-206`.
- Found: account-lifecycle exercises a retained old home with SSH and browser terminal identities; the editor requires an image built with optional `vscodeWeb`/broker and at least 2 GiB. The editor fixture independently checks a numeric UID-owned workspace. The family and capability should be recorded for each case rather than assuming one image covers every surface.
- Not found: one existing same-email retirement journey combining all three transports on both NixOS and Ubuntu guest builds.
- Conclusion: partial. Start with the retained-home SSH/terminal fixture, add an editor-capable image case, and label family-specific coverage separately.

#### What is the old-home access boundary for a newly authorized replacement user?

- Examined: `docs/architecture/decisions/0158-durable-guest-identities.md:27-50,85-96` and `nix/verification/tests/machines/account-lifecycle/driver.py:1297-1329`.
- Found: ADR-0158 promises noncycling identity and home custody, then explicitly says separate UID/home allocation prevents accidental inheritance rather than confidentiality against another authorized sudo-capable writer. The native retirement fixture denies a fresh unshared user while retaining the old marker; that refusal does not establish denial after an explicit later grant.
- Conclusion: resolved scope correction. Assert distinct GuestAccount UUID/UID/`u<uid>`/home, no inherited credentials or grant, and unchanged numeric file owner. Do not assert blanket inability of an explicitly authorized sudo writer to read the old home.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: pre-cutover UUID/UID ledger and guest home owner/read effect; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R10`: Treat pre/post GuestAccount migration conversion as native/integration acceptance. Antithesis races post-cutover same-user email edit with retirement, reuse, lost reply and real guest identity effects. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
