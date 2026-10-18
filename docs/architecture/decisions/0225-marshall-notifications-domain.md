# ADR-0225: Marshall Notifications domain

- ID: ADR-0225
- Date: 2026-10-18
- Status: accepted
- Implementation: planned
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

No implementation yet.

## Open questions

None.

## Related decisions

[ADR-0222](0222-porsche-client-commands.md),
[ADR-0224](0224-susan-push-relay.md).
