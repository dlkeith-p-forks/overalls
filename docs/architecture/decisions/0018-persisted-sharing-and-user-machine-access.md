# ADR-0018: Persisted sharing and user machine access

- ID: ADR-0018
- Date: 2026-09-15
- Status: superseded
- Implementation: implemented
- Components: Marshall Access, Accounts, Compute, machine LiveViews
- Supersedes: none
- Superseded by: ADR-0058, ADR-0114

## Context

[ADR-0114](0114-overalls-workspace-design.md) replaces only the default machine-list
landing with an authenticated Overview dashboard; the access requirements below
remain in force.

[ADR-0058](0058-administrative-authority.md) adds persisted administrative
authority while retaining unrelated sharing and archival requirements.

The authorized platform requires signed-in users to provision and share VMs, with
protected ownership and viewer/operator/manager roles. Cedar already evaluates the
role matrix, but caller-supplied test entities do not establish durable sharing.
Manager revocation must remain authoritative when a lifecycle request is waiting
on a database lock or arrives through another Marshall instance.

## Decision

Create an Ash Access domain for grants and immutable sharing request results.
Keep VM lifecycle and reservations in Compute and registered identity in Accounts.
The existing trusted in-process coordinator actor crosses these domains; network
payloads cannot construct it. Ordinary users cannot invoke internal resource reads
or mutations. Explicitly mapped generic actions admit signed-in users, then their
coordinators evaluate fresh record-specific Cedar policy.

Store at most one unarchived grant per VM/member, enforced by a partial unique
index. Role replacement archives the old grant and creates a new grant. Record
who granted/revoked access, and use AshPaperTrail for grant history. Immutable
sharing changes record the requester, recipient, requested role, result grant and
idempotency key. Serialize on the VM row before authorization and mutation.
Identical keys return the original result; changed recipients/roles conflict.
A delayed old grant request cannot undo a later revocation.

Resolve the complete registered email identity, using the same case-insensitive
comparison as account registration. Do not use substring searches or send
invitations. Only the internal account lookup action can read recipients; the
coordinator checks the caller's VM management permission before lookup. Managers
may add/remove managers, including themselves, but cannot change the owner's
access or transfer ownership. Owner authority is intrinsic to the VM, not a grant.

Build each Cedar entity from the owner and the requesting user's current grant.
Do not cache permissions or load every VM member into an authorization request.
Lifecycle checks authorization before locking and again after the host/VM locks.
Grant mutations acquire the VM lock and never acquire a host lock afterward, so
they cannot invert lifecycle's host-then-VM ordering. A waiting lifecycle request
must observe revocation after acquiring the VM lock.

Expose bounded, cursor-based VM and grant views. VM listing filters owned/shared
candidates and evaluates Cedar; detail reads reject unauthorized users. Grant
listing is manager-only and includes protected ownership separately. Public VM
views omit host/pool identity, admission idempotency keys and internal history.
Deleted intent remains readable until archival so its progress can be displayed;
sharing mutations reject deleted intent.

Provide authenticated `/machines`, `/machines/new` and `/machines/:id` LiveViews. Users can see
available admission capacity, choose an available image/profile/size, request
lifecycle changes and manage sharing. Mutations always call the same Ash/Cedar
coordinators, even if a caller forges an event for a hidden control. Preserve form
idempotency keys until success and replace them for subsequent requests. Refresh
views every second using bounded streams; each mutation checks current membership
independently of that display refresh. Redirect a revoked viewer when the next
read fails. Magic-link sign-in defaults to the machine list.

The page describes the role meanings from ADR-0008. Remote terminal relay,
writer leases and terminal-session revocation remain separate required work;
these pages do not yet expose a terminal.

[ADR-0047](0047-audi-ingress-and-authoritative-dns.md) adds a lower `web` role
for Audi application sharing, using this same audited replacement/idempotency
model. Its separate Cedar `web` action includes all existing VM roles but gives
web-only members no VM read/write/manage permission. Management-list candidates
exclude web-only grants before pagination. Replacing a VM role with web-only
access closes existing terminal sessions under the VM lock; SSH authority still
requires VM write permission. The sharing form offers “Web apps only”. This
implements the permission boundary, not Audi browser sessions or forwarding.

## Alternatives

In-memory grants diverge across nodes. Checking roles only in the browser lets
forged events bypass authorization. Updating a grant without an idempotent request
record lets delayed retries regrant access. Locking only the grant row leaves the
first grant and lifecycle authorization races unresolved. Sharing the VM's owner
as an ordinary removable grant violates protected ownership.

## Consequences

Sharing is durable, auditable and consistent with lifecycle across nodes. Grant
and request history consume storage; future retention must preserve idempotency
and audit obligations. Metadata polling adds database reads and needs workload
measurement before large-scale claims. Aggregate available capacity is a current
view, not a placement promise; admission still atomically verifies one host/pool.
The new migration is additive on upgrade; rolling it back removes the new access
history and therefore requires an intentional rollback plan.

## Invariants and verification

- No current grant plus no ownership means Cedar denies VM access.
- Viewers/operators cannot change lifecycle, sharing or ownership.
- Revoked managers cannot commit a lifecycle request after acquiring the VM lock.
- Replays create no additional grants and cannot restore revoked access.
- Archival retains the grant's audit history and allows a new current grant.
- Users cannot enumerate accounts or call internal Ash mutations directly.
- Connected pages recheck permissions; hiding controls is never authorization.
- Validate the permission matrix as properties, three-node races, LiveView events,
  and real browser sign-in/registration and sharing interaction.

## Implementation evidence

[Access domain](../../../marshall/lib/marshall/access.ex),
[grant](../../../marshall/lib/marshall/access/grant.ex),
[request result](../../../marshall/lib/marshall/access/change.ex),
[sharing coordinator](../../../marshall/lib/marshall/access/sharing.ex),
[Cedar mapping](../../../marshall/lib/marshall/access/authorization.ex) and
[migration](../../../marshall/priv/repo/migrations/20260915200839_add_access_grants.exs)
implement durable membership and audit/idempotency.
[Account lookup check](../../../marshall/lib/marshall/accounts/checks/internal_lookup.ex)
protects recipient resolution.
[Lifecycle](../../../marshall/lib/marshall/compute/lifecycle.ex) rechecks stored
membership, and [user views](../../../marshall/lib/marshall/compute/views.ex) expose
bounded authorized data. [Machine pages](../../../marshall/lib/marshall_web/live/machines_live.ex)
connect them to authenticated users. The [console redesign review](../reviews/2026-09-17-web-redesign.md)
records the separate creation page, draft retention and unchanged domain authority.

[Permission properties](../../../marshall/test/marshall/access/sharing_test.exs),
[three-node tests](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
and [LiveView tests](../../../marshall/test/marshall_web/machines_live_test.exs)
exercise these boundaries. The [review](../reviews/2026-09-15-sharing-and-machine-pages.md)
records completed checks and remaining platform requirements.

## Open questions

Remote terminal transport, writer ownership, terminal revocation and current
account-token enforcement are implemented under ADRs 0019–0022. The
[fleet browser test](../../../nix/verification/tests/machines/fleet/browser.py) verifies sharing,
writer handoff, revocation and loss/recovery through the real production stack.
Measure metadata polling at the intended fleet/user load. Production email has
the durable implementation under ADR-0024; supply and verify its actual provider
and deployment configuration before rollout.

## Related decisions

[ADR-0002](0002-elixir-ash-and-types.md), [ADR-0003](0003-control-plane-coordination.md),
[ADR-0008](0008-identity-sharing-and-terminal.md), [ADR-0009](0009-assurance-and-testing.md),
[ADR-0010](0010-capacity-admission-transactions.md),
[ADR-0016](0016-executable-generations-and-lifecycle.md),
[ADR-0017](0017-durable-vm-actors-and-host-ownership.md).
