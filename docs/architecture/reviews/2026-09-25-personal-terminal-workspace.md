# Personal terminal workspace review

Date: 2026-09-25. Scope: machine tabs, automatic opening, shared personal guest
accounts, and guest image integration. User authorization covers implementation,
validation, commit and push. ADR-0117 replaces the relevant portions of ADR-0084,
ADR-0115 and ADR-0116; ADR-0110 identity/retirement requirements remain unchanged.

## Architecture and contracts

Marshall keeps Cedar, stored login, guest identity and opening receipt authority.
Browser guest names cannot choose identities. Guest creation reuses the SSH
reconciler with serialized mutation and a fresh bounded private roster. terminald
reads passwd only after reconciliation; its existing credentials and home handling
remain authoritative. Opening parameters/terminal bytes are not persisted or logged.
The root-only host administrative API remains separate from browser account selection.

The UI state machine controls presentation/retry intent; database receipts control
idempotency. Existing streams, session sharing, single-use tickets, clipboard consent,
execution fences and failed-boot readiness remain intact. Inception roster eligibility
expands without changing SSH login eligibility or allowing bootstrap proofs for tickets.
Management tabs recheck domain authority, and header commands use authorized endpoints.

No substantive contract conflict found in the inspected call paths. Relevant ancestor
and local contracts were reviewed; structural contract/ADR checks alone do not prove
runtime behavior. Authorized VM read projections additionally expose an opaque execution
reference so UI resets follow both relocation and boot generation without publishing
internal placement IDs. No host protocol, schema or capacity policy change is
introduced.

The native browser check exposed a pre-existing ADR-0110 implementation gap:
NixOS did not include the directory containing reconciled sudo policies. This
change includes that directory and uses UID-based policy filenames, because sudo
ignores filenames containing dots. Both legacy and current policies are removed
on retirement. The shared helper property covers dotted names as well.
Follow-up native testing found that Ubuntu Base did not contain sudo. Its required
package set and regenerated authenticated lock now install sudo and sudo-common
from the same pinned archive snapshot. This fulfills the existing ADR-0110 policy.
Manual opening errors also remain visible across periodic refreshes while another
shell is live, until retry or a new execution; the LiveView regression covers this.
The NixOS run's new closed diagnostics identified physical roster proof refusal
at the placement lock. That proof now uses the existing lock's bounded 250ms
contention window, preserving identical boot/confinement checks and renewed
runtime/actor authority. The native lock property also generates that shorter
window; persistent contention and cancellation retain fail-closed coverage.
The terminal and boot-log holders now fill the responsive panel's remaining
height instead of retaining a fixed inner height. This presentation correction
preserves the existing geometry and authorization contracts.
Further browser review found a selection race: when a newly created pane was
already listed before its reply, the hook selected it immediately and again on
the next refresh. A user selection between those events could be overwritten.
The hook now consumes that selection once. A regression test fails against the
old implementation and covers both listing/reply orders. This preserves
ADR-0084/0117's pane interaction and attachment behavior without changing authority.
The next diagnostic follow-up catalogues `terminal.viewer_refused` using closed
reason atoms for authority, credit, acknowledgement and slow-viewer refusals.
Socket stop behavior, authorization checks and credit accounting are unchanged;
terminal contents, tickets and viewer state remain outside diagnostic metadata.
Native execution showed that the terminal process privacy filter also removed
those closed reasons. It now retains only the six explicit atoms for that event;
all arbitrary reasons, messages and process state remain redacted. The viewer
property exercises the actual privacy tag, and filter properties reject private
strings, tuples, unrecognized atoms and reasons attached to other events.

A subsequent isolated native run reached seven live shells before physical
roster proof refusal. Sampled session bindings and owners stayed current, with no
deleted VM; host-report age stayed below five seconds. The roster bootstrap's
placement-lock contention window is now one second. This retains the same native
inode, physical boot checks, post-proof route/command renewals and guest request
deadline. It changes bounded retry latency within ADR-0115/0117, without granting
authority from cached state or changing a protocol. Native verification remains
pending for this follow-up.

Viewer diagnostics now distinguish stored login, session/access, host capability
and writer-permission failures. The checks and close behavior remain unchanged.
The privacy filter permits these four additional fixed atoms; arbitrary reasons
remain redacted. Database-backed tests revoke the login or grant, age the host
report and downgrade the session owner's machine role, asserting both closure
and the corresponding diagnostic.

## Verification

- Focused terminal authority, lifecycle state machine, LiveView and SSH projection
  checks: 24 passed (4 properties, 20 tests). They exercise identity reuse, retries,
  exit, revocation, stopped/read-only machines and execution changes.
- Marshall follow-up `mix precommit`: 982 passed (76 properties, 906 tests), 2 excluded;
  all 23 JavaScript tests passed and Dialyzer reported zero errors.
  Both tab-selection ordering regression tests passed.
- Viewer refusal diagnostics: 2 passed (1 property, 1 test). Generated private
  terminal strings remain absent from logs across authority, output-credit and
  input-acknowledgement refusal paths.
- Follow-up viewer and terminal privacy-filter checks: 5 passed (2 properties,
  3 tests), including tagged process redaction and rejection of arbitrary reasons.
- Diagnostic follow-up Marshall `mix precommit`: 1,001 passed (82 properties,
  919 tests), 2 excluded; all 23 JavaScript tests passed and Dialyzer reported
  zero errors. Python ruff, ruff-format and ty, ADR/contract/logging checks and
  the packaged Nix `hldd` check also passed.
- Lilly `mix precommit`: 407 passed (48 properties, 359 tests), Dialyzer clean.
  Includes Inception roster bootstrap and physical-proof refusal. Earlier runs
  under concurrent build load hit existing elapsed-time assertions; the complete
  gate passed with four schedulers, without changing timing thresholds.
- One-second roster-lock follow-up: focused native lock and roster-bootstrap
  checks passed (1 property, 8 tests). Generated hold times include longer-than-
  250ms contention; retained ownership, stable inode, deadline exhaustion,
  cancellation and durable supersession remain covered. This unit/property
  execution does not establish full guest/browser acceptance.
- The one-second roster follow-up Lilly gate passed: 407 checks (48 properties,
  359 tests), with zero Dialyzer errors.
- Granular authority boundary checks: 15 passed (2 properties, 13 tests).
  Login, session/access, stale host and writer-downgrade closures are exercised
  against sandbox database state; closed-reason privacy properties also passed.
- The full Marshall execution passed 1,012 checks (84 properties, 928 tests),
  with two excluded and zero Dialyzer errors, but the command failed because
  Mix reported the HLDD fixture's `.exs` filename as an undiscovered test.
  Mix 1.20 discovers both `.ex` and `.exs`; changing the extension alone did not
  resolve the warning. The corrected full gate then passed all 1,012 checks,
  all 23 JavaScript tests and Dialyzer with zero errors. Concurrent upstream
  commit `09180940` resolved the same warning by naming the explicitly loaded
  fixture `hldd_helper.exs`; this follow-up adopts that fix and removes its
  redundant exact-file discovery configuration.
- After integrating `09180940`, focused architecture and terminal checks passed:
  51 checks (9 properties, 42 tests), with warnings treated as errors. Packaged
  HLDD, generated topology/options references, contract and ADR checks passed.
- terminald: 38 Rust tests passed; Clippy passed. Lyra's account helper: 11 tests
  and properties passed; formatting and Clippy passed.
- Python `prek run --all-files`: ruff, ruff-format, ty and logging checks passed.
- Browser layout probe passed for tabs, installer/SSH clipboard feedback, mobile
  terminal ordering, overflow, navigation, and light/dark themes. Its disposable
  database fixture does not establish real guest execution.
- ADR and code-contract syntax/discovery checks passed. Contract semantics were
  reviewed across the authority, UI callers, shared allocator and guest reconciler.
- Native NixOS and Ubuntu runs with the bounded lock fix both passed personal
  identity, home, passwordless sudo, account removal/restoration with the same
  UID/home, viewport resizing and fifty personal shells. Earlier roster refusals
  were traced to immediate placement-lock contention through closed stage/reason
  diagnostics. Both distributions subsequently failed the graphics command's
  visible completion-marker assertion; full graphics, reconnect, sharing and
  revocation acceptance remains under investigation. Received byte counts alone
  do not establish whether the completion marker arrived. The fixture now records
  only its synthetic marker's presence and bounded DOM diagnostics, and uses a
  separate bounded graphics deadline. A follow-up corrects the stress workload to
  10,000 images (310,000 bytes), exceeding the 256 KiB transport byte window.
  The follow-up NixOS run did not receive the completion marker before its
  120-second deadline; bounded terminal DOM reads also timed out. A renderer
  probe and the tab-selection fix do not yet establish native graphics acceptance.
  A separate 4 GiB browser experiment failed earlier at clipboard consent after
  a socket closure. Its memory peak was approximately 825 MiB, with approximately
  3.4 GiB available at failure. It did not reach the graphics workload and cannot
  establish the cause of that later failure.
  The next native run failed earlier at the passwordless-sudo marker after a
  socket closure. Two viewer-refusal events were present, but the process privacy
  filter had removed their reasons. This observation motivated the narrow filter
  correction above; it does not establish whether authority or credit was refused.
  With that correction, the next NixOS run emitted `reason=authority` and failed
  the personal identity/home completion marker before reaching graphics. The
  diagnostic classifies the refusal but does not yet distinguish stored login,
  current session/host freshness or writer permission. No acceptance assertion
  has been relaxed.
  The one-second roster retry run failed at clipboard acceptance after repeated
  `reason=authority` socket closures. It emitted no roster-binding refusal, but
  did not reach fifty shells and cannot establish that contention is resolved.
  The subsequent instrumented native run passed account restoration and fifty
  live shells, then failed the graphics completion marker. It emitted
  `authority_host`; sampled host-report age exceeded five seconds, and both
  provisioners later rejected exchanges with `invalid_report`. Session bindings,
  ownership and VM intent stayed current. No roster-binding refusal appeared.
  The renderer stopped servicing bounded DOM probes after 55,790 received bytes;
  this observation does not establish which delay initiated the failure.
  A local synthetic probe through the shipped pane code processed 10,000 images
  in 31-byte chunks in 3.4 seconds, with both buffer and accessibility completion
  markers. This excludes neither native resource pressure nor interactions with
  the real transport, LiveView or host report path. Full acceptance remains open.

## Remaining scope

Existing guest disks require updated
terminald and the account helper; a new Marshall release alone cannot add on-demand
account creation to an older image. Native account restoration has passed on both
guest operating systems; the complete terminal scenario remains under investigation.
Mock tests do not establish VM isolation or fleet
availability.

## Deployment

At the user's request, implementation commit
`04b24b3e3d4499f702808c136370cfd4ec67b545` was committed on main, pushed and
deployed while native testing continued. On 2026-09-25 both Overalls and Dungarees
reported that exact revision as healthy through the normal fleet updater.
Follow-up commit `8bc64092e6003c6489c4c5ee931a9515c7c6a2a2` was also pushed and
deployed; both hosts reported that exact revision healthy, with public readiness
again returning HTTP 200.
Presentation/diagnostic follow-up `831e206e6076f2fc48da9c358539d1b2f2528ce2`
subsequently reached healthy on both hosts, again with public readiness HTTP 200.
Overalls' Marshall, Lilly, Audi private and Ziggy services were active; the public
`https://overalls.dev/health/ready` endpoint returned HTTP 200. Host activation
does not migrate the contents of existing guest disks. Native failures above
remain separate from these service-health observations.
