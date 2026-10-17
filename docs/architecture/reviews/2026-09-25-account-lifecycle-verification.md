# Account lifecycle verification

## Scope and architecture impact

Campaign improvement 009 preserves ADR-0066's accepted invitation, immediate
retirement, fresh identity and physical cleanup requirements. It adds verification
through existing Ash actions and packaged services. No production schema,
protocol, dependency or authority policy changes are made. ADR-0077
continues to require separate committed transfer/retirement race acceptance.
ADR-0123 supplies the remembered-browser authority contract inherited through
ADR-0119. Published campaign007 (`5bce9478`) is incorporated before native
execution; a positive remembered resume precedes copied-cookie refusal.

The user authorized isolated tests, defect fixes and incremental commit/merge/push;
no production deployment or live destructive acceptance is performed.

## Allowed, refused and recovery paths

- An elevated administrator invites an eligible address; only explicit verified
  link consumption creates its ordinary identity.
- Rejected ordinary, self and mismatched retirement preserve existing records,
  credentials, membership, reservations, operations, audit and deletion receipts.
- Accepted retirement revokes old login authority immediately and retains the
  historical UUID. Old email links cannot resurrect it.
- A new verified same-email registration receives a new UUID while old cleanup
  remains pending. No previous administrator role, passkeys, keys, membership,
  sharing or machines are inherited.
- Cleanup retries retain one deletion receipt and one physical delete operation.
  A busy resize or unavailable host cannot release disk holds or complete the
  receipt. Native recovery must remove the actual owned dataset and VM process;
  shared-only workloads survive.

## Independent oracle and contract review

The generated test tracks identity generations, stale links and pinned deletion
receipts separately from coordinator state. Every generation acquires real
synthetic P-256 registration/assertion, a registered SSH key, an ordinary team
membership and sharing of a survivor-owned VM before retirement. Some generations
are separately promoted. Refused actions compare full persisted projections for
the target, administrator and ordinary requester, including existing authority
values and history/version inventories. Tests never infer unchanged state merely
from row counts.

Synthetic physical outcomes establish only coordinator admission and accounting.
The native test uses actual source-built services over verified HTTPS, three
Marshall machine instances, two nested-KVM/ZFS provisioners and a browser virtual
authenticator. Its separate unused administrator completes bootstrap before any
user login. The invited user is created only through the browser invitation.
Prior team membership is established by the generated histories; the native
journey does not claim a Teams-owned workload or integration boundary.

Encrypted disposable outbox access writes tokens to mode-0600 files. Browser
token interactions and the fixture operator suppress exception data and login
URLs. No external SMTP delivery is claimed. The native resize barrier waits only
at fixture dispatch after the operator runtime has started; it does not supply a
production lock, fabricate host freshness or forge physical evidence.

Root, Marshall/test, Accounts, Nix/tests and handbook contracts were reviewed.
New notes make the generated oracle, private token handling, installed bootstrap,
strict native boundary and real resize admission explicit. The architecture view
inventory is unchanged: tests add no production domain, resource, host or service.

## Execution record

Focused lifecycle tests passed: 11 passed (1 property, 10 tests), seed `9009`, 14.5 seconds.
It executed twelve histories with two or three retired identity generations each.
Earlier runs exposed fixture mistakes: an ineligible overlong local email name,
a nonexistent Reservation history read action and delivery of synthetic cleanup
evidence to the original fixture host when placement had selected another active
history's host. The final test uses the admitted VM's actual host identity.

A subsequent focused run tightened the refusal oracle to exact forbidden,
confirmation-mismatch and self-deletion errors: 1 property passed with twelve
histories, seed `9009`, 10.2 seconds.

The focused run includes the final token-purpose and persisted-inventory projections
after integrating published campaign008 (`0ffb0754`). The first native driver
build passed composed Python type checking and linting. The manual browser check
passed with an explicit source path. Review initially attributed that result to
project include exclusions; a separate invalid-return probe showed that explicit
paths override the include list, so that exclusion explanation was incorrect.
The browser helper was also copied outside the repository and passed
`ty check --project` against its packaged Python/Playwright environment. A return-type mutant in that temporary
copy failed with the expected `invalid-return-type` diagnostic; the source copy
was restored. The native derivation enforces this separate copy-out helper check.
The integrated Marshall `mix precommit` passed at published main `5bce9478` plus
009: **1,040 passed (98 properties, 942 tests), two excluded**, seed `181537`,
414.7 seconds. Forced Dialyzer reported **0 errors, 0 skipped and 0 unnecessary
skips**. The copied worktree PLT was relocated and rebuilt before forced analysis.
ADR, contract, HLDD options/coverage/views, Nix HLDD and all-file prek gates passed.

Preflight inspection of immutable guest
`/nix/store/03whj0x446v01pf2sa8l0qwlbwksyl30-lilly-nixos-x86_64/manifest.json`
found a minimum disk of 3,725,295,616 bytes. The browser Customer and both OSS
requests use 4 GiB; the checked browser artifact now rejects an image whose disk
or memory minima exceed those fixture requests before native boot. Resize retains
that disk and grows memory from 512 MiB to 768 MiB.

The first native execution used derivation
`/nix/store/bvzgyhnw6xpibikbghkw24i04rc29v3c-vm-test-run-kittens-account-lifecycle.drv`.
Fleet boot, authenticated capacity, browser invitation/signup, ordinary authority,
WebAuthn, SSH registration and positive remembered resume passed. Both real guests
reached running. The transient resize fixture then exited 127 because its systemd
PATH omitted `mkdir`; the dispatch barrier timed out after 90.02 seconds. No
resize admission, retirement or cleanup acceptance is claimed from that run.
All test machines were terminated; cleanup completed in 3.62 seconds. The driver
now supplies the installed-system PATH and fails promptly if the fixture service
fails before dispatch.

The next native candidate, derivation
`/nix/store/y5rg9z4snfs9zmdrgmxzyjdv831k67ca-vm-test-run-kittens-account-lifecycle.drv`,
passed boot (54.79 seconds), authenticated capacity/private services (131.63 seconds)
and the browser registration/remembered phase (30.14 seconds). Both guests ran and
the corrected resize fixture reached its real dispatch barrier. The driver then
waited for a sample less than one second old. Source review established that this
fixture condition was impossible: `Lilly.Host.Collector` timestamps before
`Lilly.Host.ZFSIO` performs its mandatory one-second native interval, and Marshall
retains that sample start. The run was stopped before stopping Lilly or admitting
resize. The Nix command exited after interruption and process inspection confirmed
no test-driver or QEMU machine processes remained; no timed Python cleanup result
is claimed for this cancellation.

The driver now waits for an advanced real report sequence with sample age under
three seconds, checking that the dispatch fixture remains alive. This leaves time
within the existing five-second public admission window; no host timestamp,
production timeout or workflow state is replaced. The wait is bounded to ninety
seconds within the fixture's existing two-minute barrier. That correction awaited
full native verification, recorded in the final run below.

Published resize improvement 010 (`6f58ef65`, candidate `5677ad02`) is integrated.
Its production change renders confirmed fractional disk sizes with the existing
exact formatter; no account authority or resize admission behavior changes. Both
independent typed native drivers and browser checks remain wired. The combined
Marshall `mix precommit` passed: **1,042 passed (100 properties, 942 tests),
two excluded**, seed `637918`, 470.5 seconds. Forced Dialyzer reported **0 errors,
0 skipped and 0 unnecessary skips** in 1m4.06s. All-file prek passed, including
Ruff format/check, ty, logging and handbook review. The combined native driver
`/nix/store/20i7m9kn8s31lj5i1i181pmlc4p5l2f6-nixos-test-driver-kittens-account-lifecycle.drv`
passed its composed type and lint checks. The third native run used captured derivation
`/nix/store/ipq22rp9kjmja16a4ri9ny1v1m1zhkqg-vm-test-run-kittens-account-lifecycle.drv`.
It passed fleet boot (65.62 seconds), authenticated service setup (101.78 seconds),
browser invitation/registration/remembered resume (26.40 seconds), offline busy
resize plus typed retirement and stale browser authority refusals (87.99 seconds),
and fresh same-email identity with a new running guest before cleanup (62.48 seconds).
Three cleanup retries retained the owned dataset, active guest and disk reservation
with no delete operation. Recovery physically stopped and resized the owned
Customer guest, then waited in restart before launching a new process.

The fixture had restarted Lilly alone. The real `audi-private.service` has a
`Requires=lilly.service` dependency and stopped when Lilly stopped; starting Lilly
alone does not start that dependent frontend. Lilly correctly withheld guest
restart because its private service readiness predicate was false. The exact Nix
build client was interrupted once this cause was identified. It exited 1, and
process inspection confirmed no test driver or QEMU machine remained. No timed
Python cleanup result or completed physical reclamation is claimed for this run.
The recovery fixture now starts both actual services and waits for real Ziggy and
Audi readiness responses. Public readiness, execution and capacity policy remain
unchanged. The corrected complete execution is recorded below.

The run also observed repeated `account_guest_accounts_username_never_reused_index`
refusals for the fresh identity's guest roster on Lilly l2. ADR-0110 permanently
reserves the old email-derived guest username and forbids assignment to another
UUID. ADR-0066 permits a fresh application identity with the same email; that does
not establish guest SSH usability. The new guest's observed running state is not
proof of successful roster reconciliation or SSH. The fixed privileged network probe in the corrected run below establishes only
guest egress and survival through old cleanup.
This accepted-design interaction needs a separate user-facing resolution; no
username is reassigned or fence weakened in improvement 009. The retired account's
Customer resize was on l1 and stalled before a new unit launch due to the omitted
private frontend, independently of l2's username collision.

## Final native execution and assessment

Native account lifecycle passed in 470.00 seconds; nine-machine cleanup completed in 3.56 seconds.

The immutable run derivation was
`/nix/store/99gak2mx2igljakm8jw1fhlxhpxdsg6r-vm-test-run-kittens-account-lifecycle.drv`,
with strict driver
`/nix/store/wgmjmvvd8za2gnnvl79apgg55czbxkwq-nixos-test-driver-kittens-account-lifecycle.drv`
and output
`/nix/store/hqj83d5fzqqxfw9gn58jyvrx95kasdab-vm-test-run-kittens-account-lifecycle`.
The Nix command exited zero. The driver recorded all nine QEMU terminations.

The complete run passed installed bootstrap, ordinary invitation and explicit
registration, virtual WebAuthn, SSH-key registration and positive remembered
resume. Wrong typed confirmation left the account active with no deletion receipt.
Accepted retirement revoked the mounted browser, a full cookie copy, remembered-only
cookies and the earlier email link. Three cleanup retries preserved the real
Customer dataset, active process and disk hold while resize was busy and Lilly
unavailable, with no delete operation.

The replacement account had a different UUID and no inherited administrator role,
MFA, keys, passkeys, grants, membership or VM ownership. It acquired its own real
OSS workload before old cleanup. Restoring Lilly and the dependent Audi frontend
allowed resize to finish. Cleanup then archived the old owned VM, removed its
actual ZFS dataset and active VM service, released disk/compute holds and retained
exactly one delete operation. The survivor-owned shared VM retained the same ZFS
GUID and process PID; fixed live guest probes confirmed egress from both surviving
workloads. The fresh browser remained usable after cleanup. Its known guest-roster
username conflict remains explicit; these probes do not establish fresh-user SSH.

Final architecture assessment: ADR-0066, ADR-0110/0117 and ADR-0123 authority,
isolation, identity and cleanup decisions remain unchanged. Test fixtures use
existing actions and real service dependencies, with no production source change.
Domain/resource ownership and deployed topology are unchanged. The substantive
new design gap is tracked as campaign 018; remaining distributed retirement races
retain their separate scope. Final documentation only records this exact execution.

## Remaining gaps

- Fresh same-email accounts cannot acquire the retired UUID's permanently reserved
  guest username under ADR-0110. A separate design follow-up must reconcile the
  guest workflow and clear user guidance with ADR-0066, preserving old homes and UIDs.
- Full `delete_user` overlap with Teams ownership transfer and membership changes
  across independent Marshall processes remains a separate improvement.
- Generated coordinator evidence does not prove native isolation; the bounded
  native journey does not establish every interruption or host-failure ordering.
- Native virtual authenticators do not establish hardware-device compatibility.
- Isolated outbox extraction does not establish SMTP delivery or inbox receipt.
- Three Marshall VMs on one physical test host do not establish independent
  physical failure domains or production deployment acceptance.

- Source review identified a separate, unconfirmed credential race lead:
  `SSH.KeyActions` serializes key owner/fingerprint but does not acquire the
  account-admission fence. Existing inactive-actor checks may still prevent
  authority. A separate credential improvement must reproduce public key
  registration/retirement overlap and inspect key reuse and cleanup before
  classifying any defect; this change claims no result for that race.
