# ADR-0193: Per-user machine pins and the owner-pin deletion guard

- ID: ADR-0193
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: Marshall Access and Compute domains, MarshallWeb, Marshall SSH commands, shared protocol command catalog, Porsche client
- Supersedes: none
- Superseded by: none

## Context

Users keep a handful of machines that matter beside many short-lived ones. The
machine list and the overview order by id, so the important machines drift down
the page, and nothing stops a tired owner, a shared manager, an administrator in
Fleet workloads, a Porsche `rm` or a thread teardown from deleting one of them.

Observed facts:

- Every user, administrator, SSH/Porsche and thread delete reaches
  `Marshall.Compute.Lifecycle.execute/2` and `enqueue_locked!/5` under the host
  and VM row locks ([ADR-0074](0074-durable-lifecycle-state-machines.md) lineage;
  `lifecycle-generation-transaction`). Account deletion uses the same path through
  `delete_for_account/2` with a `deletion_id` context.
- VM archival happens at exactly two sites, `Marshall.Compute.Outcomes` and
  `Marshall.Compute.RelocationDeletion`, both inside the archive transaction.
- Machine views (`Marshall.Compute.Views`) page by id with a keyset cursor and
  make a fresh Cedar read decision per row (`views-bounded-current-access`).
- Porsche's command catalog is the shared `OverallsProtocol.SSHCommand`
  ([ADR-0046](0046-porsche-ssh-management.md)); refusals cross the wire as closed
  reason atoms and Porsche refines only a predefined set into exit classes.

Assumption: a pin is a personal ordering preference, so it belongs to a user,
while the deletion fence must belong to the machine's owner, because the owner
is the only principal whose consent deletion already requires.

## Decision

Accepted on 2026-10-18 under the user's request for per-user pins that keep
pinned machines first and make an owner-pinned machine undeletable, including
through Porsche.

1. **A pin is a per-user Access resource.** `Marshall.Access.Pin`
   (`machine_pins`) belongs to a user and a VM, carries an AshStateMachine
   `state` of `pinned` or `unpinned` (`unpin` and `repin` are the only
   transitions), `pinned_at` for ordering, AshArchival and PaperTrail. The
   identity `current_pin` on `(user_id, vm_id)` where `archived_at IS NULL`
   keeps at most one live row per pair; repinning reuses the row. Removal when
   the machine is archived is a soft delete (`remove`), never a state.
2. **Pins are coordinated, not written by users.** `Marshall.Access.Pins` runs
   `pin_machine` and `unpin_machine` inside `Ledger.transaction`: a per-user
   advisory lock, the VM row lock shared with lifecycle, a fresh Cedar `read`
   check for pinning (`vm_deleted` for deleted intent or an archived row,
   `machine_failed` for a machine whose observed state is failed — amended
   2026-10-18: an existing pin on a failed machine stays and can be unpinned),
   the locked pin row, and a cap of 20 pinned machines per user (`pin_limit`).
   Pinning a pinned machine and unpinning an unpinned one return the row
   unchanged. Unpinning needs a live row but not current read access, so a
   user whose access ended can still clear the pin. Changes emit `vm.pinned`,
   `vm.unpinned` and `vm.pin_refused` after commit (ADR-0042 catalog).
3. **The owner's pin fences deletion.** In `enqueue_locked!/5`, a `delete`
   request is refused with `machine_pinned` while the VM owner holds a live
   `pinned` row. The check runs under the VM lock after the existing
   authorization, clone, resize, relocation and deleted-intent checks, so it
   covers the browser, Fleet workloads, SSH `rm`, Porsche and thread deletion
   alike. Other users' pins never block deletion. Start and stop are not
   fenced. Relocation source cleanup reclaims a copy, not the VM, and is not
   fenced.
4. **Account deletion is the one exception.** When the request carries a
   `deletion_id`, the departing owner's own pins on that VM are archived in the
   same transaction before the guard runs; the owner retiring the account is
   the consent. Account cleanup also archives the user's pins on other
   people's machines.
5. **Archival removes every pin.** Both archive sites call
   `Pins.remove_for_vm!/1` before `Ledger.archive!(vm, :archive)`, so no live
   pin row outlives its machine. By then the delete was admitted, so only
   non-owner or retired-owner pins remain.
6. **Pinned machines come first.** `Views` gains a `pinned` operation (the
   caller's pinned rows, newest pin first, at most the cap, same per-row Cedar
   read and the same projection) and `list_for_user` gains an `exclude`
   argument (at most 20 ids). The machines page shows the pinned section on
   its first page and excludes those ids from every keyset page; the overview
   fills its six slots with pinned machines first. The view exposes the
   caller's own `pinned` flag; the SSH `ls`/`show` wire view drops it, so the
   Porsche JSON contract is unchanged.
7. **Porsche pins too.** The shared catalog gains `pin MACHINE` and
   `unpin MACHINE` as non-physical mutations resolved like `rm`; they answer
   with `{id, name, pinned}` and replay idempotently by request id. `rm` on an
   owner-pinned machine answers the closed `machine_pinned` reason, and Porsche
   refines `machine_pinned` and `pin_limit` as named conflicts with a fixed
   next-step hint. `ls` gains no pinned indicator because that would change its
   wire shape.
8. **The browser follows the Monospace Web** ([ADR-0161](0161-monospace-web-presentation.md)):
   a text `Pin`/`Unpin` control with `aria-pressed`, a `[Pinned]` label, and a
   disabled Delete with "Unpin to delete" when the owner has the machine
   pinned. The server-side guard remains the authority.

## Alternatives

- **A `pinned` flag on the VM.** One flag cannot be per user, and it would
  make a shared user's preference block the owner. Rejected.
- **A lock separate from the pin.** Two concepts for one user action; the
  user asked for pin to imply protection. Rejected; the guard reads the owner's
  pin state directly, so no second resource or state is needed.
- **Blocking deletion for any holder's pin.** A viewer could then hold an
  owner's machine hostage. Rejected: only the owner's pin fences, which matches
  who already consents to deletion.
- **Refusing account deletion while pins exist.** That would leave retired
  accounts with undeletable machines and no actor able to unpin. Rejected in
  favor of archiving the owner's pins in the delete transaction.
- **Guarding in each caller** (LiveViews, admin page, SSH, threads). Rejected:
  the lifecycle coordinator is the single admission point every path already
  uses, and it holds the VM lock the pin coordinator also takes.
- **Sorting the keyset page by pin.** A per-user join in the cursor would
  change cursor semantics and make pins visible in other users' ordering.
  Rejected for a separate bounded pinned section plus exclusion.
- **A pinned column in Porsche `ls`.** Rejected because the response field set
  is a pinned wire contract; the information is available through the browser.

## Consequences

- An owner can never lose a pinned machine to a stray delete from any surface,
  and a shared manager or administrator sees a fixed refusal naming the pin.
- Deletion gains one indexed read under the VM lock; pinning takes the VM lock,
  so a pin and a delete for the same machine serialize. The per-user advisory
  lock serializes a user's own pins so the cap holds under concurrency.
- Account deletion carries one more cleanup step and cannot be blocked by pins.
- The pinned section adds at most 20 authorized rows to each list refresh and a
  one-row pin read per projected machine.
- The Porsche catalog grows by two commands; the protocol change needs both
  consumer gates, and Porsche's refined conflict set grows by two names.

## Invariants and verification

- At most one live pin row per user/VM pair; repin reuses it
  (`pin-single-live-row`, Hegel model property, Covenant I5).
- Pinning requires current read access and a live, non-deleting VM; the 21st
  pin is refused; repeats are unchanged (`pin-current-read-access`,
  `pins_test.exs`).
- Delete is admitted iff the owner's pin is absent at that moment, through the
  domain action and the SSH `rm` path, and a refusal changes no intent or
  operation (`lifecycle-owner-pin-guard`, `pin-owner-delete-guard`, Hegel guard
  history over the real actions).
- Account deletion proceeds past the owner's pins and archives them
  (`pins_test.exs` account deletion case).
- After the deleted outcome, no live pin remains and the VM is archived
  (`pin-removed-on-archive`, guard history tail).
- Pinned section plus excluded pages yield each authorized machine exactly
  once, pinned first (`views-pinned-section-bounded`, Hegel pagination
  property, LiveView tests).
- SSH `pin`/`unpin` are idempotent, `rm` refuses `machine_pinned` while pinned
  and succeeds after `unpin`; `ls`/`show` carry no `pinned` key
  (`ssh-pin-commands-idempotent`, `commands_test.exs`); the protocol parses
  only `pin`/`unpin MACHINE` (`ssh_command_test.exs`); Porsche classifies the
  two reasons and adds its hint (`client_test.exs`, `runner_test.exs`).
- Refusals are closed reasons in the SSH 409 set and Porsche's refined set
  (Covenant `marshall.compute.I4`).

## Implementation evidence

- Resource and coordinator: [`pin.ex`](../../../marshall/lib/marshall/access/pin.ex),
  [`pins.ex`](../../../marshall/lib/marshall/access/pins.ex),
  [`access.ex`](../../../marshall/lib/marshall/access.ex),
  [authorizer](../../../marshall/lib/marshall/authorization/ash_authorizer.ex),
  migration `20261018092851_machine_pins.exs`.
- Guard and cleanup: [`lifecycle.ex`](../../../marshall/lib/marshall/compute/lifecycle.ex)
  (`admit_delete_with_pins!/2`), [`outcomes.ex`](../../../marshall/lib/marshall/compute/outcomes.ex),
  [`relocation_deletion.ex`](../../../marshall/lib/marshall/compute/relocation_deletion.ex),
  [`delete_user_machines.ex`](../../../marshall/lib/marshall/accounts/delete_user_machines.ex).
- Views and web: [`views.ex`](../../../marshall/lib/marshall/compute/views.ex),
  [`workspace_components.ex`](../../../marshall/lib/marshall_web/components/workspace_components.ex),
  [`machine_workspace.ex`](../../../marshall/lib/marshall_web/machine_workspace.ex),
  [`machines_live.ex`](../../../marshall/lib/marshall_web/live/machines_live.ex),
  [`overview_live.ex`](../../../marshall/lib/marshall_web/live/overview_live.ex).
- SSH and Porsche: [`ssh_command.ex`](../../../protocol/lib/overalls_protocol/ssh_command.ex),
  [`commands.ex`](../../../marshall/lib/marshall/ssh/commands.ex),
  [`control_requests.ex`](../../../marshall/lib/marshall/ssh/control_requests.ex),
  [`client.ex`](../../../porsche/lib/porsche/client.ex),
  [`runner.ex`](../../../porsche/lib/porsche/runner.ex).
- Tests: [`pins_test.exs`](../../../marshall/test/marshall/access/pins_test.exs),
  [`pins_property_test.exs`](../../../marshall/test/marshall/access/pins_property_test.exs),
  [`machine_pins_live_test.exs`](../../../marshall/test/marshall_web/machine_pins_live_test.exs),
  [`commands_test.exs`](../../../marshall/test/marshall/ssh/commands_test.exs),
  [`ssh_command_test.exs`](../../../protocol/test/ssh_command_test.exs),
  [`runner_test.exs`](../../../porsche/test/runner_test.exs), Covenant
  obligations `marshall.identity_authorization.I5`/`I6` and `marshall.compute.I4`.
- Review: [2026-10-18 machine pins](../reviews/2026-10-18-machine-pins.md)
  records the checks actually run.

Remaining: no NixOS machine test drives a pin through a live Porsche SSH
session or the packaged browser; the browser probe covers presentation only;
concurrent pin/delete races are reasoned from the shared VM lock, not
exercised across BEAM nodes.

## Open questions

- Whether a team-owned machine should let team admins pin on the team's
  behalf. Today the fence follows `owner_id` only.

## Related decisions

- [ADR-0074](0074-durable-lifecycle-state-machines.md): lifecycle intent and
  the single delete admission path the guard extends.
- [ADR-0018](0018-persisted-sharing-and-user-machine-access.md) and
  [ADR-0175](0175-thread-sharing-and-bound-machine-authority.md): the Access
  domain and fresh Cedar decisions the pin coordinator reuses.
- [ADR-0046](0046-porsche-ssh-management.md): the shared command catalog and
  closed refusal reasons.
- [ADR-0117](0117-personal-terminal-machine-workspace.md) and
  [ADR-0161](0161-monospace-web-presentation.md): the machine workspace and
  its presentation rules.
- [ADR-0042](0042-host-observability.md): the event catalog the new events join.
- [ADR-0191](0191-elixir-hegel-property-verification.md) and
  [ADR-0186](0186-covenant-contract-verification.md): the property and contract
  verification forms used here.
