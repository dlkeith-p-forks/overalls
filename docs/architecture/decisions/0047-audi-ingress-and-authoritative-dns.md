# ADR-0047: Audi ingress and authoritative DNS

- ID: ADR-0047
- Date: 2026-09-17
- Status: superseded
- Implementation: implemented
- Components: Audi, Marshall, Lilly, protocol, NixOS
- Supersedes: none
- Superseded by: ADR-0105

## Context

ADR-0105 supersedes this record's public certificate issuance, custody and
hostname shape. The remaining ingress, DNS, SSH and authorization rationale is
carried forward there; evidence below records the historical per-VM design.
Its issuer, custody and control protocol source has since been retired; the
following paragraphs describe the earlier implementation and test evidence.

The user authorized implementation of Audi, including its own authoritative DNS
server and SSH proxy, HTTP/HTTPS access to Firecracker guests, Ash domain modeling,
structured logging, property tests and real NixOS tests. Backward compatibility
is not required. The original design target was 100 hosts and 10,000 VMs, not
demonstrated capacity. On 2026-09-18 the user explicitly removed investigation
of that scale from this implementation's scope. Capacity measurements remain
historical diagnostics, not a completion gate or a claim of supported scale.

## Decision

Audi is an independent Elixir release with separately supervised gateway and DNS
deployment roles. The gateway runs beside Lilly on each VM host. At least two
control-plane hosts run Audi's DNS role. Audi implements DNS UDP/TCP itself and
uses OTP SSH for its SSH listener; no external DNS or SSH server implements
these Audi roles. Standard OpenSSH clients use generated configuration.

The [access-flow diagrams](../../services/audi.md) describe service placement, the user's
view and the nested SSH stream. They distinguish target behavior from enabled
implementation.

For outer SSH host verification, generated OpenSSH configuration uses
`KnownHostsCommand` with HTTPS-verified curl to obtain the current placement's
registered Audi host key from Marshall. Strict host-key checking stays enabled;
lookup failure terminates connection setup. This requires OpenSSH and curl, not
an Audi client binary, and affects connection setup only. The inner guest SSH
connection retains its independent normal known-hosts verification. The public
host-key endpoint returns only registered public keys for current published
bindings and must not accept a key supplied by the requesting client.

Delegate the application DNS zone once. Marshall publishes durable placement
state, never per-VM DNS provider API changes. Audi answers from locally replicated,
versioned placement state, without querying Marshall for individual DNS packets.
Address TTL defaults to 20 seconds, negative TTL to five seconds and NS TTL to
one hour. Stale or uninitialized routing state must not fabricate NXDOMAIN.
DNS is authoritative only, with bounded parsing, EDNS, UDP truncation and TCP
fallback; recursion, public updates and zone transfers are excluded.

Stable VM names include an immutable unique suffix and survive relocation.
Additional web apps use distinct hostnames on HTTPS port 443. The primary guest
web port is configurable and private by default; its owner may make it public.
Alternate guest ports 3000–9999 remain private. Ordinary HTTP redirects to HTTPS.
Browser SSO uses one-time state-bound exchanges and host-only protected cookies;
platform credentials never reach guest applications. Forwarded and identity
headers are sanitized and reconstructed. Streaming and WebSockets are required.

Marshall Ash resources own endpoints, publication revisions, proxy sessions and
gateway credentials, reusing Accounts, Access, SSH keys and Compute placements.
Add web-only sharing; viewer/operator/manager can use private web endpoints.
Guest SSH requires owner/operator/manager authority. The SSH transport connects
only to guest port 22 and preserves inner guest authentication and host-key
verification. Users manage guest sshd and credentials. No arbitrary TCP forwarding,
custom domains or programmatic HTTP tokens are included in this release.

Traffic travels directly from the client to Audi on the selected Lilly host and
through a restricted local connector to the guest. Marshall is outside the data
path. The connector binds VM, placement, epoch and permitted service, never a
client-selected arbitrary destination. Source fencing and destination readiness
precede publication of a moved route. Existing connections break on relocation;
stale DNS must never cause cross-host application relaying.

Background authorization renewal grants at most five seconds of authority,
including existing streams. Delayed replies cannot restart that deadline. Loss of
authority closes streams and denies new requests. This exception is specific to
Audi; management and existing console checks retain their current semantics.

## Alternatives

The user rejected DNS provider updates by Marshall, an established DNS server,
arbitrary TCP forwarding and a custom SSH client requirement. Host-specific VM
URLs would break stable names on relocation. Additional public HTTPS ports share
cookie scope and were replaced by distinct app hostnames on 443. Central proxying
would add geographic latency to every connection.

## Consequences

Audi adds DNS protocol maintenance, certificate issuance capacity, SSH host
identity lifecycle and expiring distributed authority. DNS TTL is not a deadline
for all resolvers or existing connections. TLS issuance must be prepared before
route publication. Production sizing requires separate issuer-quota measurements;
scale investigation is outside this implementation's scope. A fleet-wide shared
TLS private key is not an acceptable shortcut.

[ADR-0052](0052-fenced-local-guest-ingress.md) now replaces ADR-0007's ingress
prohibition while carrying forward direct guest isolation. The original codec
slice added no network access. Access and deployment decisions still need
reconciliation as their implementations arrive.

## Invariants and verification

- Property tests use independent models for wire parsing, publication ordering,
  hostname binding, expiration, revocation and placement fencing.
- DNS tests cover malformed compression, lengths, EDNS, truncation, TCP framing,
  unsupported operations, negative answers and stale replica recovery.
- Real NixOS tests use packaged Audi, actual browsers/OpenSSH, local ACME and
  nested Firecracker; exercise relocation, revocation, outages and isolation.
- JSON diagnostics use bounded event metadata and protected OTP reports. Guest
  payloads, credentials and raw URLs are excluded; Fluent Bit export remains
  bounded and independent of guest availability.
- Nix modules, secret provisioning, dependency hashes, update health and rollback
  cover both Audi roles. Full project checks include forced Dialyzer, contracts
  and ADR validation. Production capacity requires measured evidence.

## Implementation evidence

### Current status — 2026-09-18

Audi's authorized implementation is complete. The merged source passes all
application gates and the complete physical `audi-relocation-fleet` script in
1520.47 seconds, including real relocation/source cleanup, crash recovery,
certificate-storage permission loss and gateway/DNS corrective updates. The user
removed scale investigation from the completion criteria on 2026-09-18;
historical capacity limitations below are not claims of supported scale.
The detailed [review](../reviews/2026-09-17-audi-ingress.md) records executed
checks, source revisions and failures. The [access guide](../../services/audi.md) describes
the configured service composition and user flows.

| Capability | Current implementation and evidence |
| --- | --- |
| DNS | Audi's own [UDP/TCP server](../../../audi/lib/audi/dns/server.ex) serves bounded authoritative answers from authenticated, expiring Marshall publications. Two independent DNS services pass the recorded fleet failover scenario. |
| SSH | Audi's [SSH listener](../../../audi/lib/audi/ssh/listener.ex) and local Lilly connector reach real guest sshd through nested OpenSSH. Recorded fleet acceptance verifies platform-key revocation and preserves the guest VMM. |
| Web | [HTTP/WebSocket forwarding](../../../audi/lib/audi/http/web_socket.ex), private browser sign-in and host-only cookies pass the real-browser fleet scenario. Public access remains limited to the primary app. |
| Certificates | Independent readiness work, durable issuance/custody and bounded recovery are implemented. The merged fleet test issues through Pebble, restores gateway readiness with the CA stopped, and denies ingress during custody permission loss before recovering the same certificate and guest. |
| Modeling and verification | Marshall Ash resources remain authority. Structured logging, property tests and Nix modules are implemented; the [review](../reviews/2026-09-17-audi-ingress.md) distinguishes application gates, physical scenarios and unexecuted requirements. |
| Relocation and crash recovery | The [real fleet scenario](../../../nix/verification/tests/machines/fleet/scenarios/audi-relocation.py) passes transfer, handoff, physical source cleanup, destination DNS, unchanged strict SSH with retained guest data, HTTPS at the stable name and stale-source refusal. The same run passes a Lilly main-process crash while preserving the guest and closing live streams. These are the tested failure cases, not a claim of universal fault tolerance. |
| Capacity | The [measurement artifact](../measurements/2026-09-18-audi-readiness.json) retains complete-publication and HTTPS-readiness measurements, including failures. The latest twelve-round synthetic HTTPS run passed with only about 1.5 ms first-round margin. This does not establish actual fleet capacity. |

The final merged run uses clean snapshot `/tmp/audi-brady-integrated-v7uw6ba3`
at `695ee8f`; subsequent Audi changes are documentation only. Its log is
`/tmp/audi-brady-integrated-fleet.log`, with terminal exit zero and relocation
completed in 409.34 seconds. Merged gates pass 331 Lilly checks (39 properties),
134 protocol checks (51 properties), 140 Audi checks (46 properties), and 725
Marshall checks (64 properties; two opt-in cases excluded), with no Dialyzer
errors or skips. The review preserves the earlier failures and successful
refinement run. Public deployment still requires operator-supplied delegation,
addresses, issuer configuration and credentials.

An earlier successful `audi-relocation-fleet` script passes in 2004.31 seconds
with terminal build exit zero. Its immutable snapshot is based on `b57e093` plus
captured local transfer changes, including source-export logging and all four
bounded pool-acquisition retry call sites. Relocation takes 899.33 seconds,
including eventual source cleanup after closed failure/contended-lock retries.
It also verifies Customer restrictions, live revocation, independent DNS failover,
and gateway/DNS corrective updates. This run predates the certificate-custody
fault scenario and does not establish that scenario's acceptance. The earlier
`1efb7c0`-based run passed in 1803.68 seconds, with relocation taking 705.05 seconds;
both results and their limitations remain in the review.

The subsequent custody-fault subtest passes, but its full run fails at source
cleanup after destination activation. Cleanup acquisition retries and private
native-utility diagnostics subsequently pass the complete physical run in
1668.42 seconds, including source cleanup and post-move access. The earlier
failure remains evidence of transient recovery problems, not a proven root
cause. The final merged run above also passes with the newer main networking
changes; the detailed review distinguishes the tested snapshots.

An earlier completed full Audi fleet script passed in 1008.57 seconds with
terminal build exit zero, using merged main `6f0e518` plus the captured fleet
fixture changes. It includes private role readiness across control outages and
real package updates for both gateway and DNS. Each role rejects a running but
unhealthy candidate, preserves its last healthy revision and recovers through a
corrective revision. Guest process identity survives, gateway traffic returns
with the CA stopped, and the second DNS replica remains available. This follows
ADR-0036's corrective-update semantics, not automatic code or schema rollback.
Later concurrent Inception changes on main are outside this captured run.

Audi now implements a private [status service](../../../audi/lib/audi/status_server.ex)
and [role health check](../../../audi/lib/audi/health.ex). DNS requires a live
listener, fresh replica and authenticated control identity; gateway health
requires live listeners and an authenticated current gateway catalog. Each
status check has a five-second deadline and returns only version, role and ready.
The updater requires an exact affirmative response from every enabled Audi role
before advancing healthy state. The fleet scenario provides the bounded
package-update evidence described above; it does not establish fleet capacity
or the complete failure matrix.

### Historical implementation notes

The Brady shared-consumer gate exposed a publication-plan failure with stale
small-table estimates: PostgreSQL estimated a 10,000-row materialized inventory
as one row and nested the eligibility join beneath the outer inventory scan.
The [publication statement](../../../marshall/lib/marshall/ingress/publications.ex)
now materializes current eligibility once as well as inventory, preserving the
single statement, clock, predicates and 1.5-second deadline. The
[capacity regression](../../../marshall/test/marshall/ingress/publications_test.exs)
explicitly analyzes the small fixture before expanding it to exercise stale
estimates. Validation is tracked in the
[Brady review](../reviews/2026-09-18-brady-egress-cache.md); this plan correction
does not establish deployment-scale publication capacity.

The new [relocation scenario](../../../nix/verification/tests/machines/fleet/scenarios/audi-relocation.py)
combines real transfer with Audi's existing fleet checks. Its runtime acceptance
is pending; adding the scenario does not close the relocation evidence gap.

The following notes preserve observations made during implementation, including
failures and capabilities that were then unfinished. Statements such as "unrun"
or "unimplemented" describe those intermediate states, not current status.
Use the current-status section and the review's revision-specific results when
assessing completion; no historical failure is erased by a later passing run.

[Application boundary](../../../audi/lib/audi/application.ex) and
[bounded DNS decoder](../../../audi/lib/audi/dns/wire.ex) establish the first
implementation slice. [Decoder tests](../../../audi/test/dns_wire_test.exs)
contain arbitrary-input and valid-question properties plus malformed fixtures.
[UDP/TCP listeners](../../../audi/lib/audi/dns/server.ex),
[authoritative answers](../../../audi/lib/audi/dns/authority.ex) and the
[local directory](../../../audi/lib/audi/dns/directory.ex) now implement bounded
connections, address and zone answers, negative answers, truncation, stale-state
failure and monotonic snapshot publication. [Socket tests](../../../audi/test/dns_server_test.exs)
exercise both transports with Audi fixtures and OTP's independent DNS client;
valid alternate-port names inherit the stable VM's single address entry while
retaining the queried DNS owner name. Their removal and freshness use the same
atomic snapshot lookup; no per-port records or broad wildcard are required.
Socket and property tests cover the accepted port interval, IPv4/IPv6, invalid
prefixes, removal and unavailable replicas. This does not grant web access.
[publication properties](../../../audi/test/dns_directory_test.exs) check reordered
revisions. Those initial tests use local sockets and injected publication data;
the later replication tests below cover the Marshall API. The closed DNS startup schema and
[DNS Nix module](../../../nix/domains/system/audi-dns.nix) enable an independent
unprivileged `audi-dns` service with bounded UDP/TCP listeners and an initially
empty replica. Automated ACME issuance, HTTP/HTTPS forwarding and full acceptance
remain outstanding. Until the first fresh snapshot arrives, configured DNS
services return SERVFAIL for the application zone.

The [DNS-01 proof validator](../../../audi/lib/audi/dns/challenge.ex) and server
support one to four canonical SHA-256 proof values at each exact per-VM ACME
challenge owner, including before address publication. Challenge expiry is
independent of snapshot refresh, TXT TTL is capped at five seconds, and challenge
presence creates no application addresses. [Proof properties](../../../audi/test/dns_challenge_test.exs)
and UDP/TCP socket tests cover encoding, rejection, expiry and empty parent names.
Authenticated challenge replication is implemented below; the deployed ACME
producer that derives and registers these proofs remains unfinished.

The account-key primitive and
JWS encoder implement P-256 account identity,
canonical public thumbprints, protected ES256 requests and DNS-01 proof derivation.
Cryptographic tests verify real signatures,
tamper rejection and proof binding. These follow
[RFC 8555](https://www.rfc-editor.org/rfc/rfc8555.html),
[RFC 7638](https://www.rfc-editor.org/rfc/rfc7638.html) and
[RFC 7518](https://www.rfc-editor.org/rfc/rfc7518.html).
The issuer transport now performs
verified HTTPS directory, nonce and signed POST exchanges restricted to one
configured origin. Every signed attempt fetches a nonce by HEAD and sends one
POST; redirects, implicit retries and decompression are disabled. Responses and
deadlines are bounded, returned resource locations remain same-origin, and error
details are reduced to status, bounded parsed retry delay and fixed problem types.
Real HTTPS tests verify signatures,
concurrent nonce consumption, trust/hostname rejection and response limits.
There is still no deployed account coordinator, durable order coordinator or authenticated
challenge publication; transport alone does not establish issuance.

The per-VM CSR generator creates a fresh
P-256 private key and a signed PKCS#10 request with exactly the stable hostname
and its per-VM wildcard as SANs. It accepts no arbitrary extensions or fleet-wide
names. Request tests use OpenSSL to verify
the request and generated properties to bind the exported key, signature and exact
SAN set. A CSR alone does not establish issuance, listener installation or route
readiness.

The issuer operations now cover explicit
account registration, exact per-VM orders, authorization discovery, DNS-01
acknowledgement, polling, finalization and validated certificate download.
Resource validation binds names,
wildcard flags and issuer-origin URLs without assuming authorization URL order.
Malformed response bodies return fixed errors. A
local issuance test uses actual HTTPS,
JWS verification, TXT queries to Audi DNS and OpenSSL certificate signing;
properties reject resource identity
substitution. These are individual operations, not a running issuance coordinator.
Durable account/order coordination, production key custody, retry scheduling,
certificate installation and route-readiness publication remain unfinished.

Account recovery now performs an existing-only signed lookup with the saved
account key, without accepting terms or falling back to registration. Saved
per-VM CSR recovery validates bounded DER/PEM, canonical request contents,
signature and derived public-key identity while preserving the original bytes.
The local issuance test exercises recovery before proceeding; request properties
reject corrupted signatures and tests reject changed names, keys and encodings.
The local custody layer now exclusively
creates immutable account-key and per-issuance request records under an existing
private service-owned directory. It syncs file contents and the directory before
success, never overwrites existing records, and validates permissions, links,
identity and cryptographic contents when loading.
Custody tests cover independent-process
reads, concurrent exclusive writers, malformed records and unsafe filesystem
paths. The issuance fixture now saves and reloads keys and requests before use.
An interrupted partial record remains an explicit recovery failure; it is never
silently replaced with another key. Custody currently assumes trusted service UID
and root, with no automated cleanup, key rotation, account/order coordinator,
restart scheduling or Nix state-directory wiring.

Custody also stores immutable issued chains bound to the saved request. Saving
and loading validate the chain, exact names and key against current operator
roots; record identity and byte limits are checked independently. The
[SNI store](../../../audi/lib/audi/tls/store.ex) can restore a specified issuance
record through the same revision/tombstone and capacity checks as installation.
The local issuance test restarts the store, restores from disk and completes an
actual verified TLS 1.3 handshake. Wrong trust, stale or conflicting restoration,
capacity rejection and corrupt records fail without replacing a valid entry.
This does not discover current issuance IDs after startup, persist store revision
tombstones, establish placement authority or publish routes; those require the
outstanding control-plane coordinator and deployment wiring.

Marshall now models [issuance work](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/marshall/lib/marshall/ingress/issuance.ex)
through Ash/PostgreSQL with transactional audit history, positive execution
bindings and a partial unique index allowing one pending record per VM.
The historical admission action authenticated the
gateway under an exclusive service lock, then shares the
[current execution checks](../../../marshall/lib/marshall/ingress/execution.ex)
used by route readiness. Repeated current bindings reuse the issuance ID; changed
bindings retire old pending work before replacement. A service holds at most 128
pending records. This bounds admitted backlog, not public-CA issuance quotas.
Historical admission tests verified
reuse, stale and unauthorized rejection, generation replacement and absence of
route publication. Issuance IDs can identify Audi custody records, but no worker
connects them yet. Gateway transport and terminal outcomes are implemented below;
automatic retries, retention, renewal and installed-readiness reporting remain unfinished.

Restartable order preparation now connects
the gateway control API to private request custody and CA order creation. It
persists request keys before external creation and saves immutable issuer/order
identity before Marshall binding. Saved keys and order URLs are revalidated on
recovery; a missing key for already bound work cannot be regenerated. A durable
attempt marker prevents a second CA order for the same issuance when creation's
outcome is unknown. This is not an exactly-once CA guarantee: unknown attempts
need a later failed-work/backoff policy before a replacement issuance.
Custody properties and
order preparation tests were added for
immutable origins, missing keys and ambiguous attempts. They remain unrun pending
the consolidated verification pass. Scheduling, challenge propagation checks,
finalization, installation and renewal are still to be connected.

Certificate progression now composes
order preparation, fresh CA polling, exact base/wildcard authorizations,
authenticated proof registration, challenge acknowledgement, finalization and
validated certificate download into a resumable pass. A ready result means
validated material is durable in custody, not installed or publicly routed.
Propagation checking queries every
configured Audi nameserver directly over bounded TCP, requiring authoritative
exact-owner TXT answers and the exact proof set. All observed TTL deadlines,
counted from each query's start, must remain live when the combined check returns.
No recursive resolver or address discovery fallback is used. Added
two-replica propagation properties
cover fresh convergence, missing/expired proofs and unavailable replicas; they
remain unrun. Scheduler/startup, installed-readiness production and renewal still
need integration, followed by complete positive workflow verification.

Catalog entries now include an optional latest issued certificate ID scoped to
the current gateway identity/generation and stable VM label. This permits local
custody recovery after restart without equating old execution with fresh route
authority. The [installation helper](../../../audi/lib/audi/tls/installation.ex)
restores custody under store revision/tombstone checks and calls a
[local TLS probe](../../../audi/lib/audi/tls/probe.ex). The probe requires a real
loopback handshake with exact VM SNI, current operator trust and matching served
leaf fingerprint. Missing listeners, expired metadata and mismatches fail.
[TLS properties](../../../audi/test/tls_material_test.exs) and catalog/domain cases
were extended but remain unrun. Scheduler and readiness API wiring are still
required; this helper alone does not publish a route or forward application data.

The installation producer now has a `publish` operation that restores custody,
proves local TLS service, derives certificate expiry/digest and sends the current
execution binding through the authenticated `route-ready` API. The
[shared readiness schema](../../../protocol/lib/overalls_protocol/ingress_route.ex)
rejects supplied addresses, user authority and route lifetimes. Marshall retains
the existing current-execution checks and five-second report lifetime. The API
trusts its authenticated gateway's installation attestation; it does not perform
an independent remote certificate probe. Added
[readiness properties](../../../protocol/test/ingress_route_test.exs) and HTTPS
transport cases remain unrun. The producer is callable but not yet scheduled or
enabled in deployment; application forwarding and full acceptance remain open.

The certificate worker now has independent
issuance and readiness modes. Issuance admits up to four jobs per round. When
active orders and other VMs are both due, at most three slots go to active orders;
the groups rotate independently so indefinitely pending orders cannot starve
other VMs. An empty group leaves all four slots available to the other. Readiness
uses a bounded independent pool of
sixteen local probe/report jobs. A completed VM becomes due independently of
stalled jobs; slots are reused only after monitored job death. The pool cancels
changed/removed bindings and expires work under its original catalog deadline,
even if the scheduler is suspended. Both modes fetch authenticated inventory and
allocate store revisions before
asynchronous work. Removed inventories produce SNI tombstones. Retry delays and
reported CA retry-after values bound repeated attempts; these in-memory delays
are not a durable fleet-wide CA quota implementation. Issued material is restored
after restart using the catalog reference, and configurable expiry proximity
triggers renewal while the separate readiness loop keeps serving existing material.
Account startup saves keys before external
registration and requires explicit configured terms acceptance for registration;
otherwise only existing account recovery is attempted. Added
scheduler properties cover bounded fair
selection and retry deadlines on positive and negative monotonic clocks. Runtime
startup/Nix wiring and full worker integration tests remain outstanding; these
new tests have not been run under the deferred verification sequence.

The gateway's optional closed TLS configuration now starts the SNI store,
HTTP/HTTPS listeners, bounded task supervisor and separate readiness/issuance
workers through [application startup](../../../audi/lib/audi/application.ex).
The [Nix gateway module](../../../nix/domains/system/audi.nix) supplies separate public
trust credentials, private persistent certificate custody and explicit issuer
consent/replica settings. Config rejects unsafe custody, fewer than two replicas,
unknown fields and listener port collisions. Added startup and Nix evaluation
cases remain unrun. Browser authentication, actual guest web forwarding, full
worker/machine integration and fleet quota/performance acceptance remain open.

The [web header boundary](../../../audi/lib/audi/http/headers.ex) now implements
bounded request/response sanitization for the upcoming streaming proxy. It removes
hop-by-hop and Connection-nominated fields, owns framing separately, strips
`__Host-audi_` platform cookies and caller forwarding/identity headers, and
rebuilds Host/forwarding metadata from trusted connection context. Ordinary guest
Authorization and non-platform cookies are preserved. Guest response cookies
cannot use the reserved prefix; Domain attributes are removed and Set-Cookie
fields remain separate. [Header properties](../../../audi/test/http_headers_test.exs)
cover these boundaries but remain unrun. The module is not yet connected to guest
forwarding or browser SSO and does not itself establish authentication.

Marshall now models [one-time browser exchanges](../../../marshall/lib/marshall/ingress/web_login.ex)
and [browser credentials](../../../marshall/lib/marshall/ingress/web_credential.ex)
in Ash/PostgreSQL. The [coordinator](../../../marshall/lib/marshall/ingress/web_logins.ex)
binds gateway execution, VM/app and a browser-state digest, verifies the current
stored Marshall login and Cedar web membership, then issues a short-lived code.
Redemption rechecks state/code/login/execution and atomically consumes the exchange
with cookie credential creation. Only token hashes persist. Cookies bind the
original login and gateway generation and expire within twelve hours or that
login's earlier expiry; they do not directly authorize streams. Limits are 128
live exchanges and 1,024 live credentials per gateway. Separate bearer purposes
prevent ticket/code/cookie substitution.
The [generated migration](../../../marshall/priv/repo/migrations/20260918013711_audi_browser_exchange.exs)
was reviewed: its forward path creates only these tables/audit tables, constraints
and indexes. It has not been applied. Added exchange/replay/state properties remain
unrun. Browser HTTP redirects/callbacks, transport APIs, retention and per-stream
web authorization still need connection before SSO is usable.

The [browser exchange codec](../../../protocol/lib/overalls_protocol/web_login.ex)
and control API/client now connect begin/redemption with strict bearer purposes
and expected-host reply binding. User approval remains exclusively on Marshall's
[logged-in browser controller](../../../marshall/lib/marshall_web/controllers/audi_login_controller.ex),
which validates the fixed sign-in return path and uses the domain's configured
callback hostname. Ticket-bearing routes are privacy-tagged before logging.
Audi's [browser handler](../../../audi/lib/audi/http/browser.ex) creates host-only
Secure/HttpOnly/SameSite state cookies, redeems callbacks using the state proof,
sets the distinct credential cookie and returns only to bounded local paths.
Duplicate credential cookies fail closed. The HTTPS front dispatches reserved
callbacks only after Host/SNI validation. Begin remains callable but awaits the
web-admission result that triggers sign-in; ordinary app requests still return
503 until stream authority and forwarding are connected. Added codec/browser
properties remain unrun; complete browser acceptance remains outstanding.

Issuance records can now atomically bind a CSR SHA-256 fingerprint, issuer
directory, order, finalize and two authorization URLs. The internal action
rechecks current gateway execution and pending status before binding. It accepts
only same-origin HTTPS resources and immutable exact replay; conflicts leave
the old order intact. Re-admission returns the saved order for recovery. URL
attributes are sensitive and excluded from audit versions; the binding digest
is audited. A database constraint enforces the all-or-none order shape.
These URLs remain gateway attestations, not permission for Marshall to fetch
them or an independent issuer-validation result. Audi must still enforce its
configured issuer origin on resumed network operations. Gateway delivery is wired
below; automatic challenge progress and renewal remain unfinished.

The internal issuance coordinator now records one or two distinct canonical
DNS-01 SHA-256 proof values only after order binding and fresh execution checks.
The first set is immutable. Explicit authenticated refresh renews that same set
for 60 seconds from database time; recovery reads never refresh expiry. Initial
registration is audited without proof bodies, while heartbeat-only refreshes
do not add audit history. PostgreSQL enforces proof/expiry pairing and order
presence. Tests cover invalid values, conflicts, stale execution, read-only expiry
behavior and direct constraint rejection. These are stored gateway attestations,
not independently derived proofs or DNS publication permission. The authenticated
replication coordinator described below revalidates binding, status and expiry
before distributing them; a raw stored row cannot bypass those checks.

The shared certificate request/response schema
now connects admission, order binding, proof registration and terminal completion
through the [authenticated API](../../../marshall/lib/marshall_web/ingress_api.ex)
and [Audi client](../../../audi/lib/audi/control/client.ex). Requests have closed
versioned fields and bounded values; order requests allow 16 KiB, other control
requests retain 4 KiB. Certificate recovery replies allow 32 KiB. The client checks
configured host, execution fields, issuance ID and returned order digest.
Completion rechecks current execution and the CSR, records an immutable issued
or failed outcome and releases pending quota/proof eligibility without creating
readiness. Bound orders are required for success; unbound work can fail.
Protocol properties and
historical domain/HTTPS tests
were added for closed fields, canonical proofs, recovery, revocation and terminal
idempotency. Execution of these new checks is deferred under the user's instruction
to connect remaining functionality before full verification. These endpoints do
not yet establish an automatic ACME worker or installed-certificate publication.

The [gateway catalog coordinator](../../../marshall/lib/marshall/ingress/catalog.ex)
now supplies worker discovery through a Service Ash action and authenticated
`gateway-catalog` endpoint. It locks gateway/host authority and reads at most
10,001 active running local placements in one SQL statement; overflow rejects
the complete result. Inventory has no issuance or route authority. Every later
mutation still rechecks execution. The [shared catalog decoder](../../../protocol/lib/overalls_protocol/ingress_catalog.ex)
rejects unknown fields, duplicate VM/placement/label identities and mismatched
UUID labels. Audi binds the configured host and counts the five-second freshness
window from request start, with a 4 MiB response bound. Added
[catalog properties](../../../protocol/test/ingress_catalog_test.exs) and domain/
HTTPS cases cover these boundaries; execution remains deferred with the broader
implementation work. Automatic worker startup and physical acceptance remain open.

An internal current-proof projection now performs that per-record revalidation:
it locks gateway, host, VM and issuance, rejects stale execution, non-pending
work, invalid proof values and expired proof deadlines, and returns only issuance
ID, stable label, proofs and at most five seconds of remaining validity. Callers
must count validity from request start. Reads never refresh deadlines or audit
history. Tests cover fresh selection, omission of issuer URLs, stale/retired/
rotated/malformed rejection and expiry bounds. This is not yet an authenticated
replica feed or DNS request backend; Audi continues to answer from its local
directory and does not call Marshall per DNS packet.

The authenticated `dns-proofs` control endpoint now exposes that projection to
current DNS-role credentials only, retaining the credential lock through the
projection. [Audi's client](../../../audi/lib/audi/control/client.ex) validates a
closed versioned reply, exact requested label, issuance ID, canonical proof set
and at-most-five-second TTL, then derives expiry from monotonic request start.
Expired responses return no proof. [Real HTTPS tests](../../../marshall/test/marshall_web/ingress_transport_test.exs)
cover the actual Ash/API/client path, role rejection, revocation, malformed replies
and response delay. The four-KiB transport bound remains unchanged. This endpoint
does not supply a complete catalog or snapshot revision, and the client does not
publish it to the DNS directory. The complete publication producer and runtime
wiring described below use a separate endpoint.

The [snapshot receiver](../../../audi/lib/audi/dns/snapshot.ex) and
[background replica worker](../../../audi/lib/audi/dns/replica.ex) now implement
the Audi side of a complete `dns-snapshot` feed. The closed version-one envelope
binds the configured zone, a nonnegative 64-bit revision, a lifetime of at most
five seconds, and separate route/proof collections with independent shorter
lifetimes. Each collection and their union are bounded to 10,000 VM labels;
routes accept one to eight canonical distinct IPs, and proofs one or two
canonical distinct SHA-256 digests. The snapshot response alone has an eight-MiB
bound; existing control replies retain four KiB. All deadlines use monotonic
request start. A changed deadline is changed snapshot content and requires a
new revision; a producer must not reuse a revision to refresh different content.

The worker issues one verified HTTPS request at a time and waits one second
after completion before retrying. Only a complete validated response reaches
atomic directory publication. Failure preserves previous state without renewing
it. An independently expired address entry returns SERVFAIL, even while the
snapshot remains fresh; it cannot fabricate NXDOMAIN. A newer complete empty
snapshot can authoritatively remove entries. [Receiver tests](../../../audi/test/dns_replica_test.exs)
drive actual HTTPS, UDP and TCP, including alternate ports, TXT, malformed replies,
outage, expiry, recovery and removal. [Envelope tests](../../../audi/test/dns_snapshot_test.exs)
cover request-start deadlines, strict bounds and a 10,000-label decode. That is
decoder coverage, not fleet throughput evidence. These tests use a controlled
HTTPS publisher. The subsequent producer and startup integration below connects
the same receiver to actual Marshall state; fleet throughput remains unverified.

[Publication](../../../marshall/lib/marshall/ingress/publication.ex) now stores a
durable per-zone revision through Ash. Its
[coordinator](../../../marshall/lib/marshall/ingress/publications.ex) authenticates
the DNS credential and configured zone, holds the credential's shared lock, and
serializes revision allocation and selection with a transaction-scoped per-zone
advisory lock. A failed snapshot does not commit a revision. This counter is
coordination metadata, not a business mutation; it does not generate PaperTrail
versions on every refresh. Existing endpoint, route and issuance auditing remains.

The complete inventory and current publication facts come from one bounded SQL
statement inside the trusted Ash coordinator. PostgreSQL statement visibility
provides a consistent committed view, and a single database timestamp evaluates
host freshness and route/proof lifetime. The statement normalizes that clock to
UTC to match timestamp storage independently of the database session time zone.
This read does not acquire the individual
VM mutation locks used for admission: it grants no stream authority, and the
receiver's request-start deadline bounds observation age. The query requires the
same current service/execution binding, fresh connected host, running state,
completed start/provision and committed-relocation readiness as the point reads.
It derives host identity from the current placement, not a VM-local host column.
More than 10,000 active endpoint rows rejects the complete snapshot; no truncated
catalog is published. Lock waits and database statements are bounded. Gateway
addresses, proof values and DNS name bounds are validated before returning data.

`POST /api/audi/v1/dns-snapshot` accepts only the closed version/zone request and
returns the complete receiver envelope. [Domain and HTTPS tests](../../../marshall/test/marshall/ingress/publications_test.exs)
exercise the actual Ash/API/Audi path, current-state rejection, independent expiry
on both sides of UTC (Honolulu and Kiritimati sessions),
and retained row preservation. [Concurrent transaction tests](../../../marshall/test/marshall/ingress/publication_order_test.exs)
use separate committed PostgreSQL connections and two DNS identities to verify
unique increasing durable revisions. They do not establish multi-node capacity.

The [startup configuration](../../../audi/lib/audi/config.ex) and
[application](../../../audi/lib/audi/application.ex) now require DNS control
credentials and start the refresh worker after the directory and listener.
The [DNS Nix module](../../../nix/domains/system/audi-dns.nix) passes private runtime
credentials using systemd `LoadCredential`, supports a CA bundle and prerequisite
secret services, and preserves the separate unprivileged role. The
[machine test](../../../nix/verification/tests/machines/audi-dns/default.nix) now exercises this
wiring against a controlled HTTPS publisher. Automated certificate/readiness
production, full Marshall-to-Firecracker deployment and fleet scale acceptance
remain outstanding; DNS publication cannot manufacture those missing records.

[Ingress domain](../../../marshall/lib/marshall/ingress.ex),
[endpoint resource](../../../marshall/lib/marshall/ingress/endpoint.ex) and
[endpoint coordinator](../../../marshall/lib/marshall/ingress/endpoints.ex) now
persist stable identity, private-by-default primary ports and audited visibility
revisions. New VM admission creates the endpoint in its existing transaction.
[Shared naming](../../../protocol/lib/overalls_protocol/ingress_name.ex) preserves
the complete VM UUID within a bounded label; alternate applications use
`p3000.<stable-label>.<zone>` through `p9999.<stable-label>.<zone>` on port 443.
[Endpoint tests](../../../marshall/test/marshall/ingress/endpoints_test.exs)
exercise actual PostgreSQL/Ash state, current membership checks and revision
conflicts. This does not yet publish endpoint data to Audi or grant proxy access.

[Service resources](../../../marshall/lib/marshall/ingress/service.ex) and the
[credential coordinator](../../../marshall/lib/marshall/ingress/services.ex)
persist audited DNS/gateway identities with immutable role/host binding, hashed
credentials, rotation and revocation. The bounded versioned
[control API](../../../marshall/lib/marshall_web/ingress_api.ex) requires actual
TLS and a purpose-specific service credential. Audi's
[HTTPS client](../../../audi/lib/audi/control/client.ex) verifies the server,
rejects redirects, bounds responses and validates the configured service binding.
[Real TLS transport tests](../../../marshall/test/marshall_web/ingress_transport_test.exs)
connect this client to the actual API; service identity does not establish user
permission, publication readiness or permission to connect to a guest.

[Monotonic lease interpretation](../../../audi/lib/audi/authority/lease.ex) and
the [stream lifetime guard](../../../audi/lib/audi/authority/stream_guard.ex)
now enforce a maximum five-second request-start deadline for trusted grants.
Renewal pins the complete binding and cannot revive expired authority. A separate
watchdog closes the resource-owning process when the guard dies or stalls.
[Lease properties](../../../audi/test/authority_lease_test.exs) exercise delay and
expiration; [socket tests](../../../audi/test/stream_guard_test.exs) verify closure
on expiry, denial, placement changes, guard death and suspension. These components
are now exercised by the SSH transport and Marshall proxy sessions below;
actual guest connector sockets remain unimplemented.

The [OTP SSH listener](../../../audi/lib/audi/ssh/listener.ex),
[key proof](../../../audi/lib/audi/ssh/proof.ex) and
[leased byte relay](../../../audi/lib/audi/ssh/channel.ex) implement the outer SSH
transport. Only `connect <stable-label>` is accepted; shells, PTYs, subsystems
and both general TCP forwarding directions are disabled. The channel validates
the configured host, SSH service/port and complete placement/session identity
before opening a connector, and runs renewal outside its guarded I/O process.
[Transport tests](../../../audi/test/ssh_transport_test.exs) exercise OTP clients
and a real OpenSSH client with strict host verification against a loopback
connector fixture, including unsigned probes, renewal denial and stalled renewal.
The default [backend](../../../audi/lib/audi/ssh/backend.ex) denies all requests;
the explicit control backend below supplies Marshall authority and the local
Lilly connector. Configured startup enables the SSH listener. The transport tests
do not prove guest SSH login, relocation host-key lookup, KVM isolation or deployment.

[Source privacy filtering](../../../audi/lib/audi/privacy.ex) sanitizes OTP and
SSH reports before logger handlers. Reviewed stream-open events retain only
validated UUID identifiers with fixed text. [Canary checks](../../../audi/test/privacy_test.exs)
verify payload removal; host collector integration remains outstanding.

Marshall's [proxy session resource](../../../marshall/lib/marshall/ingress/session.ex)
and [SSH coordinator](../../../marshall/lib/marshall/ingress/sessions.ex) now
implement durable SSH admission and renewal. They recheck the registered key,
gateway generation, current Cedar write membership (owner/operator/manager),
host freshness and the exact running placement/epoch/generation. Admission also
respects retained relocation readiness. Five-second database expiry and closure
prevent session revival; a re-registered key has a new identity and cannot restore
old sessions. Credentials are stored only as hashes; heartbeat renewal does not
create audit versions. [Bounded cleanup](../../../marshall/lib/marshall/ingress/retention.ex)
removes sessions expired for seven days while retaining admission/closure audit.
[Database tests](../../../marshall/test/marshall/ingress/sessions_test.exs) cover
sharing histories, key/gateway changes, expiry, execution changes and cleanup.
The bounded control API now exposes SSH admission, renewal and closure. Audi's
client validates closed grant envelopes and pins host, label, VM, placement,
epoch, lifecycle generation and session identity. Its
[control backend](../../../audi/lib/audi/ssh/control_backend.ex) connects the SSH
channel to these actions over verified HTTPS. A live SSH-to-HTTPS integration
test exercises real key revocation through Ash and observes both connector socket
and SSH channel closure. The connector in this test is explicitly a loopback
fixture; deployed guest access remains unavailable.

The [local connector schema](../../../protocol/lib/overalls_protocol/ingress_connect.ex),
[Audi Unix client](../../../audi/lib/audi/connector.ex) and
[Lilly Unix server](../../../lilly/lib/lilly/ingress/server.ex) now implement the
local handoff transport. Both sides check Linux peer credentials before disclosing
or accepting a binding. Requests are bounded, closed and host-bound; only SSH port
22 is currently supported. The server requires an explicit local backend and an
execution guardian, bounds concurrent streams and setup time, and closes both
ends when the guardian exits. Neither application enables this listener by default.
[Client tests](../../../audi/test/connector_test.exs) and
[server tests](../../../lilly/test/ingress_server_test.exs) use actual Unix sockets
and loopback guest fixtures. The [execution backend](../../../lilly/lib/lilly/ingress/backend.ex)
now resolves the exact connected runtime and observed actor identity through a
[watchdog](../../../lilly/lib/lilly/ingress/guardian.ex). Restored or stale running
observations cannot authorize a stream. [Namespace sockets](../../../lilly/lib/lilly/network/ingress.ex)
and the optional [marked SSH policy](../../../lilly/lib/lilly/network/policy.ex)
implement the ADR-0052 exception. They require explicit operator enablement;
the Lilly NixOS module now exposes `ingress.enable` and binds it to a matching
local Audi identity. Firecracker acceptance remains outstanding.

[Source-built packages](../../../nix/domains/artifacts/default.nix) now include Audi and
its encrypted-dump variant with a fixed dependency hash; host-tool metadata and
symlinks are explicitly Lilly-only. The exported `audi-release`
[payload check](../../../nix/verification/tests/release/probe.exs) passed for the actual Nix
release and verifies runtime and application independence. The gateway
[runtime configuration](../../../audi/lib/audi/config.ex) and
[application startup](../../../audi/lib/audi/application.ex) now select the real
Marshall authority and UID-checked local connector. Configuration is bounded and
closed, private files require service ownership and restrictive permissions, and
invalid configured startup fails without exposing secret contents. Registry loss
restarts the dependent SSH listener. The [NixOS module](../../../nix/domains/system/audi.nix)
runs an unprivileged independent release with systemd credentials, a persistent
Ed25519 host key and explicit administrative/Porsche port collision checks.
Its configuration and service machine checks passed against the packaged release;
these cover service startup without Marshall or a Firecracker guest.
[Socket custody](../../../lilly/lib/lilly/ingress/socket_custody.ex) holds a
persistent exclusive OS lock and a private exact-path claim for crash recovery.
Unclaimed sockets and replacement files are never removed. The
[Lilly application](../../../lilly/lib/lilly/application.ex) starts the connector
after its runtime, with the execution guardian fixed as its backend. Loss of the
runtime restarts dependent admission. Complete ingress deployment acceptance
remains outstanding.

The gateway service now stores a generation-bound Ed25519 host key through its
[Audited Ash service resource](../../../marshall/lib/marshall/ingress/service.ex)
and [serialized publication action](../../../marshall/lib/marshall/ingress/services.ex).
The first canonical key is immutable within its credential generation; repeated
publication is idempotent and rotation/revocation atomically clears it. DNS
credentials cannot publish gateway keys. The closed HTTPS `host-key` control
route returns the exact host/key/generation acknowledgement.
Audi [derives the public key](../../../audi/lib/audi/ssh/host_key.ex) from its
private Ed25519 key, offers only that host-key algorithm, and runs a
[bounded publisher](../../../audi/lib/audi/ssh/key_publisher.ex) after listener
startup. It retries every 30 seconds after completion without extending any
stream authority. User public-key algorithms remain independently validated.
Registration is not placement publication or readiness. The public lookup now
requires a current readiness projection. Authenticated configuration downloads
now use a fresh stored browser login and a VM-serialized Cedar write check through
the Ash endpoint action. The former `MarshallWeb.SSHConfigController`
returns a non-cacheable attachment using the configured application zone and
Marshall endpoint origin. The machine detail page offers the download to writers;
server-side checks reject viewers, web-only members, revoked grants and revoked
logins. Downloading a profile grants no connection authority and does not establish
certificate/report publication readiness.

The former `Marshall.Ingress.SSHConfig` renderer could
construct an exact per-VM profile with strict outer Ed25519 host-key verification,
verified bounded HTTPS lookup, HTTP-200-only acceptance and no persistent outer
host cache or connection multiplexing. It preserves the inner guest's normal
known-hosts files and rejects shell/configuration/SSH-token injection. The
[NixOS client-flow check](../../../nix/verification/tests/machines/audi-openssh/default.nix)
uses real OpenSSH and curl with controlled stock sshd and HTTPS fixtures. Its
scope is client configuration, not Marshall publication or Audi/Firecracker
acceptance. Configuration generation grants no access by itself.

The download and renderer described above were retired on 2026-09-25; see the
[retirement review](../reviews/2026-09-25-ssh-config-download-retirement.md). This is historical implementation evidence.
The native check now uses test-only profiles and Lyra Rust HTTPS lookup.

Gateway enrollment now persists up to eight operator-owned canonical IP literals
in the service resource. Address-set changes advance the gateway generation and
clear its registered key under the same lock; order-only changes are idempotent.
The [service tests](../../../marshall/test/marshall/ingress/services_test.exs)
exercise the durable transition and audit, including generated address histories.
These addresses do not establish reachability or certificate/execution readiness
and are not yet published as routes.

The TLS material validator validates
bounded PEM inputs against operator trust using OTP PKIX path validation,
requires exact base/per-VM wildcard SANs and server-authentication usage, and
proves the supplied P-256 ECDSA private key matches the leaf. Its effective expiry
is the earliest expiry in the validated chain, including the trust anchor.
[TLS tests](../../../audi/test/tls_material_test.exs) exercise a real verified
TLS 1.3 handshake, intermediate chains, negative certificates and arbitrary input.
This is local material validation only: automated ACME issuance, deployed key custody,
listener installation/renewal, revocation checking and publication acknowledgement
are not yet implemented. It does not turn certificate metadata into readiness.

The [local TLS store](../../../audi/lib/audi/tls/store.ex) now atomically installs
validated material and supplies OTP SNI options for base and canonical alternate
names. It rejects unknown, removed, expired or unavailable selections without
default-certificate fallback. Monotonic revisions and retained removal tombstones
reject delayed replacements; entry count and certificate/key byte budgets bound
storage. Tests exercise real primary/alternate TLS handshakes, revision histories,
removal, expiration, capacity and redacted status. It is not yet wired into the
production listener or a durable publication/installation acknowledgement.

The [HTTP listener](../../../audi/lib/audi/http/listener.ex) now uses the same
pinned Bandit stack as Marshall, with finite connection/header/idle bounds and
disabled peer-input diagnostics. Its
[TLS transport](../../../audi/lib/audi/http/tls_transport.ex) adds an explicit
five-second handshake deadline to Thousand Island's otherwise unbounded default.
The [front plug](../../../audi/lib/audi/http/front.ex) redirects only installed
names, ignores forwarded identity and requires HTTPS Host/SNI agreement. It
returns 503 after origin checks because route/session authority is not connected.
Real socket tests cover redirects, rejection, Host/SNI mismatch and silent TLS
clients. HTTP/2 and WebSocket upgrades are disabled in this initial HTTP/1.1
listener. Production configuration, forwarding and WebSocket support remain
outstanding; this listener is not yet started by gateway deployment.

The [route resource](../../../marshall/lib/marshall/ingress/route.ex) and
[report coordinator](../../../marshall/lib/marshall/ingress/routes.ex) now persist
an internal authenticated gateway readiness report. Admission locks service,
host, VM and route; it requires matching service/execution generations, fresh
running evidence, completed relocation/start readiness, addresses and an SSH key.
A report lasts at most five seconds and never beyond its certificate metadata.
Binding changes are audited; refreshes are not. The
[domain tests](../../../marshall/test/marshall/ingress/routes_test.exs) exercise
PostgreSQL transitions, stale binding rejection, certificate limits and auditing.
Certificate metadata is a trusted infrastructure attestation, not independent
proof. This action has no HTTP exposure or gateway producer; validated certificate
installation must precede a future report. The internal current-route action now
revalidates the service, host, VM and report under shared locks, returning the
current gateway addresses/key only while execution and certificate/report
freshness remain valid. Its TTL uses the database clock after locking and is
capped at five seconds. Tests reject missing/expired reports, rotation even after
key re-registration, stale hosts, changed execution and ordinary user actors.
The complete snapshot producer now applies the same current-state predicates
before distributing address records to Audi DNS.
Persisted report rows alone must not be consumed as current published routes.

The [public known-hosts endpoint](../../../marshall/lib/marshall_web/ingress_known_hosts.ex)
now consumes this current-route action on each HTTPS GET. It returns one exact
hostname/key line with `no-store`, no internal route metadata and no key on
missing/stale authority. `MARSHALL_INGRESS_ZONE` supplies the operator-owned zone;
request headers and parameters cannot choose it. The route tests cover missing
readiness, valid output, transport/method/query rejection and gateway disablement.
Without an actual certificate-installation report producer, this endpoint does
not establish operational publication or relocation acceptance.

Web-only sharing now uses an audited `web` grant in the existing
[Access resource](../../../marshall/lib/marshall/access/grant.ex), with a separate
[Cedar action](../../../marshall/priv/cedar/compute.cedar). Owners and all existing
VM roles also receive web permission. Web-only users cannot list/read VM
management data, manage sharing, use terminals or obtain SSH authority. Grant
replacement closes terminal sessions transactionally. Role-matrix, persisted
replacement and terminal properties include the new role; explicit tests cover
management listing and SSH denial. The UI exposes the role, but browser SSO,
web sessions and HTTP forwarding are still unimplemented.

## Open questions


Deployment domain, certificate issuer quotas and independent physical-host
capacity remain deployment inputs. The bounded fleet composition has passed
native SSH, browser/web, DNS failover, revocation, isolation and CA-outage
recovery. Publication-backed SSH key lookup still needs the broader relocation
and lookup-failure acceptance matrix. Actual fleet capacity and the broader
actor/runtime crash and storage-failure matrix remain unproven. A passing
composition is not a claim that all deployment acceptance is complete.

The fleet script now also contains a certificate-custody permission fault:
restart the gateway with unreadable retained storage while the CA is unavailable,
require route withdrawal and rejected SSH/HTTPS, then restore permissions and
require the same TLS certificate and surviving guest process. The scenario
preserves the original directory and restores permissions in a `finally` block.
Its physical subtest now passes in 11.06 seconds, verifying unchanged public
certificate fingerprint, directory inode and guest process after recovery.
The surrounding fleet script subsequently failed at relocation source cleanup
after destination readiness. Source cleanup now additionally uses bounded pool
acquisition retries; closed utility diagnostics identify timeout/ownership
failures without exposing arguments or output. Verification of these later
changes remains pending, as recorded in the review.

## Related decisions

[ADR-0090](0090-second-audi-dns-replica-on-worker.md) amends this record's
DNS placement requirement for a single-control-plane fleet, and
[ADR-0091](0091-fleet-perimeter-public-listeners.md) amends the fleet
perimeter so these listeners accept anonymous public clients.
[ADR-0002](0002-elixir-ash-and-types.md),
[ADR-0007](0007-profile-networking.md),
[ADR-0052](0052-fenced-local-guest-ingress.md),
[ADR-0008](0008-identity-sharing-and-terminal.md),
[ADR-0018](0018-persisted-sharing-and-user-machine-access.md),
[ADR-0037](0037-workload-placement-and-relocation.md),
[ADR-0042](0042-host-observability.md),
[ADR-0043](0043-declarative-host-provisioning.md),
[ADR-0046](0046-porsche-ssh-management.md).

Web stream authority now has an implementation in
[`WebStream`](../../../marshall/lib/marshall/ingress/web_stream.ex) and
[`WebStreams`](../../../marshall/lib/marshall/ingress/web_streams.ex), with closed
[wire messages](../../../protocol/lib/overalls_protocol/web_stream.ex), gateway API
and request-start expiry in Audi's control client. Public primary access and
private stored-login/Cedar access use execution- and policy-bound five-second
leases. Added property tests cover policy transitions, alternate-port privacy and
non-resurrection. The migration and tests await consolidated verification; guest
web transport and watchdog integration remain incomplete.

The [web frontend](../../../audi/lib/audi/http/proxy.ex) now connects leased HTTP
streaming through the local connector, with [independent renewal](../../../audi/lib/audi/http/authority.ex)
and a [WebSocket relay](../../../audi/lib/audi/http/web_socket.ex). WebSocket
handshake proof, subprotocol and bounded frame checks are implemented separately
from browser authentication. Transport/property tests pass in Audi’s application
gate, including real HTTP uploads, truncated responses and WebSocket framing. These checks alone do not
prove deployed app access or fleet readiness.

[Web retention](../../../marshall/lib/marshall/ingress/web_retention.ex) now
schedules bounded dependency-aware cleanup after seven days of expiry, retaining
audit history. [Operational events](../../../audi/lib/audi/events.ex) use a fixed
vocabulary and source privacy reconstruction for web, DNS and certificate work.
The former issuance budgets
serialize rolling fleet/hour and VM/day admission against durable rows, including
failed work. The index migration and budget tests pass in Marshall’s application
suite. Actual issuer/fleet quota acceptance remains incomplete.

Retry custody now persists issuer-scoped
account/VM retry windows through atomic private file replacement. Before CA work,
it durably records an unknown outcome that cannot expire with time. Each issuer
has one exclusive staging file, retained on failure so repeated writes cannot
accumulate temporary records. Offline recovery validates and durably publishes a
complete staged record; corrupt or insecure records remain untouched. A saved
result replaces that marker with its absolute retry deadline. Failed result writes
are retried with the original deadline before further CA work; killed tasks and
crashes retain unknown custody. Reading durable state before reservation prevents
an older scheduler state from bypassing that marker. Readiness runs independently.

An operator may reconcile an unknown outcome offline only after stopping issuance
and establishing an issuer-safe absolute not-before time. Reconciliation preserves
all other entries and rejects expired deadlines and non-unknown targets. This
favors respecting issuer restrictions over automatically retrying an attempt whose
result was lost; a crash cannot establish whether the CA imposed a longer delay.
The prior one-minute reservation could not provide that guarantee. New properties
cover process death, stale state, rejected result writes and explicit reconciliation;
the final Audi gate passes 122 checks (39 properties, 83 tests), with zero
Dialyzer findings. The worker integration also restores readiness with unknown
issuance markers and the CA stopped. Broader power-loss and
filesystem fault acceptance remains separate.

New [browser exchange acceptance](../../../marshall/test/marshall_web/audi_login_controller_test.exs)
connects the actual Marshall controller/API to Audi's browser helper and stream
client. Certificate worker acceptance
connects a controlled CA, two Audi DNS replicas, private custody and a real TLS
listener, including CA-independent readiness recovery. Both pass in their
application suites and do not establish Nix/Firecracker or fleet acceptance.

The new [Audi fleet scenario](../../../nix/verification/tests/machines/fleet/scenarios/audi.py)
and [role composition](../../../nix/verification/tests/machines/fleet/audi.nix) deploy actual
Audi/Marshall/Lilly releases and nested Firecracker with two Audi DNS replicas and
a DNS-validating Pebble CA. The updated full composition passes in 601.56 seconds with
nested KVM. It verifies DNS-validated certificate issuance, public HTTPS, live
public-to-private revocation, and private browser HTTP/WebSocket access on primary
and alternate hosts, including host-only cookies and unshared-user denial.

The same run verifies native nested OpenSSH with independent platform/guest keys
and strict guest host pinning. Revoking the platform key closes the live session
without stopping the VM. Actual guests cannot reach same-host siblings,
cross-host guests or host services, including with guest-selected socket marks.
Stopping the control plane expires live web authority and makes DNS fail closed;
recovery restores access. One DNS node serves while the other restarts. Restarting
the gateway with the CA stopped restores certificate readiness from custody and
preserves the VMM. The production default guest image stays console-only.

Nix configuration and namespace network checks also pass. This evidence covers
the acceptance composition, not a production deployment, long-running capacity,
or the complete crash/storage-failure matrix. Implementation remains partial.
The [review](../reviews/2026-09-17-audi-ingress.md) records fixture corrections,
application gate results and remaining limits.


The opt-in [publication capacity measurement](../../../marshall/test/marshall/ingress/publications_test.exs)
now populates 10,000 publishable routes across 100 distinct gateway identities,
including host, pool, placement and completed-operation rows. Ten real publication
action samples return the full catalog in 142–253 ms without changing production
deadlines. This is a synthetic database projection measurement; it excludes
readiness writes, HTTP/DNS transport and physical guest traffic and does not
establish sustained fleet capacity. The [access guide](../../services/audi.md) documents
the explicit command; normal gates exclude the capacity tag.

The passing physical rerun includes independent readiness completion, fair issuance
selection and explicit DNS recovery before single-node failure injection. The
later bounded retry-staging refinement is covered by the 129-check Audi application
gate, not that physical snapshot. Remaining capacity claims retain the narrower
measurement scope described above.

A separate opt-in readiness baseline uses a valid gateway credential to refresh
100 distinct routes through the real authenticated Ash action in the 10,000-VM
fixture. Three sequential rounds take 780–861 ms, retaining all 100 fresh routes
under the unchanged five-second deadline. This establishes a per-gateway action
baseline only; concurrent gateways and producer/network costs remain unmeasured.

A subsequent [committed-load diagnostic](../measurements/2026-09-18-audi-readiness.json)
uses 100 concurrent gateway workloads and independent database connections with
16 BEAM schedulers and a 32-connection pool. All 10,000 readiness actions succeed
and remain fresh in each of three 4.69–4.72-second rounds. Synthetic heartbeat
updates maintain host freshness. The small remaining deadline margin, excluded
producer/network costs and short duration prevent treating this as full fleet
capacity acceptance; a reusable committed-load harness remains to be integrated.


The reusable [capacity harness](../../../marshall/scripts/audi_capacity.exs) now
exercises actual Audi HTTPS readiness requests against committed fixtures. The
[measurement artifact](../measurements/2026-09-18-audi-readiness.json) retains a
failed 16-scheduler/32-connection run: all updates succeeded, but three rounds
exceeded five seconds and some routes expired. Capacity acceptance remains open;
the earlier Ash-only result does not establish HTTPS or fleet throughput.

The harness now also samples freshness during each round on an independent
database connection, waiting 100 ms between queries. After the bootstrap round,
any observed expired/missing route fails the measurement even if the endpoint
count recovers. Aggregate diagnostics include sample count and maximum observed
gap; they do not establish uninterrupted availability. The sampler adds load,
so earlier unsampled measurements remain distinct. A three-round diagnostic
under concurrent fleet-test and compiler load executed this stronger check:
all updates succeeded, but rounds took 5.53–5.61 seconds and sampled freshness
fell below endpoint counts. The unchanged deadline and freshness checks failed.
The linked artifact preserves these results separately from isolated runs.

Allocation comparisons using the same HTTPS harness also failed: 32 schedulers
and 64 connections took 5.76–6.31 seconds per round; eight schedulers and 16
connections took 8.95–9.50 seconds. All updates succeeded, but each round had
expired routes. These measurements do not establish an adequate deployment
configuration; aggregate results remain in the linked measurement artifact.


Readiness reporting now obtains an existing route with one locking Ash read by
VM identity, removing the earlier preliminary lookup. The already-held VM lock
continues to serialize creation, and service/host/VM/route ordering is unchanged.
The [route properties](../../../marshall/test/marshall/ingress/routes_test.exs)
exercise refresh/replacement sequences and exact revision increments. This is a
request-cost reduction, not evidence that the fleet capacity target is met.


The shared [execution check](../../../marshall/lib/marshall/ingress/execution.ex)
now asks Ash whether a matching completed start/provision exists instead of
materializing operation records. Exact execution predicates match the existing
publication SQL, with no eligibility or lock-order change. Generated status/kind
sequences exercise both readiness reports and current-route projections.

## Amendment 2026-09-22: production guest SSH endpoint

[ADR-0093](0093-audi-mediated-guest-ssh.md) makes the existing VM-bound port-22
route usable by standard production guests. Audi remains the outer current
authorization and revocation boundary; key bootstrap does not grant a new route.
