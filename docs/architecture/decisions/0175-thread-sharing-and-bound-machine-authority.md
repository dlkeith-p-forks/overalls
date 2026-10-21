# ADR-0175: Thread sharing and bound machine authority

- ID: ADR-0175
- Date: 2026-10-16
- Status: accepted
- Implementation: partial
- Components: Marshall Threads, Access, Compute, Agents, Terminal, Editor, SSH, Ingress
- Supersedes: ADR-0174
- Superseded by: none

## Context

ADR-0174 introduced durable user tasks above machine-scoped agent conversations.
Its initial read boundary used the creator and team, while machine operations
continued through current VM authority. The user has now explicitly requested
sharing a thread through the existing ACL model and having that share grant
access to its machine. A share must survive archive and reopen, because the
thread keeps its identity while its machine changes.

This decision replaces only ADR-0174's creator/team-only thread authority with
the grants below. Its durable task ownership, idempotency, machine readiness,
generation fencing, deletion, retained transcript and recovery requirements
remain in force. The existing VM role meanings and protected ownership from
ADR-0018 and its supersession chain remain in force.

## Decision

Persist canonical grants in `Marshall.Threads.Grant`, with immutable sharing
request results in `Marshall.Threads.AccessChange`. The creator remains the
protected thread owner. A manager shares with an existing registered account
resolved by complete case-insensitive email; recipient lookup follows current
management authorization. Thread shares accept viewer, operator and manager;
the machine-only web role is not a thread role.

| Thread role | Thread authority | Bound machine authority |
| --- | --- | --- |
| Viewer | Read the task and authorized retained transcript | Existing VM read actions |
| Operator | Viewer actions and submit prompts when ready | Existing VM write actions |
| Manager | Operator actions, thread sharing and thread lifecycle management | Existing VM manage actions |

Current creator/team authority and canonical grants are evaluated through Cedar
for read, write and manage actions. Profile restrictions, current login, account
state and execution fences still apply. The role table grants no access to
another person's terminal session or guest identity. Editor, terminal and SSH
operations retain their personal-account and transport checks. Existing VM-write
permissions include prompt-triggered agent wake; ordinary machine lifecycle
actions still require management authority.

The current thread-to-machine binding projects thread grants into the VM's
existing authorization model. Do not copy grants into machine ACL rows. VM
lists, detail, agent work, terminals, editor, SSH and profile-permitted web ingress
use that current effective
authority. Direct VM grants and team authority remain independent, additive
sources. Revoking a thread grant removes only its contribution; it cannot remove
an independent grant or team permission. A thread manager intentionally has
existing machine-manager powers, including creating independent machine grants.
Conversely, a VM-only grant or machine administrative override grants no access
to the enclosing task or transcript.
Ownership and billing remain with the original creator.

Grants belong to the durable thread in pending, provisioning, failed, ready,
deleting and archived states. A pending share creates no machine prematurely.
Reopen retains the grant and applies it to the new current machine when bound;
retired machine bindings receive no authority from the new generation. Archived
task and transcript reads recheck current thread read authority. Prompt and
runtime access still require their existing live-machine conditions.

Sharing changes serialize on the thread row, then lock the bound VM when there
is one. Recheck current authority after locking; never acquire the thread lock
after its VM lock in the sharing path. This orders grant mutation with binding,
archive and reopen while respecting lifecycle's VM authority. Grant replacement
archives the old grant and preserves its audit history. A repeated request key
returns the original immutable result; changed recipients or roles conflict,
and an old successful request cannot restore a later-revoked share.

Grant changes update the existing machine authorization hints and revocation
paths in the same authoritative workflow. Hints and displayed controls are not
grants. Active transport and personal-session access must recheck current
effective authority; loss of the thread source must not erase a surviving
independent source. Closed diagnostic outcomes and identifiers may be emitted
after commit; emails, prompts and transcript contents remain excluded.

Agent event receipts update the enclosing current user-thread activity clock in
a post-commit projection. This is a redacted list/activity ordering hint, not a
grant or transcript projection: the projection checks the current agent-thread
binding, locks the user-thread row and skips archived or deleting threads.
Sharing and lifecycle authorization remain governed by current thread grants
and machine checks.

## Alternatives

Copying each thread share into a VM grant would create two authorities, ambiguous
revocation and a propagation obligation on every reopen. Sharing only the VM
would lose task-level access before admission and after replacement, and would
expose the task to machine-only recipients. A new role vocabulary would duplicate
the existing viewer/operator/manager policy. Making manager shares unable to
delegate machine access would contradict the existing manager role selected by
the user.

## Consequences

Task access remains stable across machine generations. Machine authorization
must consult one additional current grant source, and bounded machine/SSH views
must include its candidates without treating a candidate as authorization.
Revocation means removal of one source, not guaranteed total loss of access.
Managers can create grants with a different lifetime, which must remain visible
in the existing machine sharing history.

The schema is additive. No shared protocol, host placement or guest isolation
model changes. Current actor checks, personal guest accounts, terminal ownership,
editor leases and execution fencing remain separate requirements. The browser
Share control calls the same domain actions as forged or direct requests.

## Invariants and verification

- A viewer cannot prompt, manage shares or perform machine writes; an operator
  cannot manage thread sharing or thread lifecycle. Existing VM-write actions
  remain available. Owner authority cannot be replaced.
- An authorized thread share grants the corresponding current bound-machine
  actions without creating a duplicate VM grant.
- A VM-only grant does not reveal the thread's objective or transcript.
- Pending and archived sharing survives reopen; old bindings cannot acquire
  current-generation thread grants.
- Removal or downgrade is observed after the row locks and by active access
  paths; independent VM/team grants keep their own authority.
- Replays retain one result and cannot restore revoked access. Changed input
  conflicts without changing grants.
- Machine and SSH candidate queries remain bounded and are followed by current
  Cedar evaluation. Guest identity and personal-session ownership stay intact.
- A durable event advances only its current enclosing thread's activity clock
  after commit; archived or deleting threads and stale bindings do not move the
  clock or acquire authority.
- Use SQL-backed role, replay and binding histories plus native sharing,
  terminal/editor/SSH revocation and cross-node race acceptance. Unit tests alone
  cannot establish transport revocation or physical VM isolation.

## Implementation evidence

The [thread grant](../../../marshall/lib/marshall/threads/grant.ex),
[immutable result](../../../marshall/lib/marshall/threads/access_change.ex),
[sharing coordinator](../../../marshall/lib/marshall/threads/sharing.ex) and
[additive migration](../../../marshall/priv/repo/migrations/20261016010537_add_thread_sharing.exs)
implement the persisted grant and replay boundary. The
[binding index](../../../marshall/priv/repo/migrations/20261016010726_index_thread_machine_binding.exs)
supports current-machine grant lookup without adding a second binding authority.
The
[thread authorizer](../../../marshall/lib/marshall/threads/authorization.ex)
evaluates current task roles and contributes grants only through a current
matching-owner VM binding. [VM authorization](../../../marshall/lib/marshall/access/authorization.ex),
[bounded machine views](../../../marshall/lib/marshall/compute/views.ex) and
[guest roster](../../../marshall/lib/marshall/ssh/guest_access.ex) consume that
source while retaining final Cedar checks.

[Sharing tests](../../../marshall/test/marshall/threads_sharing_test.exs),
[machine integration tests](../../../marshall/test/marshall/threads_machine_access_test.exs)
and [LiveView tests](../../../marshall/test/marshall_web/threads_live_test.exs)
passed in the focused 111-case suite on 2026-10-16 for roles, immutable replay,
generation continuity, additive sources, retired identity and current browser
controls. This suite includes 109 tests and two properties; its database-backed
fixtures do not establish native transport revocation or physical recovery.
The maintained browser probe also passed 32 thread route combinations and
36 collaborator role/state/theme/viewport combinations, including live fixture
viewer revocation and restoration. The
[sharing review](../reviews/2026-10-16-thread-sharing.md) separates source and
bounded fixture evidence from native revocation and recovery acceptance.

Agent tool discovery and reads also use current thread authority:
[`ThreadTool`](../../../marshall/lib/marshall/agents/thread_tool.ex) searches
authorized user-thread titles and resolves retained transcript bindings.
[`ThreadsTranscriptTest`](../../../marshall/test/marshall/threads_transcript_test.exs)
checks shared archived reads, user-thread links, content exclusion from search,
revocation and refusal of internal agent IDs. Focused transcript/executor tests
passed with ExUnit seed 296716 (22 tests); this does not establish subscription,
replay, distributed revocation or native acceptance. Implementation remains partial.

## Open questions

Native cross-node grant revocation across terminal, editor, SSH and web ingress, and grant
continuity through physical archive/reopen, require separate execution evidence.
Previous-generation transcript browsing is implemented through the retained-generation
selector and read-only transcript path; native archive/reopen continuity still requires
separate execution evidence.

## Related decisions

- [ADR-0018: Persisted sharing](0018-persisted-sharing-and-user-machine-access.md)
- [ADR-0022: Current browser login](0022-browser-terminal-and-live-login-checks.md)
- [ADR-0058: Administrative authority](0058-administrative-authority.md)
- [ADR-0153: Personal browser editor](0153-official-source-browser-editor.md)
- [ADR-0158: Durable guest identities](0158-durable-guest-identities.md)
- [ADR-0161: Monospace presentation](0161-monospace-web-presentation.md)
- [ADR-0174: Durable user threads](0174-user-threads.md)
