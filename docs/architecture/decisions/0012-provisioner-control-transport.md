# ADR-0012: Authenticated provisioner control exchanges

- ID: ADR-0012
- Date: 2026-09-15
- Status: superseded
- Implementation: partial
- Components: Marshall Compute, Lilly Control, shared protocol, PostgreSQL, TLS
- Supersedes: none
- Superseded by: ADR-0035, ADR-0045

## Context

[ADR-0045](0045-declarative-lilly-enrollment.md) replaces the historical one-year
credential ceiling with five fixed-duration years and adds declarative enrollment
preparation. The original decision and rationale below remain historical evidence.

[ADR-0035](0035-zfs-only-provisioning.md) replaces the ext4/provisioner-v1
compatibility portions and carries forward the other requirements. The decision
and implementation evidence below describe the historical revision.

The authorized platform plan requires provisioners to reach Marshall through its
API, across multiple infrastructure hosts and control-plane instances. Local
PubSub cannot establish delivery or execution. Reports and acknowledgements must
use authenticated host identity and the same database authority as admission.
This decision supplies transport/enrollment details within the implementation
authorization; previous records did not select a concrete transport.

## Decision

Use outbound HTTPS POST exchanges for control traffic. The eventual Lilly loop
samples and exchanges every second with one request in flight, bounded timeouts,
backoff and jitter. Terminal traffic will have a separate streaming channel.
An operation's AshOban notification is a latency hint; periodic reads of durable
operations supply correctness even after lost hints or a Marshall restart.

Keep pure versioned validation/types in `protocol/`, shared as a local dependency
of the two independent releases. Version 1 uses JSON, exact command/request
fields, canonical UUID strings, bounded signed-bigint integers, at most 64 pools,
16 commands/acknowledgements and 1 MiB bodies. Metadata has bounded depth, keys,
strings and collections. Never atomize peer input. Reject unsupported versions;
incompatible schema changes need an explicit compatibility review.

Model host credentials and connection nonces as Ash Compute resources protected
by the Cedar internal-action bridge. An operator issues a 256-bit random secret
with explicit expiry, capped at one year. Only one unarchived credential per
host is allowed. Encrypt its secret with AshCloak/AES-GCM; archive revoked rows
with AshArchival and audit issuance/revocation through AshPaperTrail. Exclude
both the secret and encrypted secret from versions. Credential-bearing structs
redact their token when inspected. No remote input can construct a system actor.

Use a tagged keyring shared across Marshall instances. Production requires an
explicit keyring; the dev/test key cannot be a production fallback. The first
key encrypts and retained tags permit decryption during rotation. Key custody,
re-encryption tooling and backup restoration remain operational obligations.

Every exchange finds the credential, locks its host, then re-reads and verifies
expiry and the secret under that lock. Rotation/revocation take the same lock,
archive the credential and invalidate the session/observations without releasing
VM capacity. The credential supplies host identity; request bodies cannot select
a different host or acknowledge another host's operations.

Persist session UUIDs and assigned epochs. Retrying the current UUID returns the
same epoch; retrying an older UUID is stale and cannot replace a newer session.
A new UUID advances the epoch and invalidates old reports. The client must have
exclusive host ownership before its eventual autonomous loop is enabled; sessions
do not replace local process/command fencing. Keep nonce tombstones until an
explicit safe retention scheme prevents old opens from becoming new again.

Apply report ingestion, acknowledgement validation and command selection in the
same host-locked transaction. A null report does not refresh capacity. Receipt
acknowledgement changes only operation status; it does not release reservations
or assert any physical VM outcome. Lilly must persist command intent before
acknowledging. Deliver pending operations first, then acknowledged operations for
reconciliation, retaining their IDs and generations.

Require TLS and verify certificates/hostnames. Allow plaintext only through an
explicit dev/test exception on literal loopback addresses. Do not trust arbitrary
forwarded headers. Disable client redirects and implicit retries; stream-limit
success and error responses, and disable automatic decompression. Keep the API
outside browser sessions and request-body logging. Use 2/3/5-second connect,
receive and request timeouts; these are bounds, not evidence of host death.

## Alternatives

Outbound WebSockets could combine control with streaming, but add connection
ownership and reconnect machinery before durable commands exist. Short polling
works through ordinary HTTPS load balancing and provides a clear transaction
boundary. Terminal streaming remains separate. Node-local credentials/sessions
would produce stale authority after failover. A memory-only command queue would
lose operations after a crash. Hash-only credentials would support verification,
but this implementation deliberately applies the required AshCloak extension to
the provisioner secret, with strict internal reads and a managed keyring.

## Consequences

One exchange per host per second creates sustained database work; actual host
counts and rates must guide measurement before scale claims. Host locks serialize
admission and control; network requests never occur while holding Marshall's
database lock. Multiple live Lilly processes with the same credential can still
compete to create new sessions until host exclusivity is implemented.

Version 1 commands carry lifecycle intent and sizes. Image/address validation,
durable local receipt, physical outcome reconciliation and the autonomous loop
must be completed before using these envelopes to start VMs. Hosts continue to
default disabled. These v1 limitations remain; executable v2 delivery is implemented
under [ADR-0017](0017-durable-vm-actors-and-host-ownership.md), and authenticated
user provisioning is exposed under
[ADR-0018](0018-persisted-sharing-and-user-machine-access.md).

## Invariants and verification

- Three independent Marshall nodes agree on a retried session and enforce
  revocation against subsequent exchanges without releasing VM reservations.
- Expired, revoked, malformed and foreign-host credentials/acknowledgements fail.
- An invalid acknowledgement rolls back the entire report transaction.
- A delayed open cannot resurrect a replaced connection nonce.
- Stored secrets decrypt correctly, remain hidden from ordinary resource reads
  and inspection, and are absent from issuance/revocation versions.
- Real HTTPS tests accept an explicitly trusted CA and reject an untrusted one;
  redirects are not followed and both success/error responses remain bounded.
- Property tests cover command/report round trips, integer precision, arbitrary
  bytes and invalid credentials. Run all three projects' precommit gates.

## Implementation evidence

[Host credentials](../../../marshall/lib/marshall/compute/host_credential.ex),
[credential coordination](../../../marshall/lib/marshall/compute/credentials.ex)
and [vault](../../../marshall/lib/marshall/vault.ex) implement encrypted, archived,
audited and revocable host authority. [Session resource](../../../marshall/lib/marshall/compute/host_session.ex)
and [control coordinator](../../../marshall/lib/marshall/compute/provisioner_control.ex)
provide durable connection/operation behavior. [API plug](../../../marshall/lib/marshall_web/provisioner_api.ex)
enforces the request boundary.

[Production endpoint configuration](../../../marshall/config/prod.exs) now also
enforces direct TLS without trusting arbitrary forwarding or loopback Host
headers. [Regression checks](../../../marshall/test/marshall/mailer/config_test.exs)
cover those headers and token-free redirect logging under
[ADR-0024](0024-durable-magic-link-email.md).

[Shared protocol](../../../protocol/lib/overalls_protocol.ex) and
[Lilly client](../../../lilly/lib/lilly/control/client.ex) are used together in
[real socket tests](../../../marshall/test/marshall_web/provisioner_transport_test.exs).
[API tests](../../../marshall/test/marshall_web/provisioner_api_test.exs),
[credential tests](../../../marshall/test/marshall/compute/credentials_test.exs),
[three-node tests](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
and [protocol properties](../../../protocol/test/overalls_protocol_test.exs) cover
the listed foundation invariants. The [review](../reviews/2026-09-15-provisioner-transport.md)
records final validation and gaps.

[ADR-0013](0013-capacity-collection-and-local-receipt.md) now implements exclusive
local ownership, the automatic collector/exchange loop and durable command
receipt, verified against real host capacity over TLS. Remaining: operator
credential-file deployment, key re-encryption and fleet/failover acceptance.
[ADR-0025](0025-protected-provisioner-enrollment.md) now implements the
[protected operator workflow](../../../marshall/lib/marshall/compute/enrollment.ex)
and [Lilly file reader](../../../lilly/lib/lilly/control/credential_file.ex).
Runtime reconciliation, retained telemetry and browser terminals are implemented
under ADRs 0017, 0023 and 0022 respectively; their broader acceptance gaps remain
explicit in those records.

[ADR-0016](0016-executable-generations-and-lifecycle.md) now specifies and tests an
explicit v2 client/API with image/slot commands, enrolled machine identity and
transactional physical outcomes. V1 is unchanged and never invokes the driver.

## Open questions

Choose safe nonce/audit retention and measure host count/exchange load and
failover latency. Secret-store ownership and deployment custody are implemented
under ADR-0032. ADRs 0014/0016/0031 specify image/address capabilities and the
executable protocol, including explicit v1 limitations and the requirement to
upgrade Marshall before enabling ZFS hosts.

[ADR-0014](0014-image-and-address-admission.md) implements image integrity/catalog
and address admission prerequisites. The v1 execution omission remains explicit;
no driver may treat those receipt envelopes as executable launch configurations.

## Related decisions

[ADR-0003](0003-control-plane-coordination.md),
[ADR-0004](0004-lilly-and-vm-actors.md),
[ADR-0006](0006-capacity-accounting.md),
[ADR-0009](0009-assurance-and-testing.md),
[ADR-0010](0010-capacity-admission-transactions.md).

[ADR-0035](0035-zfs-only-provisioning.md) supersedes this decision as described above.

## Amendment 2026-09-19: terminal stream alongside the HTTPS control session

Lilly additionally holds one persistent authenticated WebSocket at
`/api/provisioners/v4/stream`, bound to the same v3 execution session, to
carry multiplexed terminal channels under
[ADR-0083](0083-terminal-host-stream-and-registry.md). The HTTPS request-reply
semantics of this decision are unchanged.
