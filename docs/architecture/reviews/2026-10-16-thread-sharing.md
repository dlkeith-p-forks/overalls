# Thread sharing architecture review

## Decision and scope

The user authorized thread sharing through the existing viewer/operator/manager
ACL model, including corresponding access to the bound machine. ADR-0175 replaces
ADR-0174's creator/team-only authority clauses while preserving its task identity,
provisioning, readiness, lifecycle and retained-history rationale.

This is a substantive architecture change: Threads owns new persisted grants and
immutable sharing results, and those grants become an additional current input
to VM authority. Compute, terminal, editor, SSH and web-ingress consumers must preserve their
independent policies and identity checks. The concurrent visual redesign remains
within ADR-0161; its separate assessment and evidence are in the
[thread review](2026-10-15-user-threads.md).

## Source and authority reviewed

- A grant belongs to the durable thread, survives pending/archive/reopen and
  contributes only through its current machine binding. No copied VM grant may
  become a second canonical source.
- Current Cedar read/write/manage roles preserve protected creator ownership,
  profile refusals and exact-account recipient lookup. A VM-only share must not
  reveal the task or transcript.
- Sharing locks the thread before its current VM and rechecks authority after
  locking. Immutable requests retain replay results after revocation and reject
  changed recipients or roles.
- VM/team grants remain additive. Thread managers intentionally retain machine
  management, including independent VM sharing; thread revocation removes only
  the thread source. UI wording and tests must not promise total revocation.
- Machine visibility, SSH/guest roster hints, terminal and editor access must
  consult the effective current role. Hints confer no authority. Personal guest
  accounts and terminal/session ownership remain separate from VM roles.

The [Grant](../../../marshall/lib/marshall/threads/grant.ex),
[AccessChange](../../../marshall/lib/marshall/threads/access_change.ex) and
[sharing coordinator](../../../marshall/lib/marshall/threads/sharing.ex) persist
one current role per task/recipient and serialize immutable results. The
[thread authorizer](../../../marshall/lib/marshall/threads/authorization.ex)
uses current Cedar roles and rejects noncurrent, archived or mismatched-owner
machine bindings. [VM authorization](../../../marshall/lib/marshall/access/authorization.ex)
merges the grant source; [machine views](../../../marshall/lib/marshall/compute/views.ex)
include its bounded SQL candidates before the final current decision. The
[guest roster](../../../marshall/lib/marshall/ssh/guest_access.ex) retains its
combined 512-account ceiling and fresh write check. Account retirement cleanup
archives canonical thread grants through the resource actions and retains their
history.

The final source review against base `2fc0be43f` found no remaining blocking
production-source finding. Machine projections read current thread grants without
acquiring thread locks, because callers may already hold a VM lock. This is
semantic source review, separate from the bounded runtime evidence below.

The new grants emit existing user/VM hints within the transaction. Source review
confirmed the existing terminal viewer rechecks current session/Cedar authority
on hints, input/resize and its five-second backstop, including write downgrade
closure. Audi dispatches the same hints to HTTP and SSH authorities; editor and
SSH renewal recheck current write authority under their existing thirty-second
leases. Periodic expiry remains the lost-hint backstop. This is source evidence,
not execution of native socket closure for the new grant path.

The manager-only Share disclosure reads a page of at most 50 grants only while
open, keeps the protected owner separate, and retains its server-held request
key until a successful mutation. Role changes or failed reads clear displayed
grant details and editable controls. The machine Access page labels its entries
as direct machine grants and explains the independent thread/team sources.

## Verification and remaining gaps

On 2026-10-16, the focused thread suite passed 111 cases: 109 tests and two
properties, zero failures, seed `332929`, in 24.1 seconds. It ran in the pinned
devenv shell against the isolated `threads_design` PostgreSQL test partition,
with `ERL_FLAGS='+S 2:2'`, `--max-cases 2` and `--warnings-as-errors`. The command,
from `marshall/`, selected these files:

```sh
mix test test/marshall/threads_test.exs \
  test/marshall/threads_lifecycle_test.exs \
  test/marshall/threads_transcript_test.exs \
  test/marshall/threads_machine_key_test.exs \
  test/marshall/threads_sharing_test.exs \
  test/marshall/threads_machine_access_test.exs \
  test/marshall/control/hints_test.exs \
  test/marshall_web/threads_live_test.exs \
  test/marshall_web/editor_workspace_test.exs \
  test/marshall_web/agent_threads_live_test.exs \
  test/marshall_web/machines_live_test.exs \
  --max-cases 2 --warnings-as-errors
```

The sharing role property exercised persisted grants through real Cedar and
PostgreSQL. The database-backed cases covered immutable replay after revocation,
generation continuity, bounded recipient and machine lists, additive VM/team
sources, stale binding refusal, guest roster candidates and retired-user cleanup.
LiveView cases covered current role controls, lost authority, registered-account
sharing, authorized search, newest-first events, the top composer and editor
eligibility. Hint checks include the new grant's invalidation catalog entries.
Synthetic lifecycle and roster observations do not establish native provisioning,
personal-session refusal or transport closure.

On the same date, the maintained browser probe passed 32 route/theme/viewport
combinations, four expanded machine-settings views and four expanded sharing
views. A further 36 collaborator role/state/theme/viewport combinations covered
viewer, operator and manager controls across ready, archived and failed tasks.
Both light/dark themes and 1440/390-pixel viewports passed. The probe observed
newest-first events with the composer above them, authorized terminal/editor
links, current lifecycle controls, bounded filters, protected-owner sharing,
live viewer revocation/restoration and unrelated-account refusals. It saved
148 screenshots across these checks and the existing broad workspace, drafts and
public documentation coverage. Grid, overflow, font, contrast, off-origin request
and browser runtime checks passed.

This is an authenticated browser over synthetic database/VM fixtures. The probe
does not submit an agent prompt, run machine lifecycle actions, open a native
terminal/editor session or demonstrate guest isolation. An earlier attempt
stopped during fixture login and produced no acceptance evidence. Earlier grid
failures were corrected before this passing run. The final browser source
SHA-256 values were:

| Source | SHA-256 |
| --- | --- |
| `marshall/lib/marshall_web/live/threads_live.ex` | `d8f19a04cc5315edb7359c1e9dd6dfea2905227a4f087ca71a1c71f889175696` |
| `marshall/assets/css/workspace.css` | `897c57e364ed015f14932fb91ec2b57f8ae6b9bd8ab6fd7e227868281407383b` |
| `marshall/scripts/monospace_browser_fixture.exs` | `b8f22cad6df655915f563d5fc8f4a2caee2b46e1da225b8bb77178eb6ec912c1` |
| `marshall/scripts/monospace_browser_probe.py` | `e55ca3a2dde6ed11b87226da0fba6cf2f712e95dff75568214100378cc58b663` |

Deployment remains pending at this boundary. Historical thread lifecycle and
production recovery results establish their original scope only.
Native cross-node revocation, active terminal/editor/SSH/web refusal, physical
archive/reopen continuity and broader generated grant/race histories require
separate execution evidence. Previous-generation transcript browsing remains
absent.
