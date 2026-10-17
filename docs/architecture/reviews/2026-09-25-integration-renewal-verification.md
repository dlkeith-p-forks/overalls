# Integration renewal and peer-consumption verification

## Scope and architecture assessment

Campaign improvement 016 starts at published `f4de549a`. It preserves ADR-0079
one-use provenance and ADR-0080 named authorization and renewable leases. No
production behavior, protocol, database schema, service placement or credential
custody changes. Verification additions exercise current authority changes
through real domain actions and real packaged private transport in disposable
fixtures. Production rollout is excluded.

The source review covered Marshall authorization/configuration/peer-token
coordinators, their Ash resources and public domain actions, Galileo's HTTP
control client and monotonic upstream lease, protocol validation, existing
unit/property/native evidence, and applicable ancestor/local contracts. Existing
Galileo tests already cover upload renewal, refused renewal, stalled origins,
silent response intervals and bounded control calls. The retained native fleet
already covers initial detach, execution-stop cancellation, peer relocation and
all-Marshall outage. Those are not new coverage claims here.

## Independent application evidence

`marshall/test/marshall/galileo/renewal_history_test.exs` adds two properties:

- Generated actual membership, attachment and integration ownership/configuration
  operations are compared with an independent boolean authority model. Every
  renewal has an exact closed TTL response or exact unauthorized refusal;
  configuration, encrypted headers, attachments, receipts, credentials and token
  rows must remain unchanged by renewal. Host observations are synthetic
  application fixtures, not native execution evidence.
- Peer authorization mints exactly one digest-backed token. Repeated renewals
  across generated direct/peer configuration changes preserve every token row,
  including expiry, and never return target, headers or another token. Removal
  refuses both renewal and token consumption.

`marshall/test/marshall/galileo/peer_token_distributed_test.exs` starts three
independent Marshall BEAMs, each with its own Repo pool. The runner is not counted.
The committed token is row-locked by the test; all three real production DELETE
consumers must be observed waiting in PostgreSQL before release. Exactly one
attestation and two refusals must agree with durable observations from every
replica. Replay, database-deadline expiry and integration archive refuse. Pending
VM provisioning creates source foreign-key identities only; this test does not
claim source request admission, transport or execution. Callers drain before
scoped teardown; an unresponsive peer is stopped before fixture deletion.
The teardown follows the existing admission fixture's foreign-key order and
filters every deletion by this test's integration, host or owner IDs; shared
image deletion additionally requires absence of any VM reference.

Focused execution on this branch: **4 passed (2 properties, 2 tests)** in 22.6
seconds, seed `16003`. An earlier test-only probe reused PostgreSQL's transaction
statistics snapshot and never observed new waiters; clearing that snapshot on
each probe corrected the oracle. The final run observes all three actual waits.

### Mutation sensitivity and cleanup

Two disposable source mutants were removed after focused execution:

- Omitting current admission inside renewal failed both generated properties
  (seed `16004`, exit 2, 1.3 seconds), including exact withdrawn-authority refusal.
- Rolling back the real token DELETE after returning its result failed the
  three-replica winner oracle: three successes instead of one (seed `16005`,
  exit 2, 3.7 seconds). All three production consumers reached the row-lock gate.

The restored production files match `f4de549a` exactly. Git blob hashes are
`a86d288b1af58357b13b3fff3c7db50949640016` for `authorizations.ex` and
`518428fd824eccce50a95353b8d403d43d4221fa` for `peer_tokens.ex`.
The dedicated database audit after both mutants found zero peer tokens,
integrations, VMs, hosts and users. Neither mutant enters the branch.

## Name and configuration investigation

Renewal carries the current integration name, binding and host credential.
Configuration searches historical names and retains the existing integration ID.
A removed integration cannot be recreated as a new identity through that action:
a changed-payload probe reached Ash's archived-record stale update refusal.
This disproves the proposed straightforward remove/recreate identity substitution;
it is not an accepted name-reuse contract or a new compatibility guarantee.
No protocol change is justified by this investigation. An already admitted
attempt retains its selected target and credentials by ADR-0080; later
configuration affects fresh requests while renewal rechecks current source
ownership/attachment. Broader configuration/name lifecycle UX remains separate.

## Packaged native journey

The new `integration-renewals` NixOS check composes the strictly typed team
resource journey with two additional cases. Its ordinary owner removes team
membership through real Porsche, or removes an explicit attachment through the
existing fixture operator calling the ordinary Galileo domain action. The latter
permits integration managers to attach another user's personal VM, whereas the
Porsche command first requires that actor to resolve the VM.

For each individual open guest request, independent origin counters and fresh
journal cursors establish:

1. The actual TLS origin accepted exactly one connection and it remains open.
2. The private HTTPS control path returned at least one successful renewal.
3. Withdrawal yields a fresh HTTP 403 renewal plus exactly one Marshall
   `unauthorized` event across the replicas.
4. The original TLS socket observes EOF/reset, the guest curl ends with HTTP
   failure, the edge has no active request, and origin TLS accept count stays one.
   This connection counter increments before HTTP parsing/credential validation;
   even a retry rejected by the origin would change the independent count.
5. A new request refuses before origin; restoration permits a fresh successful
   request.

The fixture proxy projects only the exact renewal-path boolean and HTTP status;
no URL, identity, header, credential or body enters that log. Verified hostname,
CA, real credential and request/response forwarding remain unchanged. The origin
records bounded connection/accept/closed/timeout fields; timeout cannot satisfy
closure. Closed request counts and all accepted TLS connections are separate
oracles.
No elapsed-time-only successful-renewal claim is allowed.

Native execution **passed all eight stages in 413.94 seconds** on the captured
source below. Nix elapsed time was 424 seconds; cleanup completed in 4.13 seconds.
The coordinator independently confirmed driver PID 538702 and all nine QEMU
PIDs 539046–539054 had exited. Output:
`/nix/store/gn7g31vnsp36kkpah2zjzv4i4y2cs5ir-vm-test-run-kittens-integration-renewals`.

| Executed stage | Seconds |
| --- | ---: |
| Boot nine disposable machines | 54.70 |
| Authenticated capacity setup | 109.93 |
| Ordinary browser keys and Porsche | 21.78 |
| Shared, personal and Customer guest provisioning | 122.36 |
| Member use and management/foreign/Customer refusal | 11.59 |
| Team integration and current membership | 54.59 |
| Membership withdrawal closes an already renewed request | 9.67 |
| Detach closes an already renewed request | 29.02 |

Both new stages executed the successful-renewal, exact-refusal, actual-socket
closure, no-retry and restored-fresh-request assertions described above. The
structured execution log records the completed stage names and durations;
these are executed assertions, not inference from an elapsed connection lifetime.
The check shares one physical KVM host. Ubuntu, independent physical failure
domains, real upstream providers and production rollout remain outside this
improvement.

Captured native tree: `901d7fd45a0436f6b2e1991302a47c81fb51a78e`, base `f4de549a`.
Native derivation:
`/nix/store/4sdl4kiha4sgli3r7lcdr0p4fbxjvajc-vm-test-run-kittens-integration-renewals.drv`.
Its strict composed driver passed typing and lint and produced
`/nix/store/zw8bhwx9kk7q4dwb4kfb5qp4qin04y0p-nixos-test-driver-kittens-integration-renewals`.
Earlier candidates `xl50xyzh` (redundant logger) and `9d8lk8hj` (authorized request
counter only) were superseded without native execution. The final candidate
inherits one logger and separately counts all accepted TLS connections before
HTTP parsing. Failed TLS handshakes are not counted.

## Type and captured-source boundaries

The property fixture is projected into concrete Host/User/VirtualMachine,
connection and `KittensProtocol.report()` fields. Elixir cannot express literal
binary map keys in typespecs; bounded binary-key value types accompany real
closed-binding parser validation in the request constructor. The compiler first
rejected a literal-binary-key annotation; the corrected interface does not rely
on unchecked casts or a broad `map()` contract.

The native release source allowlist in `nix/domains/artifacts/applications/source.nix` excludes all
`marshall/test` files. The test-only type correction after the first candidate
capture changes no native release input. Later fixture captures are recorded
separately; a passing old native driver is not execution of its replacement.

## Validation and final review

- Focused application checks: passing result above.
- Changed origin and driver: pinned Ruff formatting/lint passed; explicit pinned
  ty checking of the standalone origin passed.
- Full Marshall `mix precommit` passed on the restored branch based on
  `f4de549a`: **1,056 passed (105 properties, 951 tests), 2 excluded**, seed
  `903704`, 452.3 seconds. Browser-state gates and workspace typing passed.
  Forced test-environment Dialyzer passed with **0 errors, 0 skipped and 0
  unnecessary skips**, 55.22 seconds after rebuilding the runtime PLT.
- Post-gate database audit: zero peer tokens, integrations, VMs, hosts, users and
  active connections in dedicated partition `verify016` after the owner exited.
- All-file prek, ADR, code-contract syntax/discovery, HLDD review, generated
  option/coverage/view checks and `git diff --check` passed. Nix HLDD passed at
  `/nix/store/zn6dsi0xklxj5h5v048xwqxn7n0s56r9-kittens-hldd-check` before this
  final evidence-only record update; its recapture is checked separately.
- The captured `integration-renewals` native run passed all eight stages as
  recorded above. Final evidence updates change documentation only; application
  and native checks are not relabeled as runs of the later handbook content.

Final review finds no production architecture change or contract
violation in the inspected scope. ADR-0079/0080 remain accepted and partial.
The coordinator reviewed the generated model, independent three-consumer oracle,
scoped cleanup and native successful-renewal/refusal/socket/count assertions.
The executed native evidence establishes these bounded local user journeys.
Production rollout and independent physical failure-domain claims remain open.
Final semantic review checked actual source, native assertions and captured
results against ancestor/local contracts. Token DELETE consumption still owns
one-use authority, renewal still checks current admission without token or secret
reissuance, and fixture logs contain only their closed allowed projections.
No contract was weakened and no production action/protocol change is introduced.
