# Terminal attachment authority histories

## Scope and architecture assessment

Improvement 025 begins at `08ae4faa` in its own worktree and branch. The missing
seam is composition of real ticket issuance/consumption with the lifetime of a
real WebSock attachment. Existing fixed authority checks directly invoke Viewer
callbacks; a stop return alone does not prove that a stopped socket cannot revive.

The new generated histories use loopback TCP, Bandit, the production terminal
socket endpoint and Viewer, the real SQL-backed login/ticket/session/Cedar actions,
and monitored connection processes. A fixture supplies upstream authenticated
browser identity and uses the explicit legacy guest-user session fixture with
`root` as its synthetic username; this API does not require administrative
authority or elevation. The histories do not test browser login or personal
guest account creation. Epoch changes are
injected into the VM row while retaining its valid current placement/host/pool;
these histories do not simulate a real relocation. Login revocation uses the
supported locked AshAuthentication JTI action rather than a browser sign-out. Its synthetic relay records every attach/input/resize/detach;
synthetic guest acknowledgements do not establish guest execution, replay,
input deduplication, TLS, native isolation or physical recovery.

Architecture impact: verification and evidence maintenance only. ADR-0083's
per-attachment channels and creator-only writable sessions are preserved; no
exclusive writer lease is introduced. ADR-0082 and the workspace requirements
inherited through ADR-0084 → ADR-0117 → ADR-0125 remain unchanged. Existing
"writer lease/epochs" handbook and campaign wording is reconciled with ADR-0083.
No domain, schema, protocol, authorization rule, service placement or dependency
changes. The user excludes new Inception verification from this campaign.

## Independent oracle and lifetimes

Expected read/write modes derive from generated issued/current roles and explicit
session sharing: current VM read plus creator/shared visibility is necessary;
write additionally needs creator identity, current write, and a writable issued
ticket. Current promotion cannot upgrade a read-only issued ticket. Shared
operators remain read-only. Rejected role paths retain the scoped durable data.
Successful and rejected ticket consumption cannot attach twice. Expired and
foreign-actor tickets close without dispatch; expiry is injected into the issued
ticket row without waiting thirty seconds. Scoped immutable snapshots include VM,
operations, reservations, placements, access grants/receipts/versions, terminal
openings, sessions, sharing grants and their versions. Ticket consumption and
terminal attachment/denial/detachment audit receipts are expected mutable effects.

Every input, resize and idle history visits grant downgrade, login removal, lost
host capability/freshness, execution change and pending kill in generated order.
The checks inspect dispatched effects, a real close frame and monitored process
termination. Idle checks wait for the actual one-second authority timer. They do
not require zero-latency output revocation or call a stopped handler again.
Restored login/permissions/capability need a new socket and ticket; killed or
stale-execution sessions stay refused and require an explicit new session.

The new attachment fixtures use SQL sandbox ownership, including automatic agent
registrations and their history. Bandit and synthetic streams are supervised;
individual client sockets close in failure-safe cleanup. No committed database
reset, production endpoint, native VM or external account is used.

## Existing evidence retained

Improvement 013's two complete NixOS and Ubuntu native journeys on base
`3f679eff`, captured tree `e710ef1e`, retain their exact graphics, personal identity,
replay, whole-Marshall recovery, shared writer refusal and grant/login revocation
scope in the [workspace review](2026-09-25-terminal-workspace-verification.md).
This improvement does not rerun or broaden those native results. The separate
[startup recovery review](2026-09-25-terminal-startup-recovery.md) already covers
generated relay reply aliases, late/duplicate replies and Opening histories;
those tests are credited rather than duplicated.

## Execution and final review

The first attempt exposed a missing synthetic listing response and failed with
stream timeout; the second exposed repeated host fixtures competing for placement
and failed with machine-identity mismatch. Both were fixture defects. Histories
now reuse one sandbox host while creating distinct sessions, and the synthetic
stream retains its listed sessions. These failures establish no product defect.

The corrected initial four properties passed in 31.4 seconds, seed `25001`.
All five attachment properties passed in 32.0 seconds with the same seed after
adding expired/foreign-actor ticket histories. The stale-writer mutant changes only the fresh writer check to accept both modes.
The real resize history detects it: after downgrade, the attachment fails to close
within the three-second receive bound (seed `25002`, 4.3 seconds, no shrinking).
The production source is restored byte-for-byte. The complete Marshall test execution with the expanded inventories passed
1,142 of 1,143 checks (127/128 properties and 1,015/1,015 tests; two excluded),
seed `605897`, in 605.2 seconds. All five new attachment properties passed.
The sole failure is an inherited CLI lifetime generator: drawing three unique
members from a three-element set can hit StreamData's ten-duplicate limit before
constructing its next history. Dedicated improvement 031 owns that repair;
025 does not change the CLI test or conceal this failed full gate. Browser checks
(28 terminal, four dashboard) and workspace TypeScript passed. Forced Dialyzer
passed with zero errors, skipped findings or unnecessary exclusions in 48.45
seconds after the relocated PLT rebuild. The precommit process exited 2 for the
recorded test failure; a final repaired full gate remained pending at that point.

Read-only audit after the isolated focused/mutant executions found zero users,
VMs, terminal sessions/tickets and automatic agent root/thread/audit/version rows.
After the full suite, 63 rows remain in each of the five agent root/thread/audit/
version tables (315 total), matching the inherited fixture-cleanup lead recorded
by improvement 023. Every other agent table and checked terminal/access/lifecycle
row set is empty. These rows are preserved with their exact digests; they are not
attributed to the new sandbox-only attachment helpers or deleted to make a gate
appear clean. The separate inherited cleanup improvement remains responsible.

ADR/HLDD/generated options/coverage/views, contract discovery and all-file prek
(ruff, format and ty included) passed. The Nix `hldd` check passed in seven seconds.
No new native acceptance is claimed. This historical candidate remained
uncommitted pending 031 integration and a passing repaired full gate; the
resumption record below retains that boundary.

## Resumption after generator repair

Integrated published `bb83bfc2fed99e9f0a6d2bccc263d3f671561c8c`, including
improvement 031 (`7a5af2ae`), cache/backup verification and the independent
`951630ee` clone restart recovery. The five-property source and both socket/stream
helpers are byte-identical to the first full gate. The current terminal modules
and authority contracts are unchanged; restart readiness and its additional
cloning checks retain their separate upstream evidence. Documentation conflicts
preserve both upstream and 025 records. No previous failure is relabelled a pass.

Before resuming, all 315 historical agent-history rows matched the frozen
full-table digests. Their exact table/UUID/row-digest manifest is retained so a
subsequent full suite can add separately attributed inherited fixture rows without
obscuring mutation or deletion of the prior set. No database reset is performed.
On the integrated `bb83bfc2` base, all five attachment properties passed at the
original failure seed `605897` in 33.0 seconds. Complete table digests and all 315
historical table/UUID/row digests remained byte-identical. No test data was deleted.

The combined gate additionally incorporates committed 024 implementation
`c26102ac4da062fac4400300aa27e508543d6b8d`. Its host/campaign/item/VM-before-User
lock correction is reviewed and byte-identical to that implementation; 025 changes
no evacuation behavior. Its separate native capture `384b0fa9` is not broadened.
The three 025 test/helper source hashes remain unchanged.

## Passing combined gate and final assessment

The complete Marshall `mix precommit` passed on staged tree
`126d1cf36539a7f2c500b3ee9e158a8a41a75a52`, combining published `bb83bfc2`,
committed `c26102ac` and this improvement. It passed 1,168 checks (131 properties,
1,037 tests), with two exclusions, seed `1676`, in 720.9 seconds. All five
attachment properties passed. The 28 terminal browser checks, four dashboard
checks and workspace TypeScript check passed. Forced test-environment Dialyzer
reported zero errors, skips or unnecessary exclusions in 57.43 seconds after a
25.06-second PLT update. The full gate exited zero.

The unchanged terminal source identities are:

| Source | SHA-256 |
| --- | --- |
| `marshall/test/marshall/terminal/attachment_history_test.exs` | `3ab005476f730d55999d0f99554badc48c7ff742bde134da793a5083cb424725` |
| `marshall/test/support/terminal_attachment_socket.ex` | `14ad24337456dbd984418e14f3aa0cec9991c11ea72fe1254d4a7be363badc66` |
| `marshall/test/support/terminal_attachment_stream.ex` | `13b1da8221a7ef6d29edb2e77c0f785b795cac3b87cb65a1aa565652283d9555` |

The final read-only audit preserves every prior table/UUID/row digest: all 315
historical rows remain unchanged. The combined full suite added 63 rows to each
of the same five agent history tables, for 315 additional rows and 630 total.
The additional rows are retained full-suite residue pending causal attribution
by improvement 029; table counts alone do not identify the owning fixture. The
focused 025 run added no rows, as recorded above. All other audited agent, terminal, access,
lifecycle, user and token tables remain empty. No database reset or deletion was
performed. There are no remaining connections or advisory locks in this test
database and no BEAM processes with this worktree as their working directory.

The combined candidate passed ADR/HLDD, generated options/coverage/views, contract
checks and all-file prek, including Ruff, formatting and ty. Its Nix `hldd` check
passed in 17 seconds. The evidence-only update also passed these governance and
static checks and Nix `hldd` before commit. Its first receipt command rejected an
`updated` disposition without a further chapter change; the reviewed disposition
is `no-impact` because existing handbook claims and their source remain unchanged.
Published 024 merge `2d66e76d` adds integration bookkeeping to the same
evacuation implementation; the coordinator reconciles those notes during 025
integration without broadening either captured native result.

Final architecture and contract review finds no production change or new
architectural decision in 025. The independent mode oracle, one-use tickets,
actual close frame/process termination, production idle timer, fresh attachment
requirement and cleanup preserve the reviewed contracts. Synthetic upstream
browser identity, legacy guest username, epoch/time injection and relay receipts
retain the limits stated above. No new native or Inception validation was run.

## Coordinator integration

Integration with published `2d66e76d` preserves 024's publication review and exact
native scope. Marshall application, test, asset and configuration sources, shared
protocol and Lilly sources match the passing combined tree `126d1cf3`; the three
new terminal source hashes above are unchanged. Publication metadata and reviewed
receipts are the only reconciliation. No production architecture or terminal
contract changes are introduced, and no newer native result is claimed.
