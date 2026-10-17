# Agent threads implementation review

## Scope and evidence

Review the Marshall agent Ash domain, browser workspace, durable turn and model
loop, VM wake and access rules, Ziggy control transport, host-local Underclass
route, guest `kittens agent-executor`, and guest/host service wiring. Weaver was
studied from the local clone at commit
`b211e71b9c86aeca507323baab7650218688e9c9`.

ADR-0100 is accepted with partial implementation and supersedes ADR-0099's
host-listener transport. ADR-0101 governs browser-approved CLI sessions.
ADR-0063 governs the private guest path, ADR-0081 governs Underclass
credentials, and ADR-0042 governs diagnostics.

## Findings

### Whole-system agent acceptance passed

Marshall now owns PostgreSQL-backed turns, model calls, tool dispatch, child
joins, and recovery. Ziggy pulls model work over its dedicated credential and
the guest executor polls through Audi. Focused database tests cover these
boundaries, and a Ziggy NixOS machine test proves polling, host-local provider
routing, accounting, result delivery, and restart without replay against a
synthetic control fixture. The `agent-fleet` NixOS test now boots Marshall,
Ziggy, Audi and a nested guest with a deterministic model provider. It proves
that an operator-shared prompt wakes a stopped VM, two model calls complete,
the guest executes `read_file`, an audited wake is recorded, and the authorized
member receives the final answer. Its final run passed after `origin/main` was
integrated. The guest service now receives `curl` and `timeout` on its systemd
`PATH`; without them it remained active but could not register.

### Medium: CLI whole-system acceptance remains open

The guest image starts the hidden `kittens agent-executor`, which has no model
state and executes only fenced commands. The desktop `kittens agent` now uses
an explicit browser approval of a hash of its random secret. Marshall stores
only the digest, scopes the session to one VM, rechecks write access on every
request and audits approval. Focused HTTP and LiveView tests pass. A NixOS
machine test executes the packaged CLI against a verified HTTPS fixture,
including digest approval, prompt submission and terminal result. A live
Marshall model turn through this CLI remains untested.

### Medium: claimed provider work can finish uncertain

Ziggy fsyncs its accounting record before provider contact. A model call is
claimed once and cannot be replayed after a lost result. Marshall marks the
turn failed after ten minutes, and a late result from an old placement becomes
uncertain without dispatching tools. This preserves effect safety but can lose
a successful model response. Ziggy retries delivery with the same claim ID up
to three times in one process; a restart after all retries leaves it uncertain.

### Medium: deleted-VM history is owner-visible only

The agent root, thread and events remain after VM deletion. The current owner
can read archived history and prompting is disabled. Former shared users
cannot read archived history; retained shared access needs a separate policy.

### Medium: browser list lacks pagination

The browser loads the root and latest 99 child threads. Direct child URLs work,
but older children cannot be selected through the sidebar. Add keyset paging.

### Medium: some identity constraints are application-level

Unique indexes and SQL checks protect turn order, idempotency, claim state,
payload bounds and model call uniqueness. Cross-table root/thread/turn
identity agreement still relies on coordinators. Add composite foreign keys
before broad service rollout.

## Decisions and verification

The guest accepts only private verified TLS service responses, Audi stamps its
VM binding from the source lease, Ziggy forwards only closed RPCs, and Marshall
checks the current host, placement, epoch, lease, actor access and executor
fence. Child tool calls create actual child turns; separate threads may run
concurrently and their results join the parent's model context. A stopped VM
can be woken by any current write-authorized actor; a deleted VM gets an
explicit unavailable result.

Audit receipts contain identifiers and closed outcomes. Diagnostic events use
the reviewed catalogs and omit conversation and command content. Focused
PostgreSQL tests cover wake authority, queued-prompt isolation, model claims,
tool continuation, two running children, access revocation, claim loss,
relocation, and stale executor fencing. The Ziggy/Underclass and Ziggy polling
NixOS tests pass, including the packaged CLI against a synthetic HTTPS
control and the full `agent-fleet` guest round trip. Marshall and Ziggy
precommit, including Dialyzer, and Python static hooks pass after integrating
`origin/main` at `a450cfda`.
