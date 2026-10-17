# Galileo named integrations

Canonical guest endpoint: `https://<name>.integration.internal`.
Architecture: [ADR-0080](../architecture/decisions/0080-named-edge-integrations.md)
with [ADR-0077](../architecture/decisions/0077-teams-and-shared-resources.md),
[ADR-0078](../architecture/decisions/0078-fleet-wildcard-certificate.md) and
[ADR-0079](../architecture/decisions/0079-peer-vm-vm-attestation.md).

Galileo is an independent release on every enabled Lilly host, fronted by
Audi's private frontend. Guests never receive integration credentials:
secret values live Cloak-encrypted in Marshall, cross the wire only inside
per-request authorization responses, and are injected at the edge. The VM
can use an integration; it can never read its secrets.

Personal integrations require an explicit attachment for every source VM,
including the owner's machines. Detaching removes admission and renewal
authority. There is no attachment backfill or compatibility mode. Live teams
retain automatic access for their current members' machines; archived teams
and retired personal owners refuse access even when attachments remain.

Marshall authorizes each upstream attempt with a short relative lease. Galileo
renews only the execution, ownership and attachment authority while retaining
the original target and credentials. Renewal responses contain no credentials
or routing data. A refused, invalid, unavailable or late renewal closes the
existing upstream connection without retrying the guest request.
A verified Marshall403 remains guest403 before upload or origin effects;
invalid or unavailable control exchanges remain guest503. Production direct/peer
attachment and withdrawal acceptance passed on `7fda1272`; exact scope and cleanup
are recorded in the [review](../architecture/reviews/2026-10-03-galileo-attachments-and-faults.md).
The private frontend uses HTTP/1. Bandit body reads remain in their stream
owner; lease cancellation closes the frontend socket through ThousandIsland
to interrupt blocked uploads and response writes. Request cleanup retains
counter and outcome accounting. Idle timeouts remain separate from revocation.

## Deployment inputs

Galileo inherits Lilly's `hostId`, verified `controlPlane` and control-plane
CA, and is default-enabled with Lilly; an explicit disable fails NixOS
evaluation. `services.galileo.secretsFile` supplies the SOPS document
containing `GALILEO_CREDENTIAL` under `overalls-galileo.production` through
the existing SecretSpec bundle; startup copies credentials into a private
0700 runtime directory with 0400 files. The control credential is issued by
the Marshall operator CLI: `galileo-rotate HOST TTL_SECONDS OUTPUT_FILE`,
`galileo-verify OUTPUT_FILE`, `galileo-revoke HOST`. Enrollment must write
the returned credential directly to private operator custody, never to
arguments or logs.

Private TLS is the fleet wildcard certificate of ADR-0078: root (20y) and
intermediate (10y) remain recovery-only custody, the wildcard leaf (10y)
is a bundle input on every private-services host, and no issuance or
renewal service exists. Guest images must embed the matching root through
`privateServiceRoots`; existing disks that still trust the retired root
lose private-service TLS until re-imaged.

## Configuration surfaces

Users create and manage integrations from Porsche (`integration add`, with
`--target`, `--header name:value`, `--bearer -`, `--basic -`,
`--strip-prefix`, `--peer --peer-vm MACHINE` and `--attach MACHINE`) and from the
Marshall console at `/integrations`. Secrets are accepted on stdin with
`-`, stored write-only and displayed as `****`. `team` commands and
`/teams` manage teams, memberships and ownership transfers. Names are
globally unique lowercase labels.
Machine arguments accept a bare UUID or machine name.

## Accounting and monitoring

No per-request accounting exists. The fleet collector discovers
`galileo.service` and adds bounded Unix-socket probes for readiness,
active requests and bounded gauges. Prompts, upstream bodies, credentials
and VM identities never enter monitoring samples or logs.

## Verification ledger

Executed during implementation:

- Protocol property tests for names, targets, strip prefixes, header
  injection, lease bounds, and closed authorization and renewal responses.
- Marshall tests: authorization fences, Cloak-at-rest, write-only secrets,
  Cedar team/integration matrices, transfer state-machine matrix, Porsche
  dispatch without secret echo, deferred exactly-one-owner enforcement,
  retirement cleanup, and digest-backed one-use peer token mint/verify/retention.
- Galileo unit and property tests: strip-prefix alignment and header override
  semantics; bounded single-attempt streaming and failure tests against a
  fixture authority and origin; monotonic cancellation after refused or late
  renewal.
- Audi wildcard DNS and frontend tests; destination peer verification, trusted
  provenance replacement and denial tests; PKI tests for wildcard SANs, exact
  CSR validation, name constraints and 20/10/10 lifetimes.
- NixOS `galileo-service`: the real packaged Galileo release, SOPS credential
  loading, verified synthetic control/origin TLS, injection observed at a
  fixture origin, strip-prefix behavior, malformed-binding denial, and exact
  byte/digest integrity for an upload larger than three 64 KiB source chunks.
- NixOS `private-services-network`: packaged Audi wildcard DNS/TLS for
  `llm.internal` and the integration zone in guest-like network namespaces.

- NixOS `galileo-fleet` now passes with real PostgreSQL, three Marshall releases,
  two enrolled Lilly hosts and real Firecracker guests. It checks attachment
  denial/grant/detach, upload integrity, 32 guest requests, execution-stop
  cancellation and restart, cross-host peer provenance, source relocation,
  stale-source removal, and all-Marshall outage refusal/recovery.
- The expanded `galileo-service` passes packaged Audi-to-Galileo requests across
  two NixOS machines, exact query and PUT forwarding, stalled source/destination
  bounds, stale-binding renewal refusal, and 64 requests at concurrency eight
  followed by active-request drain. Binding and control authority remain synthetic.

Remaining acceptance and integration work:

- The [team-resource campaign](../architecture/reviews/2026-09-25-team-resource-verification.md)
  records three-BEAM membership/transfer versus retirement schedules and a passing
  captured Marshall full gate. It preserves the September 20 failure history;
  those old failures are not the current gate status.
- [Renewal verification](../architecture/reviews/2026-09-25-integration-renewal-verification.md)
  records generated current-authority histories and three-BEAM one-use peer
  consumption. Its packaged live membership/attachment withdrawal journey passed
  all eight stages on captured tree `901d7fd4`, including successful renewal,
  exact refusal, original socket closure without retry and restored fresh calls.
  Unchanged consumer/native cases retain their historical scope.
- Production fleet activation (guest images with the new root, rotated
  operator credentials, encrypted bundle documents) is an operator rollout.

These NixOS machines share one physical test-builder failure domain. Their bounded
loads establish functional acceptance, not production throughput or independent
physical-host availability. Earlier peer transport failure was resolved by
trusting the isolated public Audi CA in the Galileo fixture.
