# Galileo production acceptance and management repairs

## Final production outcome

The repaired management and Chromium journeys passed on rollout `33b76a25`,
recorded healthy on both physical hosts. Direct and peer requests passed again
after rollout. Bearer, Basic, static headers, query/prefix handling, upload,
credential replacement, actual membership/attachment withdrawal and independent
source/target relocation have scoped production evidence below.

All eight campaign integrations were removed, the fixture team was archived,
the real user's temporary membership was withdrawn, and all four VMs have terminal
`succeeded` / `deleted` receipts under their original cleanup request IDs. The
fixture's browser sign-out was confirmed and replay of its retained browser
credentials refused. The empty fixture account initially remained: its supported retirement
action refused an administrative actor without session-bound recent passkey
elevation. The operator was asked to retire `galileo-1002-fixture@example.test`
through the admin UI. The authorized passkey operation below subsequently completed
retirement through the supported action. No elevation proof was fabricated or
permission weakened.

## Scope and architecture impact

Named Galileo integrations and their Audi, Marshall, Porsche, guest and protocol
dependencies. ADR-0046, ADR-0077, ADR-0079 and ADR-0080 retain accepted decisions.
No persistence, credential custody, execution authority or topology changes.
SSH listing objects restore Porsche's existing map-only success envelope. The
peer flag produces the already accepted boolean wire option; no version change.

## Reproduced defects and repairs

- Production integration/team listings returned `invalid_response` on healthy
  revision `9b150e2a`: Marshall returned arrays where Porsche requires a map.
  Listings now expose `items`/`next_cursor`; `team show` exposes `members`.
- The advertised `--peer` flag was absent from the parser's boolean flag set.
  Generated option-order histories reproduce `invalid_command` and pass after repair.
- Integration/team pagination retained the cursor row and could repeat forever.
  Cursors now exclude it, return empty for unknown IDs and use stable insertion
  time/UUID ordering. Domain array APIs remain unchanged.
- Browser invalid-target submissions crashed instead of showing a refusal.
  `validated!` matched only successful protocol results for targets, strip
  prefixes and static headers. These now roll back with the closed protocol
  reason before persistence. No authorization or accepted validation is relaxed.
- Production Chromium then reproduced browser-local password retention despite
  empty server values and redacted HTML. Every submission now advances the IDs
  of all three password inputs, replacing their DOM nodes on success or refusal.
  The generated LiveView property checks disjoint input identities after each
  refusal; the successful configuration test checks the same replacement.

## Recorded evidence

Before repair, the API property shrank to an empty list and exit 5; the peer
property shrank to `vm-1`; the team API test failed on its empty list. Focused
Marshall API/integration/team execution on seed 0 recorded **38 passed
(2 properties, 36 tests)**. Protocol parser execution recorded **11 passed
(3 properties, 8 tests)**. These exercise PostgreSQL/Ash and Porsche's real
response validator with substituted HTTP transport, not deployed SSH.

Strict production Porsche trust and account discovery passed. Fresh NixOS target
and Customer guests booted and accepted certified guest SSH. Initial source
creation failed bounded ZFS accounting observation; its original failed receipt
is retained. Explicit stop/start restored that same VM. Recovery does not repair
or establish passing initial creation.

A disposable target-guest origin became reachable after opening its guest app
port and configuring public ingress through the ordinary Ash action. The source
reached `galileo-1002-direct.integration.internal` over verified TLS; the origin
confirmed bearer injection. Customer received HTTP 403. Credentials were synthetic.
Basic and static-header injection, replacement of a forged guest Authorization
header, query preservation and a 1 MiB PUT with exact length/SHA-256 passed live.
The upload initially failed because the fixture origin did not decode chunked
framing; fixing that bounded fixture decoder established passing forwarding
without changing the production proxy. A fresh Ubuntu guest also passed verified
TLS bearer injection.
A foreign-owned fixture integration established attach admission and detach
cancellation: source returned 502, one origin connection eventually closed
without retry or origin timeout, and a fresh request was refused with 503.
Reattach restored the bearer probe. Audi's bounded idle timeout can delay final
origin socket closure; this is not immediate end-to-end cancellation evidence.
The first aligned prefix probe returned 502 and a subsequent probe passed;
that transient failure remains recorded rather than discarded.
Five repeated aligned prefix probes then passed; an unaligned prefix remained
intact and received origin 404. Request replay retained one integration ID and
CLI show omitted credential values.
The [acceptance helper](../../../scripts/galileo_acceptance.py) pins the current
Audi key-derived certificate principal and verifies retained UUID/name/ownership
before guest or lifecycle access. The [origin](../../../scripts/galileo_origin.py)
returns flags, digests and socket-closure counters without echoing secrets/bodies.

## Discrepancy and remaining work

ADR-0080 describes attached user VMs and automatic team-member availability.
The existing `galileo-vm-eligibility` contract also permits a personal owner's
VMs without attachments, confirmed live. This repair preserves that contracted
behavior; attachment withdrawal needs a foreign-owned fixture integration.
The ADR/source discrepancy remains explicit; accepted rationale is not silently rewritten.
[Proposed ADR-0134](../decisions/0134-personal-integration-owner-eligibility.md)
records the clarification and attachment-only alternative without changing authority.

Protocol's full gate recorded **222 passed (83 properties, 139 tests)** and
Dialyzer success. Lilly's full gate recorded **468 passed (78 properties,
390 tests)** and Dialyzer success. The Nix `hldd` and `galileo-service` checks
passed on the repair worktree; the latter is isolated native service evidence,
not production relocation or peer acceptance. Python format/lint/type checks pass.

Marshall's initial full run recorded **1394/1395 passed**, including all
**202 properties**. Its sole failure was the existing team-show dispatch test
expecting the repaired array shape; that assertion now checks the members object.
At that stage, passing full-gate reexecution, deployment/retesting, peer transport,
independent-host relocation and cleanup remained separate acceptance steps.
The composed `integration-renewals` run failed in its inherited team SSH setup:
a recognized foreign user correctly received Marshall HTTP 403 and fresh Audi
`forbidden`, but the helper still asserted `unauthorized`. The helper now
requires `forbidden` for foreign, Customer and withdrawn membership cases,
retaining single attempts, exact recognized-key guidance and unchanged ingress
and guest-login receipts. This changes verification, not production authority.
The repaired helper's `integration-renewals` and `galileo-fleet` Nix checks
passed on captured `aea69789` plus the helper correction. This precedes the
additional configuration-validation repair and is not its passing evidence.

The invalid-input property shrank to target `http://a.example.test` and raised
`Ash.Error.Unknown` wrapping a `MatchError` before repair. Domain refusal/no-write
and connected LiveView/refusal properties now record **16 passed (3 properties,
13 tests)**. The browser inspection confirms secrets clear even after the crash;
the defect was missing refusal feedback and socket continuity, not retained
secret values. Deployment/browser retesting remained open at that stage;
the subsequent refusal-path DOM defect and its passing repair are recorded below.
This history does not establish arbitrary provider availability.

## Incremental rollout and renewed browser evidence

The management rollout `e1cb9e4f` became healthy on Overalls and Dungarees.
Deployed integration/team list and team-show object responses passed. A peer
configured with bare `--peer` passed from Dungarees to Overalls, replacing a
forged source identity with the actual source UUID and consuming Authorization
before the origin. Actual team membership withdrawal refused a fresh request
with 503; restoration recovered bearer injection.

Marshall's renewed full gate on `69bf67d7` recorded **1399 passed
(205 properties, 1194 tests), 2 excluded**, with forced Dialyzer reporting zero
errors. The merged validation rollout `95b54709` passed the Nix `hldd` check and
became healthy on both hosts. Production Chromium confirmed generic invalid-input
feedback, but its input-value check then exposed the additional DOM retention
defect above. Redacted HTML alone does not establish clearing browser values.
The replacement repair's focused execution records **2 passed (1 property,
1 test)**. The full Marshall gate on `95b54709` plus the DOM replacement records
**1403 passed (208 properties, 1195 tests), 2 excluded**, including distributed
checks and forced Dialyzer with zero errors. Python format/lint/type checks and
the Nix `hldd` gate passed. This tested application tree became `2ced254a` and
was merged with the current HTTPS acceptance work for rollout `33b76a25`.

The [Chromium helper](../../../scripts/galileo_browser.py) then passed against
production: invalid HTTP target submission shows generic refusal without socket
crash, all three password input values clear, rendered HTML omits their synthetic
secrets, valid bearer configuration clears its input, UI attachment enables a
real source-guest request, and UI detach/removal complete. A final CLI inventory,
direct bearer request and peer request passed on the deployed repair.

The disposable target relocated from Overalls to Dungarees. Its controlled
origin was restarted and its guest firewall rule restored before fresh direct
and peer probes passed. A request during relocation returned 502. Source cleanup
required repeated guarded native deletion retries, exceeded the CLI's 180-second
wait and eventually reached `complete`; routing success is separate from that
cleanup result. A source return request received `insufficient_capacity`.
After native source cleanup released capacity, replaying the source return
request was admitted. It completed with 56 seconds of execution downtime. Fresh
peer, bearer, Basic and static-header probes passed from Overalls to Dungarees;
forged peer provenance and Authorization were replaced/consumed again. Updating
the direct integration replaced bearer with Basic and restored bearer while
retaining its UUID. Eight requests at concurrency four passed; this bounded
sample is not a fleet throughput claim.

Foreign/team integrations were removed through their owner's ordinary domain
actions. Reconfiguration of each archived name refused with `name_unavailable`.
The real user's temporary membership was withdrawn, the exact fixture team was
archived, and all four VM cleanup operations reached terminal deleted receipts.
Direct, Basic, static, strip and peer integration removal verified the retained
UUID, current owner and exact campaign name before each mutation. Browser removal
used its exact fixture account and rendered integration identity. Only the empty
fixture account's passkey-authorized retirement remained open at that stage;
the authorized operation below subsequently completed it.

## Archived-team authority regression

A completion audit found that the existing internal Team archive action contradicts
the old integration source assumption that teams cannot be archived. Retained
memberships allowed admission and renewal after archival; configuration views
and pending peer tokens also lacked a current-team fence. This violates the
fail-closed current ownership requirements of ADR-0077/0080. Shared owner liveness
now reads current non-retired users or unarchived teams, and atomic peer-token
consumption joins the current team row. Refusal leaves pending tokens untouched.
No public archival API, schema or isolation boundary is introduced.

The generated property `archived teams refuse integration admission, renewal,
reads and peer tokens` reproduced credential-bearing admission before repair
(shrunk to unattached direct mode and one attempt). Focused repaired execution
recorded **19 passed (5 properties, 14 tests)**, including the existing three-node
peer-token suite. It varies explicit attachment, direct/peer mode and repeated
refusals, uses actual Ash archival and compares unchanged durable configuration,
credential, attachment, receipt and token state. Property coverage is preferred
for this database authority boundary; it does not establish native cancellation
timing. Marshall's full gate on `6cdf0ae3` plus this ownership repair recorded **1409 passed
(211 properties, 1198 tests), 2 excluded** in 849.1 seconds. Forced Dialyzer
reported zero errors, zero skipped and zero unnecessary skips. The evaluated Nix
`hldd` gate and generated handbook checks passed. New production archival
verification after deployment is recorded below.
A fresh production guest reproduced HTTP 200 after its exact owning fixture team
was archived; a second positive-control team was retained for post-rollout refusal.

## Archived-team production rollout

The repair committed as `74e969d3` was merged with current main, preserving
terminal takeover histories and the namespace cleanup repair and production
evidence. The application/config/shared Elixir source comparison to the
full-gate ownership tree is empty. Merged focused execution on `a86d6537`
recorded **20 passed (6 properties, 14 tests)** across Galileo domain/renewal,
three-node peer consumption and the newly merged terminal takeover history.
Forced Dialyzer again reported zero errors. The final merged evaluated Nix
`hldd` check and generated/reference/ADR/conflict-marker gates passed before
publication of `b96443ff`. Historical native checks retain their captured trees.

Both physical hosts reported `b96443ff` healthy with zero failures. A fresh
real guest's bearer positive control passed while its second owning team was
live. The first team, archived before rollout, changed from HTTP 200 to 503
after rollout. Archiving the second exact fixture team also produced 503.
A trusted token-mint control verified successfully immediately before archival;
another pending token refused afterwards and its unconsumed digest row still
had a future database expiry. This is current owner-liveness evidence, not
a new guest peer-transport or native stalled-stream timing measurement.

Production CLI show, attach, detach and removal returned exit 3 and the closed
`error` / `forbidden` envelope for both archived teams. The initial private
probe incorrectly expected status `failed`; correcting it to the documented
`error` envelope established the complete management refusal matrix. Inventory
excluded both fixture integrations. Exact UUID/name/team-verified rollback
archived only these integrations through the trusted Ledger primitive with
operator attribution; public management correctly refuses a dead owning team.
The two receipt-bound VM deletions are being reconciled under their original
cleanup request IDs. No additional account was created for this campaign.

## Proc-less namespace dependency defect

Source fixture deletion remained accepted with physical stop and retained disk
authority; Lilly repeatedly reported closed `unconfirmed` namespace cleanup.
Read-only inventory failed opening `/proc/self/mountinfo` after entering a
descriptor-held namespace. Repeating the inspection through a proc directory
pinned in the host namespace completed 84 namespace inspections and found one
exact source mount. No unmount, process termination or capacity release occurred
in this diagnosis. The target deletion independently reached a succeeded receipt.

The new native subtest `a retained namespace without proc still permits exact
fenced deletion` reproduced the same `unconfirmed` refusal on placement 105
before the reader repair. Its private child namespace hides proc before the
parent retains its descriptor and reaps that child. Existing late-copy and
visible-proc descriptor stages passed before this failure. The native reader
now opens current self/mountinfo through the pinned host proc directory after
namespace entry, both for planning and immediate pre-unmount reinspection. It
never substitutes a pre-opened host inventory. Exact source/root/path, alias,
readability, race, busy and capacity guards are preserved. ADR-0112 retains its
accepted decision; this corrects availability within its existing authority.

Rust format, six Hegel-backed tests and Clippy passed. The repaired `zfs-namespace-cleanup` NixOS check passed in 563 seconds including
build time, with the proc-less stage, existing busy-file refusal and surviving
guest/process assertions. The before-repair check failed in 338 seconds on the
new proc-less stage with `unconfirmed`. Lilly's full gate recorded **468 passed
(78 properties, 390 tests)** and zero Dialyzer errors/skips. Marshall's focused
handbook/ADR regression suite recorded **39 passed (8 properties, 31 tests)**.
All-file prek gates, including Python format/lint/type checks, and the evaluated
Nix handbook gate passed. The live
acceptance helper also now gives the 180-second server wait 30 seconds of
transport grace, persists accepted timed-out receipts, reports pending cleanup
with exit 4, and reconciles terminal receipts under their original UUID/name
and request ID without requiring a deleted guest to remain readable. No timeout
is a cancellation or physical cleanup result.

## Native repair production verification

Repair commit `3f70bfa5` reached main through `b9790a5c`, preserving concurrent
terminal-history, SLO freshness and audit-recovery changes. The merged Marshall
checks passed **28 checks (9 properties, 19 tests)**; Lilly's generated recovery
and terminal histories passed **six properties**. Both forced Dialyzer checks
reported zero errors and skips. Generated handbook, ADR, view, conflict-marker
and evaluated Nix handbook gates passed. Native helper, namespace fixtures and
acceptance cleanup source matched the previously passing repair exactly.

Both physical hosts recorded `b9790a5c` as activated and last healthy with zero
failures. Overalls subsequently began building the next upstream revision;
the cleanup below ran while `b9790a5c` remained activated. Reconciliation of
`galileo-1002-archive-delete-source` and `galileo-1002-archive-delete-target`
returned succeeded receipts for their original UUIDs and names.
Source cleanup completed through normal reconciliation after activation; no replacement request,
force/lazy unmount or process termination was used.

An independent read-only audit scoped to these two UUIDs verified desired and
observed deleted state, archived VM rows, and all compute/disk/startup reservation
hold bits released. Both exact placement datasets and canonical mount paths were
absent, their VMM units inactive, and the parent ZFS pool remained readable.
The campaign's integrations and teams were already archived. At this stage the original empty
fixture account still awaited supported session-bound passkey retirement; proposed
ADR-0134 remains unresolved. This evidence establishes recovery of the observed
proc-less cleanup failure, without arbitrary namespace churn or hosted load claims.

## Authorized passkey retirement, 2026-10-03

The operator explicitly authorized sudo and database updates for passkey
operations. A scoped temporary P-256 public credential was inserted for the
existing administrator, retaining operator attribution and a passkey-add audit.
A fresh stored login and genuine ECDSA WebAuthn assertion passed the normal
challenge verification action, producing its session-bound elevation receipt.
The supported `delete_user` action then retired only the exact empty fixture UUID
`0746b89b-56e8-4dab-9323-2a65fc1da34a`, with its exact email confirmation.
Neither account policies nor verification deadlines were changed; no verified
receipt was seeded or forged. This is an authorized software authenticator
operation, not a physical passkey or browser UX measurement.

Fixture retirement completed with zero remaining VMs and blocked=false.
Independent readback confirmed deletion receipt
`a6ad28ae-1dcf-417a-83ae-b4394c9613ae` completed and retained the real initiating
administrator. The temporary credential was removed and its session revoked;
the original administrator's one passkey, MFA generation and flags were unchanged.
Early operator attempts exposed missing endpoint URL initialization and an
incorrect COSE byte representation; both were corrected in the private operator
script. Every temporary credential was removed. Both early failed attempts'
pending logins were identified by exact account and creation/primary timestamps
and separately revoked through the supported token action. An independent query
confirmed zero user-purpose tokens from the operation window and zero temporary
credentials. No temporary login
or authenticator remains usable. The campaign's account cleanup is complete.
ADR-0134 remains a proposed clarification of existing personal-owner eligibility;
its unresolved policy alternative is separate from this completed cleanup.
