# ADR-0225: Marshall Notifications domain

- ID: ADR-0225
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: Marshall
- Supersedes: none
- Superseded by: none

## Context

When the agent needs input, the user should be told even with Mila closed.
Marshall must decide who to notify, deliver through Susan (ADR-0224) with
retries, and stay silent when the operator disables push.

## Decision

1. A new `Marshall.Notifications` Ash domain with:
   - `Device` (AshStateMachine `pending → active ⟲ → invalidated | revoked`),
     bound to the SSH key that registered it, at most 10 per user, revoked on
     `device rm`, key revocation or account retirement;
   - `Delivery` (AshStateMachine `queued → sending → delivered | retry_wait ⟲ |
     failed_permanent | dropped`), at most one non-terminal per device and
     collapse key, pruned after 7 days.
2. The producer runs after the outer commit of agent question and proposal
   transactions, notifying thread writers other than the actor.
3. `DeliveryWorker` (Oban queue `:notifications`, 8 attempts, jittered
   backoff) maps transport, timeout, 5xx and 429 (honouring `Retry-After`) to
   `retry_wait`; 404/410 invalidates the device; other 4xx are permanent. The
   delivery id is Susan's idempotency key; pokes older than about an hour drop.
4. The Susan origin is a compiled constant; a test override exists only in
   `MIX_ENV=test`. `services.marshall.notifications.enable` (default true)
   turns registration into a `push_disabled` refusal and the producer into a
   no-op.
5. Each Marshall generates an Ed25519 install identity that signs pokes.
   AshPaperTrail records device, delivery-terminal and preference changes with
   digests only.

Authorization: the approved Mila plan (2026-10-18).

## Alternatives

- **Sending from the request process.** Rejected: provider latency and retries
  would hold agent transactions.

## Consequences

Marshall gains a public-docs privacy page explaining what Susan sees and how to
disable push.

## Invariants and verification

Planned: a `push-notifications` fleet scenario where a fake Susan returns 503
twice then 200 and the provider sends exactly once; 410 invalidates the
device; payloads are ciphertext only.

## Implementation evidence

The [Notifications domain](../../../marshall/lib/marshall/notifications.ex)
declares [Device](../../../marshall/lib/marshall/notifications/device.ex),
[Delivery](../../../marshall/lib/marshall/notifications/delivery.ex) and the
singleton [install identity](../../../marshall/lib/marshall/notifications/install_identity.ex)
with AshStateMachine, AshCloak push-key and seed custody, partial unique
identities for live device keys and open collapse keys, AshPaperTrail versions
that ignore push keys, and AshOban prune (7 days) and reconcile schedules; the
[migration](../../../marshall/priv/repo/migrations/20261018233134_add_notifications.exs)
creates the tables. [Device actions](../../../marshall/lib/marshall/notifications/device_actions.ex)
bind registration to the session SSH key, cap ten live devices and refuse
`push_disabled`; SSH key archive and account deletion/retirement call the
domain's revocation functions in the same transaction.

The [producer](../../../marshall/lib/marshall/notifications/producer.ex) is
registered with `Ledger.after_commit` from the planning question and proposal
paths in [Planning](../../../marshall/lib/marshall/agents/planning.ex). The
[delivery worker](../../../marshall/lib/marshall/notifications/delivery_worker.ex)
implements the [retry table](../../../marshall/lib/marshall/notifications/retry.ex)
and seals [PushPoke](../../../protocol/lib/overalls_protocol/push_poke.ex) v1
inside a signed [SusanPoke](../../../protocol/lib/overalls_protocol/susan_poke.ex)
body sent by the [Susan client](../../../marshall/lib/marshall/notifications/susan.ex),
whose origin is compiled with a `MIX_ENV=test`-only override. The
[NixOS option](../../../nix/domains/system/marshall.nix)
`services.marshall.notifications.enable` reaches Marshall as
`MARSHALL_NOTIFICATIONS_ENABLED` through the launch wrappers.

Unit and Hegel property tests cover [devices](../../../marshall/test/marshall/notifications/devices_test.exs),
[delivery](../../../marshall/test/marshall/notifications/delivery_worker_test.exs)
and the [producer](../../../marshall/test/marshall/notifications/producer_test.exs);
Covenant obligations
[marshall.notifications.I1–I6](../../../marshall/contracts/marshall/notifications.obligations.md)
have [contract tests](../../../marshall/test/contract/marshall/notifications_contract_test.exs).
The [`push-notifications` machine test](../../../nix/verification/tests/machines/push-notifications/default.nix)
drives the release against a fake Susan at the compiled origin; the
[review](../reviews/2026-10-18-mila-notifications.md) records which of these
runs executed. Real APNs/FCM delivery through Susan and Mila's device-side
decryption are not established here.

## Open questions

None.

## Related decisions

[ADR-0222](0222-porsche-client-commands.md),
[ADR-0224](0224-susan-push-relay.md),
[ADR-0235](0235-mila-desktop-clients.md) (device platforms macos and windows).
