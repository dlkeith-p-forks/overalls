# ADR-0115: SSH roster authority during a verified boot

- ID: ADR-0115
- Date: 2026-09-24
- Status: superseded
- Implementation: implemented
- Components: Marshall, Lilly, Audi, Ziggy, protocol
- Supersedes: ADR-0110
- Superseded by: ADR-0117

## Context

[ADR-0117](0117-personal-terminal-machine-workspace.md) replaces the machine workspace, personal browser
account opening and roster profile portions where applicable. Other decisions
and historical rationale below remain in force.

A production customer clone and its source restart both exhausted their guest
readiness deadlines. ADR-0110 made sshd depend on a current private account
roster. Clone and resize starts require sshd before reporting running, while
both Lilly private attribution and Marshall roster authorization required
completed running execution. Ordinary provisioning bypassed this cycle because
it reports running before guest readiness. The existing cloning fleet used a
guest without the SSH integration.

This decision replaces only ADR-0110's completed-start requirement for roster
retrieval. Its account allocation, Cedar permissions, key/login checks, audit,
revocation and guest security requirements remain in force. The user authorized
implementation, validation, deployment and recovery of the affected machines.

## Decision

Only `GET https://ssh.integration.internal/ssh/v1/roster` with an empty query may
request bootstrap identity. Audi selects this purpose from the verified route,
authenticates to Lilly by Unix peer credentials and derives the guest address
from its transport. Guest headers and payloads cannot supply authority.

The local connector accepts a version-2 request with the closed `ssh_roster`
purpose and returns a binding containing host, VM, placement, execution epoch,
generation and operation ID. Lilly requires a connected runtime and identical
durable start/provision command, plus an owned current boot and running VMM with
verified confinement. Host observation runs outside actor/runtime message loops,
under the placement lock; intent is rechecked after observation and the runtime
route and actor command are renewed before returning. Failure denies access.

Audi renews the same scoped identity throughout forwarding. Ziggy accepts the
extended binding only on the roster route. Marshall authenticates the reporting
host and verifies current placement, epoch, generation, running desired state,
and the exact pending/acknowledged start/provision operation. A completed
operation must have matching successful physical running evidence. Cancelled,
failed, superseded and archived executions deny bootstrap. Roster candidates
still require current ownership/grants and fresh Cedar write permission.

Version-1 bindings retain their existing completed-running requirements.
Bootstrap bindings cannot authorize keys, logins, terminals, inference or other
integrations. Clone/resize guest readiness and capacity-release rules remain
unchanged. No guest image migration or database schema change is required.

Failure diagnostics retain stage/reason atoms and execution identifiers, never
console bytes. Failed-boot cleanup retains the existing bounded private boot
log until the next launch or deletion. Temporary execution/network lock
contention retries without replacing the previous physical observation.

## Alternatives

Removing sshd from readiness would publish guests whose authorized access is
unavailable. Publishing running early for clone/resize would alter completion,
capacity and source restoration semantics. Relaxing ordinary private-service
attribution would unnecessarily broaden bootstrap access. A roster-specific
physical proof preserves these boundaries.

## Consequences

Account reconciliation can break the startup dependency without granting user
access before readiness. Roster calls add bounded physical observation and
operation validation. Deploy Marshall, Ziggy, Lilly and Audi as a coordinated
release; mixed versions fail closed for version-2 requests. Existing version-1
clients remain supported. Retry failed generations through existing authorized
actions, preserving VM/disk identity and historical outcomes.

On-demand terminal account preparation also uses this roster proof. Its physical
check permits up to one second of definite placement-lock contention before acquiring
the same inode and verifying the current boot. This uses the existing bounded
native lock implementation; failure still denies, and no cached proof replaces
the route/command renewals. The personal terminal native run exposed immediate
lock refusal while normal reconciliation held ownership. The initial 250ms window
still produced intermittent refusal while opening many personal shells. The
one-second window retains the helper's existing three-second request deadline;
continued contention, uncertain acquisition and failed physical checks deny access.

## Invariants and verification

- Missing, stale, malformed and changed operation bindings deny access.
- Stopped/fenced execution, lost runtime connectivity or failed confinement
  cannot establish a roster identity; persisted intent alone is insufficient.
- Bootstrap proof cannot enter ordinary private-service or SSH login paths.
- Native NixOS and Ubuntu customer clones restore their source and start their
  destination with SSH active and retained data/account ownership.
- Roster outages delay readiness; recovery within the deadline allows progress.
- Resize restart uses the same safe bootstrap path.

## Implementation evidence

The [binding codec](../../../protocol/lib/overalls_protocol/private_services.ex)
separates extended roster identity from ordinary service identity. The
[runtime lookup](../../../lilly/lib/lilly/control/runtime.ex) renews the actor
route around [physical boot verification](../../../lilly/lib/lilly/vm/driver.ex).
[Audi routing](../../../audi/lib/audi/private/front.ex) and the
[Ziggy relay](../../../ziggy/lib/ziggy/http.ex) restrict the purpose. Marshall's
[roster authorization](../../../marshall/lib/marshall/ssh/guest_access.ex) checks
the exact operation and current Cedar accounts.

The [Marshall regression](../../../marshall/test/marshall/ssh/guest_access_test.exs)
failed before the fix and passes with bootstrap authorization. The
[actor tests](../../../lilly/test/roster_bootstrap_test.exs) cover pending boot,
physical refusal, supersession and disconnection using synthetic evidence.
The [native scenario](../../../nix/verification/tests/machines/fleet/scenarios/ssh-bootstrap.py)
passed on real nested Firecracker guests on both NixOS and Ubuntu: customer
clone/source restoration, resize, a temporary roster outage, full readiness
timeout with retained private logs, and authorized retry preserving placement,
data and account ownership. All five application precommit gates passed,
including forced Dialyzer. The [review](../reviews/2026-09-24-ssh-roster-bootstrap.md)
records exact validation scope and the existing fleet Python typing gap.
Production activated `1f71c785` on Overalls and Dungarees. Both affected original
VMs passed boot-bound guest readiness, and their retained clone request completed
at 2026-09-24 13:26 UTC with unchanged disk identities and historical outcomes.

## Open questions

None.

## Related decisions

[ADR-0110](0110-cedar-guest-ssh-accounts.md),
[ADR-0051](0051-vm-resizing.md), [ADR-0055](0055-queued-machine-cloning.md),
[ADR-0113](0113-guest-trust-at-boot.md), and the
[implementation review](../reviews/2026-09-24-ssh-roster-bootstrap.md).
