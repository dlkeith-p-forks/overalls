# Audi implementation review

## Scope

Audi's independent release, authoritative DNS, HTTP/HTTPS and SSH ingress,
Marshall Ash authority, Lilly isolation and Nix deployment. ADR-0047 records the
authorized target. Previously uncommitted relocation work is committed, and
upstream Porsche and Brady changes are merged without discarding local work.

## Current status — September 18

Audi has an independent release, authoritative UDP/TCP DNS, HTTP/HTTPS/WebSocket
and nested SSH ingress, authenticated Marshall control, fenced Lilly connectors,
structured private logging and Nix deployment modules. The complete captured
`audi-relocation-fleet` final merged script passes in 1520.47 seconds with terminal
exit zero.
It includes the real move, source cleanup, destination DNS, unchanged strict SSH
with retained data, HTTPS at the stable name and stale-source refusal, plus the
Lilly main-process crash and gateway/DNS package-update recovery scenarios.
That clean snapshot is `695ee8f`, including bounded pool-acquisition retries,
private utility logs and the merged main networking changes. Subsequent Audi
changes only update documentation.

The preceding cleanup-refinement run passes in 1668.42 seconds, and the final
merged run also passes certificate-storage recovery, actual source cleanup and
all post-move access checks. The earlier cleanup failure is retained below.
The authorized implementation and its verification are complete.
The user removed large-fleet capacity investigation from scope on September 18;
historical capacity measurements below are not completion gates or deployment
capacity claims.

The subsequently merged tree passes Lilly's 331-check gate (39 properties),
protocol's 134 (51 properties), Audi's 140 (46 properties), and Marshall's 725
(64 properties; two opt-in cases excluded). All required Dialyzer gates pass.
Physical verification of that merged tree also passes.
The extended completed-handoff publication regression passes with the
other focused publication checks; it uses synthetic database state and cannot
establish physical relocation. Exact revisions, logs and subsequent results are
retained below. Earlier sections are chronological evidence, not current feature
inventories; ADR-0047 is implemented for the authorized scope.

## Requirement audit — current scope

The user's September 18 scope correction removes scale investigation. It does
not remove DNS, SSH/web access, isolation, logging, deployment modules or tests.
The following audit distinguishes implemented behavior from deployment inputs.
The custody-fault fleet run failed at source cleanup; the subsequent cleanup
refinement passes application and native verification. Physical verification of
the subsequently merged main networking changes also passes.

| Requirement | Implementation and verification |
| --- | --- |
| Audi owns authoritative DNS | The [server](../../../audi/lib/audi/dns/server.ex) binds UDP and TCP itself. Wire, replica and directory properties plus two independent packaged DNS nodes cover authoritative answers, expiry and failover. No external DNS server implements the role. |
| DNS placement and short TTL | The [service diagram and guide](../../services/audi.md) place two DNS replicas on control hosts and gateways beside Lilly. Address TTL is 20 seconds. Marshall publishes placement state; it does not create per-VM DNS-provider records. Fleet relocation verifies both replicas change to the destination. |
| Audi owns SSH proxying | The [OTP SSH listener](../../../audi/lib/audi/ssh/listener.ex) disables host shells and generic forwarding. Real nested OpenSSH reaches guest port 22 with separate platform and guest keys; strict verification and revocation are exercised. |
| HTTP/HTTPS and WebSockets | The [web proxy](../../../audi/lib/audi/http/proxy.ex) and browser/session authority run against a real guest application. The fleet verifies private login, streaming, WebSockets, public-to-private changes and CA-offline recovery. |
| Current authorization and local isolation | [Lilly's guardian](../../../lilly/lib/lilly/ingress/guardian.ex) and namespace connector bind current placement/execution. Application tests cover expired/superseded authority; native tests cover revocation, control outage, daemon crash and same-host/cross-host/host denial. |
| Stable names across relocation | The [native scenario](../../../nix/verification/tests/machines/fleet/scenarios/audi-relocation.py) verifies retained data, physical source cleanup, destination DNS, unchanged strict SSH configuration, stable-name HTTPS and stale-source refusal. The final merged full run passes in 1520.47 seconds. |
| Authenticated-user and TCP-flow diagrams | The [access guide](../../services/audi.md) contains service-placement and nested-SSH sequence diagrams, browser behavior and client configuration instructions. |
| Ash domain modeling | [Marshall.Ingress](../../../marshall/lib/marshall/ingress.ex) owns endpoints, service identities, routes, issuance and sessions through Ash resources. Audi's runtime caches do not replace database authority. |
| Structured private logging | [Events](../../../audi/lib/audi/events.ex), [privacy filtering](../../../audi/lib/audi/privacy.ex) and transfer diagnostics emit closed metadata. Property tests exercise arbitrary private payloads and prevent their appearance in diagnostics or transfer stdout. |
| Nix deployment modules | [Gateway](../../../nix/domains/system/audi.nix) and [DNS](../../../nix/domains/system/audi-dns.nix) modules provide separate packaged roles, protected runtime credentials, readiness and update integration. The latest merged driver builds with type checking and linting; native runs exercise both roles and corrective updates. |
| Property-based and native tests | Merged gates: Audi 140 checks/46 properties; protocol 134/51; Lilly 331/39; Marshall 725/64. Required Dialyzer gates pass. Native ZFS transfer/recovery passes in 461.17 seconds. Snapshot-specific results and logs are recorded below. |
| Certificate storage recovery | The permission-loss subtest passes in 11.12 seconds within the successful final merged run: deny access while unreadable, recover the same certificate and surviving guest with the CA offline. The earlier full-run cleanup failure is retained below. |
| Commit, merge and preserve work | The implementation and preceding results are committed and merged into verified `origin/main` at `7d45d9e`. Original local work and interrupted experiment backups are retained. Final evidence documentation is published in the closing commit. |

A real deployment still supplies its domain delegation, host addresses, issuer
configuration and private credentials. The request implemented deployable
services and verified them in isolated Nix machines; these tests do not claim a
public production rollout or unmeasured fleet capacity.

## Initial findings

- High: Lilly's current network policy denies host-to-guest ingress. The gateway
  cannot safely treat guest IPs as ordinary upstreams. A placement-bound local
  connector and replacement for ADR-0007's ingress prohibition remain required.
- High: OTP SSH transport and standard OpenSSH clients require a deliberate host
  identity design across movement. Never work around this with disabled checking.
- High: default public ACME quotas do not establish capacity for 10,000 VMs.
  Issuance and relocation readiness must be verified separately from HTTP routing.
- Medium: Nix release metadata currently gives every non-Marshall app Lilly's
  privileged tool dependencies. Adding Audi requires explicit Lilly selection.

## Initial evidence and gaps

The initial diff adds a bounded DNS decoder and property tests, with an empty
supervision boundary. No listener is enabled and no guest isolation rule changes.
This slice does not establish DNS service, proxy behavior, deployment or capacity.
`devenv shell -- bash -c 'cd audi && mix precommit'` passed on 2026-09-17:
the pinned runtime, 47-record ADR validation, contract validation and its 19
regression tests, compiler/formatter checks, seven DNS checks (two properties and
five examples), and forced Dialyzer with zero errors or skipped warnings.
An initial opaque MapSet inference warning was resolved using a bounded plain
map for visited offsets; no warning suppression was introduced.

Audi also configures JSON logging and a protected OTP report translator. No
runtime credential-canary or collector integration test has run yet. Nix machine
tests and end-to-end guest ingress have not run. The full feature remains in
progress under ADR-0047.

## DNS serving slice

Audi now serves authoritative DNS over bounded UDP/TCP listeners from a local
directory. The directory rejects regressing revisions, conflicting content at
the same revision and expired publications. Uninitialized or unavailable state
returns SERVFAIL, while genuine missing names return NXDOMAIN with a five-second
negative TTL. TCP supports connection reuse; UDP overflow sets TC and omits whole
record sections. No recursion, transfer or external DNS daemon is enabled.

The full application gate passed with 16 checks, including three properties,
OTP-client interoperability over UDP and TCP, mixed-case question echo, and forced
Dialyzer with zero errors or skipped warnings. These are loopback process tests,
not NixOS deployment evidence.
Authenticated replication and production listener configuration remain missing.

## Endpoint authority slice

Marshall now owns ingress endpoints through Ash with AshPaperTrail versions.
Admission creates each new VM's private endpoint in the same transaction; endpoint
configuration holds the VM lock, checks current Cedar membership and requires a
matching policy revision. Identical configuration leaves the revision unchanged.
Labels contain the full VM UUID and remain independent of placement changes.

Four PostgreSQL endpoint checks (including a generated policy-history property)
and three shared-name checks passed. The migration creates only ingress endpoint
and version tables with unique identities, foreign keys and range constraints.
The domain-scoped generator also set unrelated snapshot opt-out flags; those
incidental changes were removed without altering their schema content. Distributed
test cleanup now removes only its own ingress rows before removing fixture VMs.
Protocol (71 checks), Lilly (212 checks) and Audi (16 checks) full gates passed.
Marshall's 360 checks, including distributed tests, six browser-state checks and
forced Dialyzer passed. Its one existing narrow upstream typespec exclusion
remains in use, with no unused suppressions or application findings. No proxy authorization API
or publication transport exists yet; browser sharing additions remain outstanding.

The shared gates exposed a duplicated map key and unformatted additions in the
ongoing relocation work. Minimal syntax/format repairs preserved its behavior.
The relocation import encoder now removes its import-only field before calling
the receive encoder, preserving the wire output and satisfying the latter's
closed command type; no authority or architecture semantics changed.

## Nix release slice

`nix build .#checks.x86_64-linux.audi-release --no-link -L` passed. The check
artifact is `/nix/store/ndkpc3n4maphd02yp2k5l4dngkyrddqm-audi-source-release-check`.
The application was compiled from selected source and fixed-hash dependencies.
Its payload check confirms runtime versions, shared protocol, Audi DNS modules,
absence of Marshall/Lilly application dependencies and absence of privileged
host-tool metadata/symlinks. The builder's previous non-Marshall test was replaced
with explicit Lilly selection. The encrypted-dump package is exported but its
Audi variant has not yet been built. No service or machine acceptance is claimed.

## Service control transport slice

Marshall now persists Audi service identity through Ash and AshPaperTrail. DNS
identities cannot bind a host; gateway identities must bind one. Role and host
bindings cannot change during credential rotation. Revocation advances the
generation, current credential checks retain a shared row lock through their
transaction, and no plaintext credential or digest enters the audit versions.
Service authentication grants no end-user or guest-connect authority.

Audi's real HTTPS client checks the configured role/host, rejects redirects and
implicit retries, bounds response size and request duration, and exposes fixed
error categories. Marshall's purpose-specific API requires actual TLS and closed
versioned JSON; it does not trust forwarded headers or browser credentials.
Property tests exercise rotation/revocation histories against PostgreSQL. Local
TLS tests exercise the actual client/API, certificate trust, revoked credentials,
wrong bindings, malformed/oversized responses and redirect refusal.

The Audi full gate passed with 16 checks (three properties) and forced Dialyzer
with zero errors or skips. Its updated Req dependency closure is fixed-hash
verified; the source-built `audi-release` check passed again for
`/nix/store/bmsvr142zfm2n9rhf3c34h5nn4z9lfss-kittens-audi-0.1.0`.
Marshall's full gate passed 374 checks (36 properties), six browser-state checks
and forced Dialyzer, with its existing single upstream exclusion and no unused
exclusions. The final six-test TLS transport rerun also passed, including trusted
certificate hostname rejection and the transport-failure diagnostic canary.
The 48-record ADR checker and final whitespace check passed. These remain local
process/database/transport tests, not NixOS guest or fleet acceptance.

The [flow diagrams](../../services/audi.md) explain the accepted DNS placement and nested
SSH path. They do not establish working SSH ingress. Remaining high-priority
work includes placement publication, user/SSH authorization and expiring stream
authority, a fenced local connector, the SSH/HTTP data paths, and NixOS deployment
and guest-level acceptance. ADR-0047 remains partial; this slice changes no guest
isolation rule and does not supersede ADR-0007.

## Stream lifetime slice

The local lease interpreter caps grants at five seconds from monotonic request
start, rejects future/expired grants, ignores reordered renewals and refuses
binding changes or resurrection. The temporary stream guard kills its dedicated
resource owner on expiry or revocation. An independent monitoring process also
enforces the deadline if the guard is suspended or killed; it exits when either
monitored process ends. Renewal I/O must run outside the guard. Callers must own
all stream resources in the guarded process and must not forward before admission.

Local TCP tests verify socket closure even when the owner traps exits, and check
cleanup after owner death. The full Audi gate passed 25 checks (five properties),
including forced Dialyzer with zero errors or exclusions. The final ten-check
targeted rerun (two properties) passed, including the additional successful
renewal/obsolete-timer regression. ADR structure/link and whitespace checks also
passed. No listener currently
uses this guard, and no Marshall session renewal or guest connector is implemented
by this slice. The five-second end-to-end authorization requirement remains open.

## SSH transport slice

Audi now has its own OTP SSH listener and custom stream channel. The public-key
callback only records a candidate; successful signature authentication registers
proof in the connection-owned registry. The command grammar accepts one stable
VM label and no port/address arguments. Grant validation pins this host, SSH port
22, VM, placement, epoch and session before connector creation. There is one
channel per connection and a bounded setup timeout. General forwarding in both
directions, shells, PTYs and subsystems are denied.

The channel owns its connector socket. It returns SSH receive credit after a
successful bounded local send and reads the connector with active-once. Renewal
runs in a linked worker outside the guarded I/O process; stalled renewal expires
the stream and closes both the connector and SSH channel. Peer payloads and OTP
reports are sanitized before logger handlers. A reviewed stream-open event is
reconstructed from fixed text and validated UUID metadata.

Seven transport checks use actual OTP/OpenSSH clients, strict fixture host-key
checking, and an explicit loopback connector fixture. They exercise byte transfer,
renewal, revoked/stalled authority, wrong-host grants, unsigned probes, disallowed
commands and both forwarding directions. The Nix source release payload check
passed for `/nix/store/0dngc04rnfcaakcpk253hxj4a368fxx1-kittens-audi-0.1.0`,
including SSH and lease modules. The final full gate passed 37 checks (six
properties), including privacy canaries, and forced Dialyzer with zero errors
or exclusions.

The default backend denies all access. The production authority/connector backend,
inner guest authentication test, relocation host-key lookup, slow-peer load tests,
NixOS service deployment and nested Firecracker acceptance remain open. Application
startup enables only the proof registry, not an SSH listener. No guest isolation
policy changes or ADR-0007 supersession occur in this slice; ADR-0047 stays partial.

## Durable SSH authority slice

Marshall now owns separate Audi sessions through Ash/PostgreSQL. Each binds the
gateway generation, original key registration, VM, host, placement, execution
epoch and lifecycle generation. Admission/renewal require current Cedar write
membership, running execution evidence, fresh connected-host state and relocation
readiness. Endpoint visibility never grants SSH. Lock order is service, key,
host, VM, session; a per-service admission lock serializes the 128-session limit.
Renewal performs no network I/O inside the transaction.

Sessions expire after five seconds, cannot renew after expiry or closure, and
cannot survive replacement of their registered key identity or gateway generation.
Only purpose-bound token hashes persist. AshPaperTrail retains admission/closure
events, excluding tokens and heartbeat writes. Cleanup is a bounded scheduled
AshOban action. Audit versions deliberately have no source foreign key so session
cleanup retains audit evidence. The generated migration creates only session and
version tables, with generation constraints and a composite placement/VM/host FK.

The first 14 ingress checks passed, including generated sharing histories and
real PostgreSQL key/gateway/expiry/retention cases. The final 11 session checks
(one property) also passed, including existing-session downgrade, stale-host
rejection, the live-session cap, expired slot reuse and durable continuation
across a 501-row cleanup fixture. Admission contention and end-to-end revocation
still require wider acceptance evidence. The full Marshall gate passed 395 checks
(37 properties), six browser-state checks and forced Dialyzer with its existing
single upstream exclusion and no unused exclusions. The 49-record ADR validator
also passed. The service API/client/backend are not wired to these new
actions yet. ADR-0047 remains partial; existing sharing roles retain ADR-0018's
semantics, and no guest network policy changes.

The shared gate encountered a syntax error in concurrently edited Lilly transfer
history code. Parenthesizing its case expression and formatting that file made
it compile without changing claim selection or transfer semantics. Lilly's full
gate passed 213 checks (29 properties) and forced Dialyzer with zero errors or
exclusions; this incidental repair has no architecture impact.

## SSH authority transport slice

The closed, versioned Audi HTTPS API now exposes SSH admission, renewal and
closure through the existing Ash actions. The client validates the complete
grant binding, including lifecycle generation, and rejects unknown fields,
changed bindings, redirects and malformed tickets. Credentials and tickets stay
inside the bounded private transport; peer values cannot select actions or
connector modules. The explicit control backend connects SSH authorization and
renewal to this client. Missing local connector configuration denies connection.

Fifteen targeted API/transport checks passed, including a live OTP SSH connection
through Audi's control backend, actual Marshall TLS and Ash/PostgreSQL authority.
Revoking the registered key closes the loopback connector and SSH channel.
This checks real authority wiring, not the unimplemented guest connector. Existing
request-start lease bounds still apply; delayed renewal cannot extend authority
past its local deadline. Normal disconnects leave database leases to expire;
the separate explicit close API is also covered.

Audi's full gate passed 37 checks (six properties), with zero Dialyzer errors or
exclusions. Marshall's full gate passed 402 checks (37 properties), six browser
checks and forced Dialyzer with its existing single exclusion and no unused
exclusions. The source-built `audi-release` Nix check passed. Final contract review
found no violations in the API/client/backend binding and credential boundaries.
ADR-0047 remains partial. No guest network rule changes or ADR-0007 supersession
occur here. The restricted Lilly connector, inner guest SSH acceptance, host-key
publication/lookup and deployed NixOS service remain required before production
guest access can be claimed.

## Local connector transport slice

Audi and Lilly now communicate through a versioned Unix-socket handshake and
then an opaque byte stream. The pure shared decoder accepts only a complete
SSH binding, requires port 22 and a label matching the VM UUID, and rejects
unknown fields and out-of-range execution integers. Each endpoint verifies the
connected Linux peer UID; Audi checks Lilly before sending its binding and Lilly
checks Audi before reading one. Lilly also checks this host, refuses existing
filesystem entries and requires owned directories before binding/chmod.

The server bounds admission to 128 workers, handshake bodies to 2048 bytes,
setup to two seconds and sends to one second. Active-once receive flow control
bounds queued input. An execution guardian's death closes both stream ends.
The explicit backend must supply the current durable execution fence and its
guardian; a missing backend denies. No listener starts by default, and no guest
network policy changes. Network namespace socket creation and actor/lifecycle
fencing remain outstanding; they must precede guest access, with the ADR-0007
replacement required by ADR-0047.

Independent Unix-socket client/server tests cover peer identity, closed schemas,
raw stream transfer, guardian death, excess clients, hung setup, and protected
filesystem entries. The shared decoder adds arbitrary-byte and large-integer
round-trip properties. The existing live SSH/HTTPS revocation integration now
traverses Audi's Unix client and Lilly's server, while retaining an explicit
loopback guest backend. These fixtures do not prove guest-network isolation.

Protocol's full gate passed 78 checks (30 properties), Audi's passed 40 checks
(six properties), and Lilly's final gate passed 224 checks (30 properties), all
with zero Dialyzer errors or exclusions. The Nix source release check passed for
`/nix/store/sywdn83yyx2i847lkmrp6g8xn6p70l5d-kittens-audi-0.1.0`.

Marshall's final isolated test run passed 419 checks (40 properties) with
warnings-as-errors, including the SSH/HTTPS/Unix handoff and key-revocation case.
Earlier runs encountered shared database rows, concurrent build changes and
distributed-node name collisions. Verification used a separate test database,
copied build directory with repaired dependency links, and a dedicated EPMD port.
The 49-record ADR structure/link check and whitespace check also passed.
Marshall's forced Dialyzer check passed after rebuilding the relocated PLT,
with its existing single upstream exclusion and no unused exclusions. Final
review found no contract violations in the handshake, UID checks, bounded relay
or guardian cleanup. Execution fencing remains an explicit backend obligation,
not a capability established by these transport tests. ADR-0047 stays partial.

## Local execution and namespace socket slice

ADR-0052 supersedes ADR-0007's ingress prohibition, retaining its address pools,
public egress, protected-address denial, anti-spoofing and direct guest isolation.
The exception is disabled by default and permits only privileged-marked local SSH
port 22 traffic on guest interfaces and established replies. Forwarding and
unmarked output remain denied. No public route or DNAT is introduced.

Lilly's backend now resolves a connected runtime's exact durable placement and
requires a running observation from the current actor incarnation, at most two
seconds old. Restored journals cannot grant ingress before physical reconciliation.
The stream guardian repeats resolution and actor checks, pins the executor and
command, monitors actor/owner death and uses an independent 1500ms timer armed
before each probe. A suspended guardian cannot extend its deadline; expired
authority cannot renew. Backend sockets derive their namespace, TAP and IPv4
address from trusted network configuration and validated placement/profile/slot.
The kernel socket is bound to that TAP with no fallback to the host namespace.

The unit suite includes actual Unix/TCP closure after durable command supersession,
guardian suspension, actor timeout, owner death, journal restart and observation
expiry. The final Lilly gate passed 234 checks (30 properties), with zero Dialyzer
errors or exclusions. The 50-record ADR validator and whitespace checks passed.

The first Nix attempt exposed untracked concurrent relocation dependencies omitted
by the Git flake source; their existing files were marked intent-to-add without
editing them. The machine fixture then needed an absolute Python executable for
its transient systemd service. With that fixed, the source-built Lilly package
passed real namespace/nftables tests: marked SSH sockets worked for two veth guest
fixtures, while disabled/unmarked/wrong-port connections, guest-to-host, lateral
guest traffic and unsolicited host forwarding failed. The final Nix rerun also
passed explicit unprivileged mark denial. These are kernel-network tests, not Firecracker guest
or fully deployed Audi acceptance.

Remaining requirements include runtime/NixOS listener wiring, socket lifecycle
recovery, actual nested guest SSH with independent inner host verification,
host-key publication/discovery, HTTP/HTTPS service policy and fleet-scale cost
measurement. The new actor and runtime APIs are internal to trusted Lilly; only
the existing UID-checked Unix transport may expose them to Audi. ADR-0047 and
ADR-0052 remain partial.

Final review found no contract violations in the current execution, watchdog,
derived-target or optional-rule paths. The accepted network exception is now
implemented and kernel-tested for SSH; the broader ingress milestone is not
complete. Existing public-egress and anti-spoofing programs were retained, and the
root/forwarding programs are unchanged by enabling this option.

## Gateway startup and service slice

This change implements ADR-0047's existing independent gateway deployment
boundary; it introduces no replacement decision. Audi's closed, bounded runtime
configuration requires an explicit gateway role, host UUID, verified HTTPS
Marshall origin, private credential, private Ed25519 host key, local connector
path and expected peer UID. Unknown fields, inline credentials, unsafe file
custody, invalid listener bounds and DNS-role configuration fail with a fixed
error. Client credentials remain excluded from inspection. Application startup
installs the structured OTP/privacy filters and starts the real control backend;
rest-for-one supervision makes the SSH listener depend on the proof registry.

The exported Audi NixOS module uses its own unprivileged account, systemd
credentials, resource bounds, persistent private host identity and restricted
capabilities. Port assertions reject collision with administrative OpenSSH and
Porsche. Port 22 requires administrative SSH on 2222. The module does not silently
enable Lilly's network exception or advertise an unconfigured connector.

Validation passed: Audi's complete precommit gate (46 checks, including seven
properties; zero Dialyzer errors/exclusions), the Nix configuration check, and
the actual source-release NixOS service test. The machine verified startup,
credential/private-key permissions, separate administrative host identity,
persistent gateway identity after restart, denial without authority, no fixture
credential in the journal and invalid-credential startup failure with admin SSH
still available. The Git flake initially omitted concurrent untracked Porsche
module dependencies; those existing files were marked intent-to-add without
content changes before the successful build.

Final contract review found the selected backend and connector remain exclusively
operator-controlled, startup errors do not disclose configuration, and tests do
not claim guest forwarding. Remaining work includes Lilly connector startup and
stale-socket recovery, outer host-key publication/discovery, full Firecracker SSH
acceptance, DNS-role startup/publication, web ingress, service observability and
fleet secret/update integration. ADR-0047 remains partial.

## Lilly connector lifecycle and deployment slice

ADR-0047/0050 deployment now starts Lilly's restricted connector after Runtime
under rest-for-one supervision. Closed runtime configuration requires the network
exception and the explicit socket/peer settings together; mismatches fail startup.
The configured backend is fixed to the current local execution guardian. Nix
requires a matching local Audi host identity and root connector UID, resolves
Audi's actual account UID while generating private runtime configuration, and
creates a root-owned setgid Audi-group socket directory without group write.

Socket custody now holds a persistent exclusive OS lock and records the exact
socket path privately and durably before binding. Recovery removes only an
already-claimed service-owned Unix socket. Unknown sockets, regular files and
symlinks remain untouched, and a competing live owner cannot replace the listener.
The lock inode is retained; bounded acquisition retries accommodate the previous
helper exiting after a crash. Lock loss stops admission. This changes the earlier
blanket refusal of existing paths into explicit claimed-resource recovery,
consistent with the existing exclusive-ownership decisions.

The Lilly precommit gate passed 237 checks (30 properties), with zero Dialyzer
errors/exclusions. The initial run caught an incorrect child-spec typespec, which
was corrected before the full successful gate. The source-release NixOS service
test passed with both Audi and Lilly: the connector had root:audi mode 0660,
accepted the Audi account's local connection, rejected the invalid fixture request,
and recovered after SIGKILL of Lilly's main process with a newly bound socket.
The separate gateway machine retained all credential/host-key/startup checks.
Nix configuration checks passed matching-host acceptance and mismatched-host
rejection. Initial Nix evaluation caught duplicate assertion/tmpfiles attributes;
these were merged into the existing module declarations before successful builds.

Final review retains the distinction between running connector services and
successful guest access. The machine has no Marshall authority or Firecracker
guest, so it proves lifecycle/custody, not user authorization or inner SSH login.
Full guest SSH, host-key publication/discovery, DNS replication/deployment, web
services, fleet secret/update integration and scale acceptance remain incomplete.
The accepted decisions remain partial; no replacement ADR is required.

Additional regression evidence: Marshall's 10 ingress transport tests passed with the changed real Lilly socket
server in the isolated test database/build. This includes the existing live
SSH/HTTPS/Unix authority path. The 50-record ADR checker and final whitespace
check passed. Neither result changes the outstanding Firecracker acceptance gap.
The broader Nix module-configuration process subsequently completed successfully.

## Gateway host-key registration slice

This implements the registration prerequisite for ADR-0047's selected OpenSSH
KnownHostsCommand flow, without substituting current execution state for the
still-missing published-route lookup. The Ash service resource stores one
canonical Ed25519 public key in its current credential generation. Publication
exclusively locks the authenticated gateway row, permits idempotent repeats and
rejects replacement keys. Credential rotation or service revocation atomically
clears the key. The new database constraint prohibits keys on DNS or disabled
identities; the generated migration and resource snapshot were reviewed. Public
key changes are audited while service credentials remain excluded.

Audi derives the public key from the actual private host key using OTP's
documented ssh_file APIs, ignoring the public sidecar. Its SSH key callback offers
only that Ed25519 host identity while retaining independent user-key validation.
A supervised publisher runs after listener startup, uses the existing bounded
verified HTTPS control client and retries after 30 seconds without accumulating
work. The closed acknowledgement must contain the exact configured host and
submitted key. Registration errors do not change keys or extend stream authority.
This generation-bound registration policy preserves the accepted trust boundary;
operators must rotate the service credential before replacing its private key.

Domain tests cover immutable/idempotent registration, role/actor rejection,
rotation/revocation and audit behavior. A property checks arbitrary replacement
inputs against a fixed registered identity. TLS tests cover the actual control
route and forged acknowledgement bindings; the existing live SSH/TLS/Unix test
also starts the real publisher and checks the stored derived key. Sidecar
replacement and invalid private-key parsing are tested independently.

Remaining work includes current published-route lookup, generated OpenSSH
configuration and relocation/lookup-failure acceptance. Registered keys alone do
not establish route readiness, authorize a user or complete the SSH milestone.

Validation: Audi's complete gate passed 47 checks (seven properties) and zero
Dialyzer errors/exclusions. The source-release payload check and the two-node
Audi/Lilly NixOS service check passed with the publisher enabled, including
startup during control-plane unavailability and connector SIGKILL recovery.
The initial Nix build encountered in-progress relocation references; after the
missing source files appeared, their existing contents were marked intent-to-add
for the Git flake and the build passed without editing that unrelated code.
Marshall's first broad run observed two readiness failures while a new concurrent
relocation migration appeared after database setup. The rerun against the updated
schema passed all 437 checks (42 properties), including those readiness tests and
the real publisher/SSH/TLS/Unix regression. The 50-record ADR structure/link check
and whitespace checks passed.
Marshall's forced Dialyzer check subsequently passed, with its one existing
upstream exclusion and no unnecessary exclusions; the complete final gate exited
successfully. Final review found no new contract or authorization-boundary
violations. ADR-0047 remains partial and its public host-key lookup requirement
is explicitly unimplemented.

## Generated OpenSSH client profile slice

Current-route key lookup depends on durable publication gated by certificate
readiness; neither is implemented yet. This change implements the independent
client side of ADR-0047's selected flow without exposing a lookup that would
mistake registered keys for published routes. The renderer validates an exact
stable label, canonical DNS zone, HTTPS origin and gateway port. It builds an
outer connection with strict Ed25519 checking, a bounded HTTP-200-only HTTPS
lookup, disabled curl configuration/proxy routing, no persistent host-key files,
no DNS key verification and no connection multiplexing. The inner guest keeps
normal known-hosts verification. Configuration contains no service credential.

Two SSH expansion passes require escaping fixed percent literals twice, and
KnownHostsCommand also expands braced environment expressions. The renderer
avoids those expressions and uses an absolute /bin/sh command with standard sed;
it interpolates no client-selected SSH expansion tokens. Curl versions older
than 8.4 are rejected because they do not enforce max-filesize for unknown-length
responses. Curl errors are checked before emitting any captured body, and only
HTTP 200 can supply host-key lines. Redirect/error bodies cannot become keys.

The Nix fixture deliberately uses stock outer/inner sshd and a controlled HTTPS
endpoint. It tests the generated configuration with real OpenSSH and curl; it
does not establish Marshall route publication, Audi gateway authorization or
Firecracker relocation. Early runs caught the missing fixture privilege-separation
account, OpenSSH's braced-variable expansion, and its requirement for an absolute
KnownHostsCommand executable. These were fixed before the successful nested flow.
A cached outer key cannot override a changed lookup; updating the actual gateway
key then restores access. Redirect/error responses, untrusted TLS, lookup outage,
old curl and an independently unknown guest key deny setup.

Final architectural scope is unchanged: the accepted client approach now has an
implementation and protocol-level evidence, while the public lookup endpoint,
certificate-ready route publication and authenticated profile delivery remain
outstanding. ADR-0047 is still partial. No new authority or network exception is
introduced by rendering a client configuration.

The final NixOS client-flow check also passed an unknown-length oversized response
containing a valid key followed by a large comment: curl returned code 63 and
no key was accepted. The first assertion needed stderr capture, not a product
change. Arbitrary-origin property testing found a URI parser exception on invalid
UTF-8; validation now rejects invalid encoding before parsing and converts parser
exceptions into the fixed configuration error. The focused renderer/property
suite passed after that fix. A source-only review using security-audit guidance
found no additional reachable shell-injection or failed-lookup acceptance path;
this was guidance-mode review, not a full audit or broader deployment assurance.

The final Marshall gate completed with 440 checks (43 properties, 397 tests)
and forced Dialyzer passing with its existing upstream exclusion. Its process
handle had been retired when rechecked; the retained log records successful
completion of both phases.

## Alternate-port DNS publication binding

ADR-0047 requires alternate web names without changing the stable VM identity.
The DNS authority now maps exactly one canonical p3000..p9999 prefix beneath a
stable VM label to that VM's base publication. A single directory call supplies
the revision, freshness decision and addresses; answers retain the queried owner
name and 20-second TTL. Other prefixes and deeper names receive no inherited
entry. Removing the base publication removes its derived names atomically.
This preserves Marshall's domain authority and does not grant application access.

Independent OTP DNS clients exercise IPv4/IPv6 over both UDP and TCP. A generated
port property checks the allowed interval; explicit boundary and malformed-name
cases supplement it. Tests also cover removal, missing record types and replica
loss. These remain injected local snapshots, not authenticated replication or
certificate-ready route publication. Those requirements and HTTP forwarding are
still outstanding; ADR-0047 remains partial.

Validation: Audi's full precommit gate exited successfully with 49 checks
(8 properties, 41 tests), zero Dialyzer errors or exclusions, and passing
toolchain, contract, compiler and formatting checks. The standalone ADR checker
passed all 50 decisions after the evidence update. Final contract review found
no additional authority or wildcard behavior introduced by this change.

## DNS role startup and deployment

The accepted independent DNS role now has a closed runtime schema and a NixOS
`services.audiDns` module. It runs the same Audi release as a distinct unprivileged
service, opens UDP/TCP together when requested, and holds no gateway token, SSH
host key or Lilly connector privilege. The configuration requires two to eight
distinct nameserver names; this validates configuration shape, not independent
physical deployment. Hostnames are bounded canonical ASCII DNS names. Invalid
configuration retains fixed redacted startup errors.

The directory starts before the listener under rest-for-one supervision. Its
initial state is empty, so in-zone requests receive SERVFAIL; static configuration
cannot inject route entries. Authenticated replication remains unimplemented and
is required before this role provides useful public routing. This is deployment
wiring, not a claim of a functioning publication control plane. ADR-0047 remains
partial. No new durable authority or isolation exception is introduced.

Audi's full gate passed 50 checks (8 properties, 42 tests), including role schema
rejection and real listener startup from parsed configuration, with zero forced
Dialyzer errors or exclusions. Existing gateway configuration checks still pass.

The new `audi-dns` NixOS check passed against the packaged source release:
UDP/TCP port 53, in-zone SERVFAIL, outside-zone REFUSED, dedicated service UID,
absence of a gateway host key, and restart were observed in a booted VM. It uses
no publication fixture and makes no replication or multi-host availability claim.

## Operator-owned gateway address identity

Inspection for durable route publication found no gateway address source in the
host or service resources. The existing Ash service enrollment action now accepts
at most eight canonical IPv4/IPv6 literals for gateways; DNS identities retain an
empty list. This configuration is operator authority, not an address supplied by
a gateway or guest. Hostnames, scoped IPv6, duplicate entries and noncanonical
spellings are rejected. The list is sorted before comparison and audited with the
service mutation. Address reachability is an operator deployment obligation, not
something literal validation establishes.

Changing addresses holds the existing service row lock, advances its generation
and clears its registered SSH key. Existing generation-bound SSH sessions then
fail renewal. Reordering the same set is idempotent; changing addresses cannot
reenable a revoked credential. The generated migration adds only the address
array and a database constraint bounding its size and restricting nonempty
lists to gateways. The existing service identity wire response is unchanged.

This is a prerequisite to route publication, not publication itself. No address
is yet emitted as a DNS route or public host-key binding. Certificate readiness,
execution readiness, publication revisions and authenticated replicas remain
outstanding under ADR-0047. Tests exercise actual Ash/PostgreSQL transitions and
audit entries, with a property model for address histories and generations.

Validation completed: Marshall's full precommit gate exited zero with 443 checks
(44 properties, 399 tests) and forced Dialyzer passing with the existing upstream
exclusion and no unused exclusions. The initial attempts stopped during database
setup because the development PostgreSQL service was absent, then socket-only;
after restoring loopback test access and the expected local role, the complete
gate passed. ADR validation passed all 50 records. This evidence covers domain
enrollment and generation semantics, not route publication or production DNS.

## Per-VM TLS material validation

Route publication still lacks an actual certificate-readiness producer. The new
Audi TLS material validator supplies a local cryptographic validation boundary:
operator-provided trust roots, bounded leaf-first chains, current PKIX validity,
exact stable-name and per-VM wildcard SANs, server authentication and digital
signature usage, and a matching P-256 ECDSA private key. It uses OTP's documented
public-key APIs and records from the pinned runtime. The return value contains
TLS material with redacted inspection, a SHA-256 leaf fingerprint and the minimum
expiry across the path and anchor. Errors are fixed and carry no PEM/DER data.

Tests create certificates with OpenSSL and establish a real verified OTP TLS 1.3
connection using the accepted material. Negative cases cover wrong roots/keys,
wrong or missing names, fleet wildcards, client-only usage, expired/future signed
certificates, missing/reordered/duplicate intermediate chains and bounded input.
A property checks arbitrary certificate, key and root bytes cannot escape as a
parser exception. An initial test used a keyword list where OTP requires a map
for certs_keys; the fixture was corrected before successful handshake evidence.

Architecture impact stays within ADR-0047's per-VM TLS requirement. This module
is not yet integrated into a file custodian, ACME client, production HTTPS
listener, renewal loop or route publisher. It performs no CRL/OCSP checks and
makes no installation, revocation or public readiness claim. Those remain
explicit obligations; certificate metadata alone cannot authorize publication.

Validation: Audi's full precommit gate exited zero with 55 checks (9 properties,
46 tests), zero Dialyzer errors/exclusions, and passing compiler, formatting,
contract and runtime checks. The ADR checker passed all 50 records after the
evidence update. The source review found no contract violation in this local
validation scope; packaged HTTPS/ACME/Firecracker acceptance is still absent.

## Atomic certificate selection

The local TLS store validates material against its operator trust bundle before
atomic replacement. It supplies OTP SNI options for the installed primary name
and p3000..p9999 alternate names only. Unknown names, stopped stores and expired
material return the documented `unrecognized` result, not a default certificate.
This is certificate selection only; it neither grants HTTP access nor asserts
current physical VM placement.

Per-name monotonic revisions reject old and conflicting updates. Removal retains
a tombstone so an older installation cannot resurrect a name. Tombstones count
against the 10,000-entry maximum; certificate/key DER bytes also have a bounded
budget (256 MiB maximum). These are bounds, not measured fleet capacity. Failed
validation or capacity checks preserve the previous entry. Process status is
redacted. Reconciliation/compaction and persisted restoration still need the
future authoritative publication producer; this local store is not durable state.

Real TLS tests select primary and alternate names, reject unknown and removed
names, and preserve a valid certificate after a failed replacement. A generated
history checks reordering and conflicts against a separate revision/presence
model. Tests cover tombstone capacity, byte capacity, expiry selection and status
redaction. The raw OTP client initially rejected alternate wildcard certificates
because it lacked HTTPS hostname matching; adding OTP's documented HTTPS match
function corrected the fixture while retaining certificate verification.

ADR-0047 remains partial. This introduces no new application authority, and the
store is not yet a configured production listener, ACME renewal path or route
publication acknowledgement.

Final validation: Audi precommit exited zero with 58 checks (10 properties,
48 tests), zero forced Dialyzer errors/exclusions, and passing runtime, compiler,
formatting, contract and ADR gates. A status assertion caught an invalid OTP
format_status callback shape; preserving the incoming map keys while redacting
state/message/reason/log fixed it before the final pass. Standalone ADR validation
also passed all 50 records. No production HTTPS or route-readiness claim follows
from these local selection tests.

## HTTP/HTTPS protocol entry point

Audi now uses the repository's existing Bandit 1.12.5 / Thousand Island 1.5.0
stack rather than introducing a second HTTP parser. The five added locked Hex
dependencies match Marshall's lock entries; Audi's fixed-output dependency hash
was regenerated and the source release rebuilt offline from the reviewed lock.
This dependency choice stays within ADR-0047; Audi still owns its DNS and SSH
roles and remains an independent release.

The listener limits connections to 128 across four acceptors, header count to
64, each header and request line to 8192 bytes, reads to five seconds and sends
to one second. Protocol-input diagnostics are disabled. Source inspection found
Thousand Island's TLS transport calls OTP handshake with an infinite deadline;
a thin adapter changes handshake/upgrade to five seconds while delegating other
transport callbacks to the pinned implementation. A real silent TCP client test
verifies closure on the TLS port. TLS session tickets and session reuse are
disabled so a future handshake cannot bypass current certificate selection.

HTTP redirects require a currently installed canonical hostname and construct
the HTTPS destination from that name, preserving path/query. Forwarded headers
and cookies have no authority. HTTPS additionally compares Host with the actual
connection SNI, rejecting domain fronting. Successful origin checks currently
return fixed 503 responses: no guest connection or access decision is attempted.
Tests use real TCP/TLS sockets, including known/unknown names, alternate-port
bounds, forwarded-host injection and Host/SNI mismatch.

This is a protocol entry point, not completed proxying. It is not yet connected
to gateway startup configuration, durable routes, browser authentication or the
Lilly HTTP connector. HTTP/2 and WebSocket upgrades are disabled until the relay
is implemented; required WebSocket/streaming acceptance remains outstanding.
ADR-0047 stays partial and no new guest network exception is introduced.

Validation completed: Audi precommit exited zero with 59 checks (10 properties,
49 tests) and zero forced Dialyzer errors/exclusions. The Nix `audi-release`
check rebuilt and verified the source release after updating the dependency hash.
The ADR checker passed 50 records. These are local protocol and package checks,
not production HTTP forwarding, browser authentication or Firecracker acceptance.

## Durable gateway readiness report

The new Ash Route resource stores one readiness report per VM, with service,
host, placement, execution epoch, VM generation, certificate fingerprint/expiry,
report expiry and a monotonic per-VM revision. Composite placement foreign keys
prevent mismatched VM/host references. The internal coordinator authenticates a
gateway credential and locks service, host, VM and route in that order. It checks
fresh host connectivity, enabled/nonretired state, exact running execution,
completed provision/start and relocation readiness, configured gateway addresses
and a registered SSH key. Any mismatch denies the report without changing the
existing row. Ordinary user actors cannot invoke the action.

Certificate metadata is explicitly an authenticated infrastructure attestation,
not independent cryptographic or listener-installation proof. There is no new
public control endpoint, gateway producer, current-route projection or DNS
consumer in this change. The future producer must validate/install the exact
certificate before reporting. Raw rows must never stand in for current published
routes; consumers still need service/execution/freshness revalidation.

Reports expire in at most five seconds and no later than the reported certificate
expiry. Binding/certificate changes audit atomically; unchanged freshness updates
advance the revision without creating heartbeat audit rows. Producer batching,
route retention, complete installation evidence and fleet capacity remain
outstanding. The migration was reviewed: it creates only the route and version
tables, identity index, foreign keys and validity constraints; generated drops
are confined to rollback. ADR-0047 remains partial.

Focused PostgreSQL tests passed five checks (one property, four tests), covering
binding, expiry, rotation, stale/stopped execution, actor denial, audit refresh
suppression and generated mismatched execution reports. The full Marshall gate
then exited zero with 449 checks (45 properties, 404 tests), forced Dialyzer
passing with its existing upstream exclusion and no unused exclusions, and
passing compiler, contracts, formatting and runtime checks. ADR validation
passed all 50 records. These checks do not establish certificate readiness or
publication.

## Current-route projection

The internal Ash current-route action now resolves a stable label to its report,
then takes service, host, VM and route locks in that order. Shared VM/route locks
allow concurrent reads while excluding lifecycle and report mutation. Report
admission retains its exclusive VM lock. Both paths use the same execution,
service-generation, host-freshness and completed-readiness checks. A binding
change between the initial candidate read and the locked row denies projection.

The projection returns the current service's addresses and SSH key, never a
caller-selected key or an old copied key. Report and certificate expiry are
checked against the database clock after locks; the returned remaining TTL is
positive and at most five seconds. Reads neither renew the report nor create
an audit version. Missing reports deny even when a gateway has a registered key.
Ordinary user actors cannot invoke this internal action. No user/session access
is granted by route metadata.

Focused PostgreSQL tests cover valid output, expiry, stale host reports, changed
execution, missing labels, actor rejection, and service rotation. Re-registering
a key in the new gateway generation cannot revive an old readiness report. The
shared execution checks retain the existing generated mismatch property.

ADR-0047 remains partial. There is still no public lookup endpoint, authenticated
DNS snapshot consumer or actual certificate-installation report producer. This
projection is a reusable validation boundary for those consumers, not evidence
that route publication is operational. No persistence migration is needed for
these action/coordinator changes.

Validation completed: Marshall's full precommit gate exited zero with 452 checks
(45 properties, 407 tests), forced Dialyzer passing with the existing upstream
exclusion and no unused exclusions, and passing runtime, formatting, compiler,
contract and ADR gates. The standalone ADR checker passed all 50 records. No
public-route or multi-host publication acceptance is claimed by this slice.

## Web-only sharing boundary

The existing one-current-role Ash grant model now admits a `web` role and the
sharing UI offers “Web apps only”. A separate Cedar web action includes owner,
manager, operator, viewer and web grants. Existing VM read/write/manage actions
retain their role matrix. This implements ADR-0047's authorized extension while
preserving the management/terminal rationale in ADR-0018 and the non-registration
decisions carried from ADR-0008 into ADR-0049.

Management VM queries exclude web-only grants before pagination; a large set of
web grants therefore cannot fill pages with unreadable candidates. Detail,
lifecycle and sharing actions still require their original Cedar actions.
Replacing a VM role with web-only access closes its terminal sessions (and fences
its writer) in the sharing transaction. Audi SSH admission and renewal still use
write permission, so web-only access cannot admit or sustain an SSH session.

The migration changes only the existing role check constraint. Audited archival,
immutable idempotency results, protected ownership and existing-account recipient
resolution remain unchanged. No public HTTP access is implied: browser SSO,
web-session renewal/revocation and actual web forwarding remain outstanding.

Focused verification passed 42 checks (4 properties, 38 tests). The Cedar role
matrix, persisted replacement histories and terminal-role histories now include
web-only grants. Explicit tests prove web authorization, exclusion from VM
management pages, revocation, denial of new/renewed SSH authority, and immediate
terminal archival and active-writer fencing on replacement with web-only access.
The full Marshall gate exited nonzero: 448 of 454 checks passed, including all
45 properties. Its six failures are in concurrent relocation/delete changes:
the tests expect deletion during relocation to be rejected while the lifecycle
implementation now accepts it. Forced Dialyzer passed with its existing upstream
exclusion and no unused exclusions; formatting, compiler, contracts and ADR checks
also passed. The focused run includes the subsequently added deterministic writer
fencing test. This is permission-model evidence, not browser or Firecracker
acceptance, and the full repository gate is not green.

## Public SSH host-key lookup

ADR-0047's public lookup is now implemented as a bounded text response on
`GET /api/audi/v1/known-hosts/<label>`. It calls the Ash current-route action on
every request, preserving the service/host/VM/report lock and freshness checks.
Only the canonical configured application hostname and registered public key
leave this boundary. No credentials are required to discover a public host key;
SSH admission still independently authorizes the user and target VM.

Actual HTTPS, canonical stable labels, GET and an empty query string are required.
`MARSHALL_INGRESS_ZONE` is validated at startup and response generation; missing
configuration denies publication. Forwarded headers cannot establish TLS or choose
the zone. Every response is `no-store`; failure returns no key or internal error.
This preserves the accepted architecture and introduces no persistence changes.
The producer for validated certificate-installation reports and authenticated
profile delivery remain missing. DNS snapshot publication, relocation acceptance
and the real Firecracker SSH path remain separate unfinished requirements.

Focused route and API verification passed 14 checks (1 property, 13 tests),
including current-route invalidation and the public HTTP boundary. The full
Marshall precommit gate exited nonzero with 467/468 checks passing (all 45
properties and 422/423 tests). Its only failing test is the concurrent relocation
exclusion test expecting delete rejection. Forced Dialyzer passed with the existing
upstream exclusion and no unused exclusions. Compiler, formatting, contract and
ADR checks passed, including a separate contract/ADR run after the final contract
clarification. Existing stock-OpenSSH Nix checks establish client mechanics only;
they do not establish this endpoint's production readiness.

## Authenticated OpenSSH configuration delivery

Historical evidence: the download and renderer were
[retired on 2026-09-25](2026-09-25-ssh-config-download-retirement.md).

The machine detail page now links to a profile attachment for users with write
permission when the application zone is configured. The controller independently
checks the current stored browser login and calls a new Ash endpoint read action
requiring Cedar write permission under the VM lock. UI visibility is not authority.
The generated profile uses only the operator's ingress zone and configured Marshall
endpoint URL, returns no credentials and prohibits browser/proxy caching. Its
request process is tagged before diagnostics because it verifies login material.

This implements ADR-0047's existing client-delivery decision without a schema
change. It preserves separate outer Audi and inner guest SSH verification and
requires Audi admission again when the downloaded profile is used. Downloading
while stopped is permitted; the artifact identifies the stable VM and cannot
bypass current-route readiness or access revocation. ACME, actual certificate
installation reporting and production route publication remain unfinished.

The initial focused run passed 18 checks (1 property, 17 tests), covering the
controller, endpoint model and machine pages. Explicit controller cases reject
anonymous/revoked logins, viewer/web-only grants and access revoked after an
operator grant. The full precommit run also includes a subsequently added rendered
machine-page download-link assertion. Its first run passed all 427 ordinary tests
but exposed duplicate-generation exhaustion in the existing address-history
property. The generator now deduplicates bounded lists without retry rejection;
the state-transition assertions are unchanged. All nine service checks (including
three properties) pass with the original failing seed, 733535. The complete
Marshall precommit rerun exited zero with 473 checks (45 properties, 428 tests),
passing forced Dialyzer with the existing upstream exclusion and no unused
exclusions, and passing runtime, compiler, formatting, contracts, browser-state
and ADR checks. The rendered download link is covered in that run. This is
browser/profile authorization evidence, not Firecracker deployment acceptance.

## DNS-01 challenge answers

Audi's own authoritative server now serves bounded DNS-01 TXT proof sets at the
exact `_acme-challenge.<stable-VM-label>.<zone>` owner. The local replica accepts
one to four distinct canonical SHA-256 base64url digests and a separate monotonic
expiry. A fresh snapshot cannot extend an expired proof's own deadline; malformed
challenge entries cannot replace the current snapshot. Responses cap TXT TTL at
five seconds and retain minimal ANY behavior without returning proof sets.

A challenge may exist before application addresses, which is necessary to obtain
a certificate before publishing a ready route. Its base VM name is consequently
an empty non-terminal (NODATA), while alternate application names remain absent.
Proofs never create A/AAAA answers or application access. This implements the
DNS-01 part of ADR-0047's accepted custom-DNS design; it does not create an ACME
account/order model, issuance scheduler, public update API or authenticated
replication transport. Those components remain unfinished.

Audi's final gate passed 62 checks (11 properties, 51 tests),
including independent OTP DNS client queries over real UDP and TCP, proof expiry,
negative answers, snapshot refresh without revival and digest canonicalization.
The final run includes minimal ANY and invalid-UTF8 rejection, with zero Dialyzer
errors and passing compiler, formatting, runtime, contract and ADR checks. The
packaged DNS NixOS regression exited zero: real port-53 UDP/TCP queries, initially
empty replica SERVFAIL, outside-zone REFUSED, separate service identity and restart
behavior passed. It does not inject challenge snapshots or prove issuance or
replication; those challenge-answer cases are covered by the local socket suite.

## ACME request cryptography

Audi now derives an ES256 account identity from a validated P-256 scalar, with
RFC 7638 canonical public-key thumbprints and redacted inspection. Its bounded
flattened JWS encoder includes the exact HTTPS resource URL, canonical replay
nonce, payload and exactly one account identity (`jwk` for creation or `kid` for
an existing account) in the protected header. It encodes ECDSA signatures as the
required fixed-width R||S bytes and distinguishes POST-as-GET's empty payload from
an empty JSON object. DNS-01 proofs bind the server token to the same account
thumbprint and are accepted by the DNS proof validator.

This is a cryptographic value/encoding boundary, not an ACME account domain or
issuance implementation. It adds no persisted domain model or dependency. Account
custody, nonce consumption, issuer URL trust, HTTPS exchanges, orders, scheduling,
challenge publication and CSR/finalization remain unfinished. The caller contract
explicitly reserves nonce ownership and issuer trust for the future transport.
No HTTP requests or certificate issuance are performed by this module.

The final Audi precommit gate exited zero with 66 checks (12 properties, 54 tests), including a
fixed P-256 base-point identity, actual signature verification, payload tampering,
new/existing account header differences, empty POST-as-GET, malformed request
rejection and generated DNS proofs. Dialyzer reported zero errors with no
exclusions. Runtime, compiler, formatting, contract and ADR checks passed;
contract discovery was also checked for both new modules. No issuer interaction,
certificate issuance or new deployment acceptance is claimed.

## ACME issuer transport

The issuer client now fetches the three required directory endpoints and executes
nonce HEAD / signed POST exchanges over verified HTTPS. All endpoint, account and
returned Location URLs must match the configured issuer origin. Requests disable
redirects, automatic retries and decompression. Each exchange has a three-second
request deadline, with smaller connection/receive limits, and at most 512 KiB of
response body; directory JSON additionally has a 64 KiB acceptance bound.

Each signed attempt obtains a nonce by HEAD and makes exactly one POST, without a
shared local nonce cache. The transport does not replay badNonce, redirects or
rate-limited requests. It returns only status, a parsed Retry-After delay and fixed
problem classification on HTTP errors; arbitrary issuer details are discarded.
The future order coordinator must implement bounded retry/backoff, durable account
custody, quota scheduling and certificate lifecycle state. This preserves
ADR-0047's issuer boundary, adds no dependency or persisted model, and is not
production certificate issuance.

A local HTTPS issuer fixture verifies actual JWS signatures and consumes nonces.
Tests exercise concurrent requests, CA and hostname checks, issuer-origin checks,
redirect/rate-limit non-replay, invalid nonces, oversized bodies and unsafe
Location responses. The final Audi precommit gate exited zero with 69 checks
(12 properties, 57 tests), including explicit badNonce classification. Dialyzer
reported zero errors with no exclusions. Runtime, compiler, formatting, contract
and ADR checks passed, and contract discovery was checked for the new transport.
The fixture is a protocol peer, not a real issuing CA; no certificate issuance or
deployment acceptance is claimed.

## Per-VM certificate requests

Audi now generates a fresh P-256 key and PKCS#10 request for exactly the canonical
stable VM hostname and its per-VM wildcard. The only requested extension is the
SAN set; the subject is empty and SAN is critical. Name lengths include room for
the wildcard prefix. Wildcard inputs, fleet names, noncanonical names and malformed
bytes are rejected before generating material. Inspection exposes only hostname,
and failures return a fixed reason without private key details.

This implements ADR-0047's existing per-VM certificate boundary using OTP's ASN.1
and signing primitives, with no new dependency or persisted domain model. Account
keys remain separate from the fresh TLS keys. The generated private key still
needs durable custody before ACME finalization and listener installation; request
generation alone is not operational certificate readiness.

OpenSSL independently verifies the DER request and confirms its P-256 algorithm
and exact SAN pair. A generated-hostname property checks the decoded extension
set, actual request signature and that the exported PEM key matches its public
key. The full Audi precommit gate exited zero with 72 checks (13 properties,
59 tests), zero Dialyzer errors and no exclusions. Runtime, compiler, formatting,
contracts and ADR checks passed; contract discovery and the standalone ADR check
also passed after the evidence update. No issuance or deployment claim is made.

## Local ACME issuance sequence

Audi's issuer operations now register an account with explicit terms acceptance,
create exact base/wildcard orders, discover authorizations without assuming URL
order, acknowledge DNS proofs, poll, finalize and download validated material.
Order refreshes preserve authorization identities and the finalize URL. Resource
validation rejects changed names, wildcard flags, duplicate authorizations or
DNS challenges, and URLs outside the configured issuer origin. Download requires
a valid order and the matching request, then independently validates the returned
certificate chain and key. Operations do not install certificates or publish
readiness. This extends ADR-0047 without changing its accepted boundaries.

The local HTTPS test peer verifies JWS signatures and nonces, queries Audi's real
UDP DNS listener for both TXT proofs, and uses OpenSSL to sign the generated CSR.
The test first proves acknowledgement fails before proof publication, then
completes issuance and rejects a different private key or trust root. Resource
properties exercise identity substitution. Malformed account and directory JSON
return fixed errors without raw decoder objects or response bodies; review found
and fixed the directory decoder leak while tracing registration's callee contract.

These protocol representations are transient values, not durable domain models.
The existing Ash control-plane ownership remains unchanged. Durable account and
order resources, key custody, renewal/retry scheduling, replicated challenge
publication and installed certificate readiness are still missing. The fixture
does not establish public-CA interoperability, NixOS issuance, recovery after
process loss or multi-host acceptance.

The final Audi precommit gate exited zero with 76 checks (15 properties,
61 tests), zero Dialyzer errors and no exclusions. Runtime, compiler, formatting,
contract and ADR checks passed. Contract discovery covered issuer operations,
resource validation and transport; the standalone ADR checker also passed.
No Nix module or deployment behavior changed in this sequence.

## Recovery of existing cryptographic identities

The issuer now supports existing-only account lookup with the saved key. A
missing account produces an error without registration or terms acceptance;
only a valid account with HTTP 200 and a trusted Location is recovered. The
real HTTPS fixture verifies the exact recovery payload, absence of account
creation on a missing lookup, and continuation with the recovered identity.

Per-VM request restoration preserves the exact CSR and PEM bytes. Before
returning them, it checks size bounds, P-256 private/public correspondence,
canonical DER, exact expected request contents and the CSR signature. It never
generates a new key on failure. OTP normalizes attribute record names during
decoding, so content comparison uses canonical DER rather than record tuple tags.
Tests reject substituted keys or hostnames, duplicate PEM entries, trailing DER,
malformed encodings and oversized input. A property verifies round trips and
signature corruption rejection across generated VM hostnames.

This preserves ADR-0047's per-VM identity and issuer trust boundaries. It adds
no storage policy or durable domain model. Private custody, Ash issuance state,
recovery scheduling and installed listener readiness remain explicitly missing.

The final Audi precommit gate passed 78 checks (16 properties, 62 tests), with
zero Dialyzer errors and no exclusions. Runtime, compilation, formatting,
contracts and ADR checks passed. Contract discovery covered both changed
production modules; the standalone ADR checker and scoped diff whitespace check
also passed. This is application-level recovery validation, not a disk-recovery
or NixOS restart test.

## Immutable local issuance key custody

Audi now saves account scalars bound to the exact configured issuer directory URL
and per-issuance CSR/key records bound to a UUID and hostname. Reads reconstruct
the account identity or validate the saved request cryptographically before
returning it. Records are bounded JSON rather than arbitrary Erlang terms; decode
errors cannot escape the fixed-error boundary. This is a filesystem secret
primitive, not a replacement for Marshall's Ash issuance coordination.

Creation requires an existing owner-held 0700 directory through trusted
nonsymlink ancestors. The destination is exclusively created and chmodded to
0600 before secret bytes are written. Success follows file-data and directory
fsync. There is no overwrite or automatic key regeneration: an uncertain failed
write retains its destination for recovery inspection. Reads require a single-link
0600 regular file owned by the service and bounded bytes. This follows the local
trusted-filesystem assumption already used for operator secrets; hostile root or
another process running as the service UID is outside this file boundary.

The local issuer integration now saves and reloads the account and request before
using them. Dedicated tests cover separate writer/reader processes, eight racing
writers with exactly one winner, immutable conflict handling, retained truncated
records, oversized files, permissions, symlinks and hardlinks. These establish
local file behavior, not host power-loss recovery or machine deployment. The
accepted ADR-0047 boundary remains unchanged. Production Ash coordination,
automated interrupted-record reconciliation, rotation/retention, state-directory
deployment wiring and NixOS restart acceptance remain outstanding.

The final Audi precommit gate passed 82 checks (16 properties, 66 tests), with
zero Dialyzer errors and no exclusions. Runtime, compiler, formatting, contract
and ADR checks passed. Custody contract discovery, the standalone ADR checker
and the scoped diff whitespace check also passed. No dependency or service
configuration changed in this slice.

## Certificate custody and SNI restoration

Issued chain records now bind the saved issuance request by ID and hostname.
The local custody reader revalidates the chain against current operator roots,
validity interval, exact SANs and the saved private key on every load. It never
trusts persisted validation metadata. Certificate JSON has a separate bounded
one-MiB envelope; account and request records retain their 64-KiB bound. Existing
exclusive creation, private ownership/link checks and fsync rules apply.

The SNI store's restore operation validates custody using its own configured
roots, then applies its existing revision, removal-tombstone and capacity checks
before replacing an entry. Missing or corrupt files preserve installed material.
The extended real issuance test persists the issued chain, restarts the store,
confirms it is initially empty, restores using the production operation and
completes a verified TLS 1.3 handshake with that recovered key/certificate. It
also checks immutable certificate conflicts, missing requests, wrong roots,
identity substitution, malformed/oversized records, stale/tombstone conflicts,
capacity rejection and preservation of an existing entry after a failed restore.

This implements more of ADR-0047's recovery boundary without changing its
authority model. A successful local restore is not publication permission.
Startup still needs current issuance identity/revision from the future Ash
coordinator; this change does not persist store tombstones or automatically scan
disk for installable certificates. The test restarts an application process,
not a VM or physical host. NixOS restart, renewal and route readiness remain open.

The final Audi precommit gate passed 82 checks (16 properties, 66 tests), with
the expanded issuance/recovery assertions in the existing integration test.
Dialyzer reported zero errors and no exclusions. Runtime, compiler, formatting,
contracts and ADR checks passed, as did explicit contract discovery for custody
and the SNI store, the standalone ADR checker and scoped diff whitespace check.

## Ash issuance admission and execution fencing

Marshall now owns issuance identity in an Ash/PostgreSQL resource, with audited
record creation and retirement. Its migration creates only issuance and audit
tables, foreign keys (including the placement/VM/host composite binding), positive
generation checks, a status constraint and a partial unique pending-VM index.
No private key, CSR body or issuer credentials enter these records.

Admission takes the exclusive service lock before the existing host/VM execution
checks and issuance lock. The service lock serializes the 128-pending-work limit;
the VM lock and database index prevent duplicate pending work. Exact repeated
bindings return the same durable ID without another audit mutation. A changed
binding retires prior pending work and creates its replacement in one transaction.
Failures roll back both changes. Service generation, live host evidence, placement,
execution epoch, VM generation and completed running execution remain mandatory.

The route coordinator's checks were extracted without changing their semantics,
so issuance and route readiness share one implementation. Entry actions remain
internal SystemActor-only and separately authenticate gateway credentials.
Admission establishes neither installed TLS readiness nor user access. The new
tests cover idempotence, authorization, stale evidence, changed generation,
retirement and no route creation; a property mutates execution-binding numbers
and checks that pending work cannot change. Existing route tests also passed.

This advances ADR-0047's accepted Ash ownership. It is admission only: the issued
and failed statuses reserve later completion states but have no transition API
yet. Gateway delivery, order/proof progress, completion, retry/renewal workers,
retention and CA quota scheduling remain absent. The backlog limit is not a
verified issuer quota or throughput claim. Multi-node admission stress and
end-to-end NixOS issuance remain open.

The focused admission/route run passed 12 checks before the new binding property.
The final full Marshall precommit gate passed 484 checks (46 properties,
438 tests), including distributed tests, and all six browser-state checks.
Forced Dialyzer passed with zero unsuppressed findings and the existing single
upstream exclusion; no unnecessary exclusions were reported. Runtime, compiler,
formatting, contracts and ADR gates passed. Contract discovery covered the three
new modules. The standalone ADR checker and scoped diff whitespace check passed;
direct PostgreSQL inspection also confirmed the partial pending-VM unique index
in the isolated test database. No production database migration was run.

## Durable issuer order binding

Pending issuance can now bind the saved CSR fingerprint and issuer resource
URLs through a current-execution-checked internal action. The action locks
service, host, VM and issuance, verifies pending status and exact binding,
requires a canonical lowercase SHA-256 digest and two distinct same-origin HTTPS
authorization URLs, and stores the order atomically. Authorization URL order is
normalized because issuer list order is not identity. Replays of the same order
reuse the record without another audit mutation; conflicting fingerprints or
URLs fail without replacement. Admission returns recorded order metadata so a
future gateway worker can recover instead of blindly starting another order.

The migration adds only nullable order columns and an all-or-none constraint.
The constraint explicitly checks non-NULL digest/authorization fields so SQL's
three-valued logic cannot accept an incomplete order. URL fields and action
arguments are sensitive; audit versions exclude URL bodies while retaining
the CSR binding digest. No private key is stored. Tests verify idempotence,
resumption, conflicts, user denial, stale execution and URL-free audit changes;
a property covers origin, scheme, userinfo, fragment, duplicate authorization
and malformed-digest rejection. A direct Ash mutation exercises the database
constraint rather than relying only on coordinator validation.

This is ADR-0047 coordination evidence, not CA validation or route readiness.
The declared issuer origin is authenticated gateway metadata; Marshall never
fetches it. Audi's configured-origin transport remains mandatory on recovery.
The gateway API, request/CSR custody acknowledgement, order-creation lost-reply
reconciliation, challenge replication, completion and renewal workers remain
unfinished. No production migration or external issuer request was performed.

The focused issuance/route run passed 16 checks (three properties, 13 tests)
before the direct database-constraint regression was added. The final full
Marshall precommit gate passed 488 checks (47 properties, 441 tests), including
distributed tests, and all six browser-state checks. Forced Dialyzer passed with
zero unsuppressed findings, the existing one upstream exclusion and no unused
exclusions. Runtime, compiler, formatting, contract and ADR gates passed, along
with explicit contract discovery, standalone ADR validation and the scoped diff
whitespace check. The generated migration was reviewed before applying it to the
isolated test database.

## Expiring DNS-01 proof registration

Issuance now stores an immutable set of one or two canonical SHA-256 base64url
DNS proof values, paired with an expiry. Registration requires an already bound
order and reuses the same locked pending-execution check as order registration.
That check authenticates the gateway and verifies service, host, VM and issuance
in lock order. Differing proof values cannot overwrite a bound set. Explicit
authenticated refresh may renew the identical set for 60 seconds from database
time; neither admission/recovery reads nor snapshots extend it.

The migration adds only proof and expiry columns plus an all-or-none/order-present
constraint. Proof arguments and attributes are sensitive and excluded from audit
payloads. Initial binding still records an audited mutation with its expiry;
heartbeat-only refresh is excluded to avoid unbounded repetitive history. Existing
order and admission behavior is preserved through a shared pending-row helper.

Focused tests cover initial order requirements, reversed-order replay, immutable
conflicts, no route creation, audit exclusion, stale-host renewal rejection,
expired-state reads without implicit extension, explicit renewal and direct
database rejection of proofs without an order. A property rejects duplicate,
padded, short, excessive and malformed values without partially recording them.

This advances ADR-0047 coordination but does not establish public DNS publication.
The proofs are gateway attestations, not independently computed from retained
account keys. A future authenticated replica feed must filter current execution,
pending status and proof expiry; raw stored rows are not a valid feed. Challenge
acknowledgement, replication, completion, renewal and deployment remain unfinished.
The migration was reviewed before applying it to the isolated test database.

The focused issuance/route run passed 22 checks (four properties, 18 tests).
The final full Marshall precommit gate passed 493 checks (48 properties,
445 tests), including distributed tests, and all six browser-state checks.
Forced Dialyzer passed with zero unsuppressed findings, the existing single
upstream exclusion and no unused exclusions. Runtime, compiler, formatting,
contract and ADR checks passed. Explicit contract discovery, standalone ADR
validation and the scoped diff whitespace check also passed. No production
deployment or DNS publication was performed.

After that full gate completed, a fresh `devenv shell` for the final documentation
check failed building `lilly-host-lock` (`resume_token.c`/ZFS header type errors).
The final ADR checker passed when invoked directly with the already installed
pinned Elixir executable. The passing application gate above predates this fresh
shell build failure; it does not establish that the current shell derivation or
native Lilly helper builds successfully.

## Current DNS proof projection

Marshall now exposes a trusted internal current-proof read for the future replica
publisher. It validates the stable label, selects pending issuance, locks the
gateway, host, VM and issuance in order, and rechecks live execution, binding,
pending status, canonical proof values and expiry after locking. The result
contains only ID, label, proof values and a TTL capped at five seconds and the
remaining proof lifetime. It includes no issuer/order URLs or route addresses.
Consumers must count the TTL from request start; the projection itself neither
extends proof expiry nor writes audit history.

Tests cover fresh projection, exact response keys, user denial, invalid/unknown
labels, stale host reports, short/expired proof deadlines, malformed persisted
values, retirement and gateway rotation. A property varies expiry and checks
that validity never exceeds stored lifetime or five seconds and reads leave the
deadline unchanged. This advances ADR-0047's publication prerequisites without
adding a DNS-packet control-plane dependency. Authenticated replica transport,
whole-directory versioning and startup wiring are still absent.

The previously observed development-shell failure was rechecked. The native
resume-token type/build corrections appeared in the shared worktree while it
was being inspected; this change made no Lilly source edit. A fresh `devenv
shell -- true` then exited zero, so the new application checks use the normal
pinned shell again. This establishes shell construction, not native resume or
Firecracker behavioral acceptance.

The focused proof-projection/route run passed 24 checks (four properties,
20 tests) before the expiry-bound property was added. The final full Marshall
precommit gate passed 496 checks (49 properties, 447 tests), including distributed
tests, and all six browser-state checks. Forced Dialyzer passed with zero
unsuppressed findings, the existing single upstream exclusion and no unused
exclusions. Runtime, compiler, formatting, contracts and ADR gates passed, along
with explicit contract discovery, standalone ADR validation and the scoped diff
whitespace check. There was no schema or protocol change in this step.

## Authenticated DNS proof transport

The control API now accepts a closed version-1 `dns-proofs` request containing
only a stable label. Its Ash service action authenticates a DNS-role credential
and keeps that shared credential lock through the current-proof projection.
Gateway credentials cannot acquire DNS-reader authority by changing local client
configuration. Existing TLS verification, fixed error responses, no-store headers,
privacy handling and four-KiB request/response bounds continue to apply.

Audi's DNS-role client validates the exact label, issuance UUID, one or two
canonical unique proof values and a TTL in 1..5000 milliseconds. It computes a
monotonic deadline from request start and rejects expired replies. The shared
local proof-set validator preserves the DNS codec's existing four-proof maximum;
the control reply applies the issuance protocol's narrower two-proof bound.
This adds a control wire route without changing the shared protocol library.

The real HTTPS integration provisions current Ash issuance/order/proof state,
fetches it with a DNS credential, and checks both local and server-side role
rejection plus credential revocation. Scripted verified-TLS peers exercise extra
fields, wrong labels, bad TTLs, malformed/duplicate proofs and a deliberately
delayed reply with a one-millisecond lifetime. API tests reject caller-supplied
TTL fields. No secrets or issuer URLs appear in successful replies.

This is ADR-0047's authenticated per-record transport, not a complete replica.
The local Directory contract still requires complete snapshots: this method does
not merge or publish a partial proof result, and no DNS query invokes it.
Catalog discovery, snapshot revision/consistency, background refresh, scale
acceptance and startup/Nix wiring remain unfinished. The next implementation
must preserve request-start expiry across the complete publication path.

The proof-transport gates completed successfully: Audi passed 82 checks
(16 properties, 66 tests), Marshall passed 498 checks (49 properties, 449 tests),
and both forced Dialyzer gates passed. Marshall retains its existing single
upstream exclusion; there were no unused exclusions. The ADR checker passed.

## Complete DNS snapshot receiver

This change continues ADR-0047 without moving durable authority into Audi.
The preceding turn verified the live precommit process to completion; it did not
establish deployment readiness. This turn adds the receiving half of the complete
publication path, rather than merging the per-label proof projection into a
directory that requires complete snapshots.

The new `Audi.DNS.Snapshot` decoder validates a closed version-one envelope with
zone, revision, global TTL, routes and proofs. Every route/proof record carries
its stable VM label and an independent TTL no longer than the global five-second
maximum. Canonical addresses/proofs, duplicate rejection, closed record fields,
10,000-label union bounds and request-start deadlines apply before publication.
The `dns-snapshot` control-client operation alone permits eight MiB; all existing
control operations keep their four-KiB limit and their verified HTTPS, deadline,
no-redirect and no-retry behavior. No remote hostnames are resolved from records.

`Audi.DNS.Replica` runs one control request at a time and schedules the next request
one second after completion. Directory publication remains atomic, revision
checked and expiry checked. Failed transport, decoding or publication does not
replace or renew existing state. OTP status redacts credentials and publication
contents. DNS packet handling still reads only the local directory. Address
entries now support independent deadlines; expired route authority returns stale
(SERVFAIL), never an invented absence. The existing proof-expiry semantics remain.

Semantic contract review covered root/Audi obligations and the client, Directory,
Challenge and Authority callees. The future producer must advance its durable
revision for a changed snapshot, including changed relative lifetimes: reusing a
revision with recalculated deadlines would correctly conflict at the receiver.
It must select complete current state with bounded batch queries; per-VM queries
across 10,000 VMs would threaten the five-second request-start budget. The receiver
does not solve that producer obligation or claim production availability.

Executed verification:

- Focused DNS tests passed 17 checks before the additional capacity/transport
  boundary cases were added.
- The final Audi `mix precommit` passed 90 checks (17 properties, 73 tests),
  compiler/format/contracts/architecture gates and forced Dialyzer with zero errors.
- Marshall's existing real HTTPS ingress transport/API regression tests passed
  all 19 tests against the changed Audi control client.
- New real-socket tests exercise controlled verified HTTPS feeding the background
  worker and actual UDP/TCP answers, alternate names, TXT, removal, malformed
  response retention, outage expiry, recovery, response bounds and status privacy.
  A 10,000-label decode is a parser-bound test, not a scale or deployment test.

Remaining implementation gaps: Marshall's complete-snapshot endpoint and durable
revision coordinator, batched current-state selection, service credential/startup
configuration, Nix wiring and deployment acceptance. The worker is deliberately
not started by the production application while these pieces are missing. No new
Nix acceptance is claimed; the previously tested standalone DNS service still
starts with an empty replica. Automated issuance, web SSO/forwarding/WebSockets
and full Firecracker/multi-host acceptance remain outstanding. ADR-0047 stays partial.

## Complete DNS producer and runtime wiring (2026-09-18)

The preceding goal turn made implementation progress by adding and verifying the
complete-snapshot receiver. This change connects it to Marshall's authoritative
state and enables it in the DNS role. Architecture impact is within ADR-0047:
Ash/PostgreSQL retain publication authority, Audi retains only an expiring local
replica, and the DNS path grants no guest stream authority.

`Ingress.Publication` models a per-zone durable revision in Ash. The authenticated
snapshot action holds the DNS service's shared credential lock, checks the
operator-configured zone and serializes each zone's selection and revision with
a PostgreSQL advisory transaction lock. Failed authorization or snapshot
construction rolls back revision allocation; a lost response after commit may
leave a harmless revision gap. The counter advances even when record values are unchanged, because
fresh request-relative lifetimes produce changed local snapshot content. No
PaperTrail history is generated for this operational counter; route, issuance
and endpoint business auditing stays unchanged.

The coordinator executes one bounded SQL statement for active endpoint inventory,
gateway service state, current placement/execution, connected fresh host evidence,
completed start/provision evidence, unfinished committed-relocation readiness,
route/certificate expiry and pending issuance proof expiry. This is an allowed
trusted coordination/readiness query under `marshall-domain-resource-boundaries`.
All those facts share PostgreSQL statement visibility and one database clock.
The read does not take mutation locks on every VM: it observes committed state
and the receiver bounds its age from request start. Authenticated admission still
uses its existing service/host/VM serialization. The query derives VM host from
the placement relation, matching the Ash calculation. An early focused test
caught an incorrect assumption of a VM-local host column; that was corrected
before the passing evidence below.

The 10,001st active endpoint is an overflow sentinel, causing complete rejection,
not a truncated catalog and false negative answers. Retired/expired publications
are omitted; malformed retained proofs or addresses fail the whole snapshot.
The response contains only stable labels, canonical addresses/proofs, bounded
lifetimes, configured zone and revision. It does not expose issuer URLs, guest
addresses, user membership or credentials. The new closed API request accepts
only version and zone. Credential revocation, wrong roles/zones and ordinary
actors cannot allocate a publication revision.

Runtime DNS configuration now requires the verified control origin and a separate
private DNS credential. Startup orders Directory, Server and Replica under the
existing rest-for-one supervisor. Directory loss restarts the dependent listener
and worker; a worker failure leaves the old directory bounded by its deadline.
Nix uses `LoadCredential`, a private service-owned token copy, an operator CA
bundle and prerequisite secret services. It adds no Lilly privileges or gateway
keys. There are no production dependency or shared-protocol changes in this slice.

Verification so far:

- Focused Marshall producer/order tests passed 12 checks (one property, 11 tests),
  including the actual HTTPS API/Audi client, current-state rejection, corruption
  rollback, independent expiry, revision exhaustion and committed relocation
  without readiness. An unused test alias warning was removed afterward.
- Two DNS identities concurrently allocate revisions using independent committed
  PostgreSQL connections. Eight results are uniquely ordered and a subsequent
  checkout observes the next durable revision. Cleanup targets only fixture IDs.
  This is not multi-node acceptance.
- A sandbox fixture with 10,000 active VM endpoints passes publication; adding
  the 10,001st causes rejection without advancing the counter. These synthetic
  rows prove inventory bounds, not host admission, guest execution or throughput.
- Audi's full precommit passed 90 checks (17 properties, 73 tests) and forced
  Dialyzer with zero errors. Marshall's first full gate passed 507 checks
  (50 properties, 457 tests) and forced Dialyzer with its one existing upstream
  exclusion and no unused exclusions. A final full gate includes the later
  corruption, relocation and catalog-limit cases.
- The source-built NixOS `audi-dns` check passed its 67.94-second test script. It
  verified initial SERVFAIL, actual HTTPS snapshot refresh, UDP/TCP A/TXT and
  alternate-port answers, complete removal, outage expiry, recovery, daemon
  restart and private credential permissions. The first build was stopped after
  inspecting the generated unit and proving its fixture CA path was absent from
  its closure; interpolating the fixture path fixed the dependency. The corrected
  build exited successfully. Its publisher is an isolated HTTPS fixture, not
  Marshall or Firecracker.

Final review finds no new user-authorization or cross-host byte path. The SQL
eligibility predicate and point-read execution checks must evolve together;
the Execution contract now records that maintenance obligation. Automatic
certificate/proof generation and installed-certificate readiness reports are
still absent. Therefore enabling DNS replication alone does not make VM app
URLs usable. Full Marshall-to-Firecracker, multi-control-host, relocation-ready
positive-path and sustained 100-host/10,000-VM acceptance remain outstanding.
Browser SSO, web sessions, HTTP/HTTPS forwarding and WebSockets also remain
unfinished. ADR-0047 remains partial and the overall implementation goal is active.

The first full gate containing the catalog-limit test failed that case (509/510
checks passed); its forced Dialyzer stage passed separately, but the command
correctly exited 2. The same case passed in focused runs. A local PostgreSQL
`EXPLAIN (ANALYZE, BUFFERS)` measured roughly 56 ms for the statement against the
10,000-row fixture in isolation. This does not explain or excuse the full-suite
failure. The test now retains fixed query outcome/timing diagnostics on failure,
and the complete suite is being rerun with the failing seed to identify the
cause. No final full-gate or sustained-capacity acceptance is claimed from the
focused result.

Concurrent integration then merged remote main and local resize work. The fenced
ingress decision is now ADR-0052, with its original rationale preserved by the
integration work. An attempted reproduction stopped at transient merge markers;
the next attempt encountered the older test database's mismatched migration
history. Tests resumed in a fresh dedicated `marshall_test_audi_publications_merged`
database without deleting the older database or changing production state.

All DNS cases passed in the fresh merged-tree full run. Four unrelated integration
failures remained: two permitted ordinary lifecycle during an unfinished resize,
and two rejected relocation receive-progress updates. This change restores the
explicit resize-busy check for new lifecycle intents under the existing VM lock,
preserving exact retries and the relocation-specific lifecycle allowance. That
repairs an ADR-0051/compute-retained-placement violation, without changing the
accepted resize design. The concurrent relocation work supplied its missing
internal action permission; that was not a DNS change. The subsequent full suite
passed 531 checks (50 properties, 481 tests), including the existing resize and
three-node race regressions. Forced type analysis is recorded separately below.

The isolated catalog failure has not reproduced in subsequent focused or merged
full-suite runs. Its fixed timing/error diagnostics remain in the boundary test;
the observation remains a limitation rather than a claimed resolved root cause.
Lifetime comparisons now explicitly normalize the database clock to UTC to match
the stored timestamp type. A dedicated non-UTC-session test covers this final
correction without depending on a server-wide time-zone setting.

Final UTC verification passed: the focused publication and independent-connection
ordering run passed 13 checks (one property, 12 tests). The regression was then
expanded to Honolulu and Kiritimati sessions, checking both live publication and
independent expired-route/expired-proof omission. The full Marshall precommit
passed 535 checks (50 properties, 485 tests), browser checks and forced Dialyzer
with its one existing exclusion and no unused exclusions. Contract discovery and
the structural ADR checker passed (52 decisions). Concurrent integration retained
the UTC query and both regressions; no acceptance claim is made for untested
Firecracker, multi-host or sustained-capacity behavior. ADR-0047 remains partial.

### Gateway certificate control wiring (2026-09-18, verification deferred)

The user requested implementing the remaining functionality before full
verification. The shared `IngressIssuance` schema now connects Audi's verified
HTTPS client to Marshall admission, order binding, proof registration and
completion. It rejects unknown fields and oversized values without creating
peer-derived atoms. Order bodies alone allow 16 KiB; other request limits remain
4 KiB. Recovery responses allow 32 KiB for saved bounded order URLs. Audi compares
the returned host/execution and issuance/digest identity against its request.

The Ash completion action locks current service/execution/issuance, binds the CSR
and records immutable issued/failed outcomes. Successful completion requires an
order. Failed unbound work can release pending capacity. Exact retry is read-only;
conflicting outcomes are rejected. Neither outcome creates a route. Pending-only
proof selection automatically excludes completed work. This implements existing
ADR-0047 work states, with no schema migration or change to access policy.

Added tests cover shared request/response bounds and property-generated values,
real HTTPS admission/recovery with an order body above 4 KiB, configured-host
mismatch, credential revocation and successful completion. Domain properties
cover terminal idempotency, immutable outcomes, audit preservation and removal
of pending proof/quota eligibility. Source formatting completed; these new tests,
consumer gates, contract checker and ADR checker have not yet been run. Final
verification must include protocol, both original protocol consumers and Audi.

Remaining implementation includes gateway inventory discovery, durable ACME
coordination/retry/renewal, validated installation and readiness reports, browser
SSO and web relay, deployment wiring and full physical acceptance. The route API
remains unexposed until its validating producer is connected. The overall goal
remains active; the earlier DNS gate does not validate these new changes.

Gateway inventory discovery now has a Service Ash action, authenticated HTTPS
endpoint and Audi client with a closed shared decoder. Only the authenticated
gateway's running current placements are returned, after fresh host checks. A
10,001st row rejects the entire catalog. Statement/lock deadlines are bounded and
restored; no per-VM network calls or audit refreshes are introduced. The inventory
is discovery, not issuance authorization, readiness or a web/SSH grant. Each later
action retains its execution checks. Audi rejects host mismatch, malformed or
duplicate identities and replies arriving after their request-start deadline.
Added properties and domain/HTTPS cases remain unrun per the requested sequencing.
No new architectural decision is needed; this connects ADR-0047's existing local
gateway work ownership. Gateway inventory discovery is no longer a missing API;
the worker consuming it remains unfinished.

Order preparation now persists a request before CA creation, a one-attempt marker
before the external side effect, and returned immutable order URLs before Marshall
binding. Recovery uses the configured issuer and saved request digest; retained
Marshall metadata can reconstruct a missing local order record only with the
original private request. Lost creation responses return an explicit unknown
outcome; no automatic duplicate CA order is created for that issuance. A later
scheduler must fail/back off/re-admit unknown work without treating the marker as
successful issuance. This preserves ADR-0047's private-key custody and bounded
work identity, without claiming exactly-once external effects.

Custody properties cover origin substitution and immutable records. Preparation
tests cover unknown attempt recovery and missing bound keys without depending on
an available CA. Formatting completed; test execution and consumer gates remain
deferred. Positive complete worker integration, challenge propagation, account
startup, certificate finalization/installation and renewal remain unfinished.

The resumable progression pass now calls the real order, authorization, proof,
acknowledgement, finalize and certificate custody primitives. It rebinds current
Marshall work before each pass and never returns readiness until certificate
trust and private-key binding have been revalidated and saved. Its ready result
does not install a listener or publish a route. Invalid orders finish as failed;
other bounded failures are returned to the still-unimplemented scheduler.

Propagation uses fixed configured IP/port pairs over length-bounded TCP, not a
recursive resolver. All replicas must answer authoritatively with the exact
owner/proofs; deadlines from the start of each query must remain live after the
last query. Two real Audi replica tests and generated proof sets were added but
not executed. Complete positive Progress integration, scheduler/account startup,
installation/route publication and renewal remain unverified or unimplemented as
specified above. These changes carry forward ADR-0047; no new access grant is
introduced and full verification remains deferred by user instruction.

Certificate restart recovery now has a latest-issued ID in the gateway catalog,
scoped to the current service ID/generation and stable VM label. The ID is a local
custody lookup hint, never an execution or certificate validation grant. The
installation helper restores through the existing validated SNI store and then
proves actual local TLS service using exact SNI, operator roots and leaf digest.
The probe only accepts loopback destinations, disables session reuse and returns
fixed errors. No HTTP application request or guest access is performed.

Generated fingerprint mismatch tests use an actual Audi HTTPS listener; catalog
tests now cover returned issued IDs. These additions are formatted but unrun.
Scheduler consumption, installed-readiness reporting and full application
forwarding remain unfinished. ADR-0047 remains partial; prior passing gates do
not validate the new catalog shape or installation helper.

The local validating installation producer now calls a closed authenticated
`route-ready` API after successful custody restoration and a real local TLS
handshake. Certificate metadata is derived from validated installed material;
Marshall still authenticates the gateway and checks current execution under its
existing lock order. The route contract now records the producer obligation
instead of the earlier temporary API prohibition. This connects ADR-0047's
accepted infrastructure-attestation design; it does not grant web/SSH access.

Shared properties reject injected addresses/lifetimes and malformed metadata.
The existing real-HTTPS control test now covers readiness transport and stale
generation rejection with fixture metadata; that test alone does not prove the
local installation producer. New tests and full gates remain deferred. Scheduler
startup, positive complete producer integration, web forwarding and deployment
acceptance remain outstanding.

The certificate worker now runs separate issuance and readiness loops so CA
operations do not directly block readiness refresh. Tasks have explicit
concurrency/time limits and private diagnostic metadata. Work selection preserves
active jobs and rotates other due VMs; generated tests cover complete traversal,
retry exclusion and negative monotonic clocks. Store revisions are allocated
before asynchronous work and removals retain tombstones. Account startup uses
durable key custody and explicit registration consent. Completed valid material
is installed/probed/reported before marking issuance complete; catalog IDs support
subsequent restoration, and expiry proximity can start renewal independently.

This worker is not yet wired into application/Nix startup. Full positive runtime
integration, durable quota/backoff across restart and fleet throughput remain
unverified or unfinished. Only formatting was run; added scheduler properties and
all required consumer gates remain deferred. No completion claim follows from
the presence of the scheduler source.

Gateway TLS startup and Nix wiring are now implemented behind explicit
`services.audi.tls.enable`. The closed runtime schema validates issuer/trust,
private custody, explicit account consent, distinct DNS replicas and ports.
Supervision starts the store and listeners before tasks and workers. Nix supplies
public roots through credentials, creates service-owned persistent custody and
opens web ports only under the existing firewall opt-in. Startup and Nix
evaluation cases were added, but execution is deferred. No production activation
was performed. The HTTP front still does not authenticate/forward guest traffic;
full positive worker integration and machine acceptance remain outstanding.

Added the bounded web header transformer required by ADR-0047 before connecting
guest forwarding. It reserves the `__Host-audi_` cookie prefix, removes caller
forwarding/identity fields and hop-by-hop nominations, reconstructs trusted
origin metadata and preserves guest Authorization. Responses cannot set platform
cookies; guest Domain attributes are removed without folding separate Set-Cookie
fields. Header count, field size, aggregate bytes and control characters are
bounded. Generated tests cover credential separation and cookie attributes;
fixed cases cover framing/nominations and malformed inputs. Formatting completed;
tests remain deferred. The module is not yet used by the HTTP front, which still
returns unavailable instead of forwarding without authority. Browser SSO,
session authority and actual streaming remain unfinished.

Browser authorization now has Ash exchange/credential resources and a transactional
coordinator. Begin locks gateway then host/VM, binds exact app/execution and caps
live exchanges. Approval verifies the stored user login and current Cedar web
sharing. Redemption checks the one-time code and canonical browser-state proof,
rechecks the original login and membership and atomically consumes the exchange
with cookie creation. Gateway credentials cannot authorize the user approval
action. Cookie identity is explicitly separate from the still-missing short-lived
stream authority. Distinct token purposes and hash-only persistence are enforced.

The Ash migration generator compiled current Audi/Marshall code and produced the
browser tables plus audit tables. Manual review found only additive forward DDL;
the generator's generic destructive warning corresponds to rollback operations.
No migration was applied and no test/precommit gate ran. Added properties exercise
state mismatch, replay rejection and bearer-purpose separation. Browser routes,
API/client codecs, retention and stream admission remain outstanding; this is
partial ADR-0047 implementation, not deployed SSO or verified browser behavior.

Gateway begin/redemption now have a shared closed codec and verified client/API
transport. Marshall's separate user controller preserves only a canonical fixed
ticket route across sign-in, performs domain approval and redirects to a configured
VM hostname. Its token-bearing route is included in authentication privacy tagging.
Audi now owns host-only state/return/session cookies and a reserved callback that
checks state/code and expected hostname before creating a browser credential.
Referrers and response caching are forbidden on secret-bearing redirects; duplicate
session cookies and external/ambiguous return paths are rejected.

The HTTPS front's Host/SNI gate now dispatches the callback, without guest access.
The begin function still awaits web admission integration; normal app requests
continue to return 503. Codec/return-path/cookie tests were added but not run.
Browser end-to-end acceptance, stream leases, retention and forwarding remain
outstanding. The protocol and both consumer gates must be included in the later
verification pass; no browser readiness is claimed from formatting alone.

Web stream authority implementation now adds `WebStream` and `WebStreams` with
five-second durable leases, purpose-bound hashed tickets, current execution and
stored-login/Cedar web checks, a 1,024-live-stream gateway bound, immutable policy
revision/app binding, and explicit close. Public access applies only to the primary
app. Policy changes, expired credentials and closed/expired streams reject renewal.
The shared `KittensProtocol.WebStream` codec, control API and Audi client carry
these grants; the client starts its deadline before the control request. Property
tests cover policy changes, alternate-port privacy, expiry/close and reply binding.
The additive generated migration was reviewed but has not been applied. Compilation
needed to generate it succeeded; the added tests and full gates are deferred until
implementation is connected, as requested. Guest web forwarding, its independent
lease watchdog, connector web support, retention and machine acceptance remain open.
This preserves ADR-0047's authority model and does not complete that decision.

ADR-0052's previously outstanding web service-port policy is implemented in the
shared connector, Lilly executor and namespace socket boundary. Web uses a distinct
privileged mark (`0x41554457`) and the admitted app port; the original SSH mark
still only permits port 22. Address/TAP/namespace selection remains derived from
the local current placement and the existing guardian fences both services. The
kernel does not validate HTTP semantics; Audi must expose only HTTP/WebSocket web
transport. Protocol properties and expanded Nix namespace fixtures are added but
unrun. No arbitrary TCP listener, cross-host route or guest-to-host exception is
introduced. Final review of these changes preserves the placement and privilege
boundaries in ADR-0047/0052; full web forwarding and acceptance remain outstanding.

The HTTPS frontend now invokes `HTTP.Proxy` after SNI/Host/port validation.
`HTTP.Authority` starts the existing independent StreamGuard before guest connect
and renews outside the connection owner and guard, including during blocked I/O.
The client preserves the monotonic request timestamp and expiry. HTTP uses Mint's
pinned HTTP/1 codec over the already authenticated Unix connector socket, bounded
body reads and passive response reads, with sanitized headers and no body-wide
buffering. Mint is now an explicit dependency (already present transitively).
WebSocket upgrade uses fresh upstream key proof, exact subprotocol selection,
no compression/extensions, bounded server frames/messages and masked client frames;
Bandit's WebSock handler retains the same owner and lease. WebSock is now explicit.
Connection completion stops renewal; guard expiry cannot revive a stream. Added
properties exercise masked frames, decoder bounds, suspended renewal/socket expiry
and real HTTPS-control-to-loopback-HTTP byte/header behavior. These tests have not
yet run. Browser/controller, worker/CA, Unix-to-guest and full machine verification
remain necessary; this is implementation progress, not milestone completion.

Boundary inspection also strips the entire caller `x-forwarded-` namespace and
prevents guest Cache-Control/Expires from overriding Audi's no-store policy.
Mint 1.10 bounds incomplete response/status/chunk lines via its configured header
limit; Audi restores its receive buffer bound after Mint initializes the existing
socket. The new WebSocket handshake uses a total header deadline in addition to
per-packet and aggregate header limits. These source findings still require the
queued regression and integration tests.

Web retention is now an AshOban maintenance action: each transaction deletes at
most 200 old streams, 150 unreferenced credentials and 150 browser exchanges,
all expired for seven days. Referenced credentials and audit versions remain;
full batches enqueue continuation atomically. Tests cover dependency ordering and
audit preservation. Structured DNS refresh transitions, certificate outcomes and
web lifecycle events now pass through a finite vocabulary and source-level
reconstruction that retains only validated UUIDs; generated arbitrary metadata
is covered by new privacy properties. These additions remain unverified.

New certificate admission now consumes durable fleet/hour and VM/day budgets
under a PostgreSQL transaction advisory lock. Failed/obsolete rows count; exact
pending replay does not. Defaults are 100/hour fleet-wide and 10/day per VM,
configurable through Marshall runtime/Nix options. This is a conservative local
admission budget, not evidence that a public CA grants sufficient domain quota.
A new index migration supports rolling-window counts. Gateway CA Retry-After
persistence and workload/CA quota acceptance remain outstanding. Marshall's Nix
module also now exposes the delegated zone and shared gateway HTTPS port, so
browser callback redirects can match non-default operator-configured TLS ports.

Generating the issuance-budget migration compiled the affected protocol, Lilly,
Audi and Marshall source successfully; it reported one Elixir bitstring pin
warning in the new frame decoder, which was corrected. This was schema-generation
compilation, not the consolidated gate. The generated migration was reviewed and
contains only the two issuance timestamp indexes; it has not been applied. Nix
configuration cases now assert the new environment values and reject a zero budget.

CA retry scheduling now loads an issuer-scoped private retry map and records
absolute deadlines via file fsync, atomic rename and directory fsync. The single
issuance scheduler writes a one-minute reservation before account or VM work,
then saves the resulting retry delay, including Retry-After; readiness does not
read or wait on that state. Invalid existing records are never overwritten.
Properties cover reload, issuer separation, reservation boundaries and corruption.
Normal scheduling retains monotonic VM deadlines alongside the persisted wall
clock deadlines. An interrupted attempt keeps its reservation; a response lost
before its retry deadline is persisted remains an ambiguous attempt, not proof
that the CA accepted or rejected it. Storage-failure/crash recovery acceptance and
custody garbage collection still need completion. The new WebSocket integration
property exercises actual Bandit upgrade and masked guest messages through an
HTTPS control fixture; it does not substitute for real Marshall/Lilly/VM acceptance.
All these new tests remain queued for consolidated verification.

A source integration check found the ordinary HTTP `Connection: close` response
header would also reach Bandit's upgrade response. The WebSocket path now removes
it before Bandit emits its own Upgrade header, and the transport fixture starts
with that header to cover the production frontend behavior. Stale, revoked or
missing browser identity now returns the dedicated authentication-required reason,
so a new request can restart SSO; current Cedar denial remains access denied and
renewal still revokes the existing stream.

Browser acceptance now includes a property spanning Audi's browser initiation,
Marshall's actual controller and HTTPS ingress API, and Audi's callback redemption.
It covers primary/alternate app hosts, the configured non-default callback port,
fixed anonymous sign-in returns, hostile forwarded-host input, wrong state,
one-use codes, host-only cookie attributes, current-login stream admission and
revocation. The certificate-worker scenario connects account/order progression to
a controlled HTTPS CA, two real Audi DNS servers, validated custody, local TLS
probing and readiness publication. It then stops the CA and issuance worker and
restarts the store/listener/readiness worker to exercise recovery from saved
material. Its control fixture is deliberately not Marshall; it complements rather
than proves full physical-VM authority. These newly authored scenarios remain
unrun, and real Nix/Firecracker acceptance remains necessary.

A new `audi-fleet` NixOS check now composes the real three-Marshall/two-Lilly
Firecracker fixture with two independently deployed Audi DNS replicas, one Audi
gateway per Lilly host and Pebble using actual DNS validation (never always-valid
challenges). Runtime service credentials are created through Ash and transferred
privately; issued certificate trust is fetched from the controlled CA. A console
fixture starts HTTP and WebSocket services inside the booted guest. Scenarios
cover actual DNS over UDP/TCP, certificate readiness before HTTP access, public
primary versus private alternate access, closing a live response on a policy
change, browser SSO and per-host cookies, WebSocket echo, and gateway restart
without changing VMM identity. This scenario is authored but not evaluated or run.
Physical SSH, failure/isolation variants and fleet scale acceptance still need
coverage; the new check does not replace them or establish production readiness.

The fleet restart scenario explicitly stops Pebble before restarting Audi, so
its recovery assertion requires already persisted certificate material rather
than fresh issuance. Guest response streaming uses an unbuffered client and
waits for the first actual guest line before changing policy. DNS assertions
wait for each replica's real publication, rather than treating Marshall's route
commit as proof that replicas have already refreshed. Formatting completed;
Nix evaluation, compilation and execution remain deferred.

The Audi fleet composition now builds a separate guest image with sshd enabled
and password authentication disabled; the production default remains serial-
console-only. The image builder accepts additional modules while preserving its
manifest and reproducibility path. The fixture installs only the guest public
key through the real console and obtains the real guest host key for strict
inner verification. Native OpenSSH consumes the production nested configuration,
uses a different platform key for Audi, and verifies the outer key through the
current HTTPS lookup. A live inner session is then revoked by removing the
platform key through Ash, with VMM identity checked before and after. These
scenarios are authored but unrun; they do not yet prove physical SSH acceptance.

### Publication checkpoint, 2026-09-18

This checkpoint implements the browser exchange and expiring web-stream Ash
resources, HTTP/WebSocket forwarding, durable ACME recovery and admission
budgets, structured events, and the Audi fleet Nix acceptance composition.
Architecture impact remains within ADRs 0047 and 0052; both remain partial.
Concurrent relocation changes are preserved in the same workspace checkpoint.

The consolidated Protocol and Lilly precommit gates passed. Lilly reported
271 checks (30 properties, 241 tests), with no Dialyzer errors. Audi reported
117 checks (34 properties, 83 tests), with no Dialyzer errors; its repeated
gate also passed after preserving the current connection state on proxy errors.
Marshall verification and the Nix machine builds are still in progress at this
checkpoint. The Audi fleet derivation evaluates successfully, but that is not
evidence that its physical VM acceptance scenarios pass.

Publication is an implementation checkpoint, not a deployment-readiness or
milestone-completion claim. Physical acceptance, consolidated Marshall results,
certificate recovery edge cases and the stated fleet-capacity target remain
unproven until their corresponding verification completes.

### Post-publication response-boundary verification

A socket-level property now varies partial guest response bodies and verifies
that guest truncation closes the real Bandit client connection without a
successful terminating chunk or a second HTTP response. This adds evidence for
the existing ADR-0047 streaming failure contract and changes no architecture.
Audi's full precommit gate passes 118 checks (35 properties, 83 tests), including
forced Dialyzer with zero findings. Marshall's consolidated tests pass 551
checks (57 properties, 494 tests); the full gate passes, including forced
Dialyzer with its one existing exclusion and no unnecessary exclusions.

The initial Nix machine run stopped before exercising ingress because the
daemon build user could not access /dev/kvm. The same derivations are now
running with the local privileged build store. The ingress network test passes
in 43.05 seconds, covering authorized SSH/web socket marks, unmarked/disabled
and wrong-port denial, guest lateral/host denial and forwarded-traffic denial.
This uses network namespaces, not Firecracker; fleet acceptance remains
unverified while its separate VM composition is building.

The first physical fleet run passed enrollment and fresh capacity reporting,
started both DNS replicas and gateways, issued and installed a certificate
through Pebble's actual DNS validation, and admitted a public web stream. It
then failed to retrieve guest HTTP. Inspection of the exact built guest
firewall showed only TCP 22 was permitted. The Audi acceptance image now
explicitly permits its fixed HTTP fixture ports 8080 and 3000; the production
guest default and Lilly host isolation policy are unchanged. The rerun must
establish end-to-end success; earlier issuance events alone do not prove it.

A further upload property sends arbitrary 65,537–200,000-byte binary bodies
through the authorized proxy to a real Bandit guest listener, which hashes
bounded reads and returns the checksum. This verifies request streaming across
multiple chunks alongside response truncation and WebSocket framing. Audi's
full gate now passes 119 checks (36 properties, 83 tests), with zero Dialyzer
findings. This strengthens existing ADR-0047 evidence without changing its
architecture or claiming fleet acceptance.

Rechecking the subsequently merged Lilly source exposed a test fixture using a
BEAM-local counter for a shared /tmp Unix-socket directory. The readiness test
now creates a random exclusive directory, avoiding collisions between concurrent
BEAM test runs without changing production behavior. Lilly's repeated full gate
passes 277 checks (30 properties, 247 tests), with zero Dialyzer findings.

The corresponding Marshall rerun has a new failure: the 10,000-endpoint
publication test reached its 1,500ms PostgreSQL statement deadline
(query_canceled, measured 1,499,971 microseconds). Earlier passing runs do not
supersede this result. The bounded query's performance remains under
investigation; its deadline has not been relaxed.

The corrected physical fleet run passes public HTTPS to the actual Firecracker
guest and public-to-private revocation of a live response, preserving the VMM.
It next failed in the browser helper: unlike the established fleet login
helper, it navigated away from the magic-link page without submitting its
explicit Sign in form. The helper now submits that form and waits for the
machines page. Fixed stage labels improve failure diagnostics without logging
exception text, private URLs, cookies or page content. Private browser access,
WebSockets and later fleet scenarios remain unverified pending the next run.

A separate diagnostic of the unchanged publication query using the same
10,000-row fixture measured 82.468ms execution; materializing the intermediate
publication CTE measured 78.988ms. Those isolated measurements do not explain
the earlier 1,500ms timeout. The default test selection passed on replay, but
excludes 33 distributed tests; a replay explicitly including those tests is
now running with the original seed. No production query or deadline was changed.

The full replay with the original seed (113492), including distributed tests,
passes all 551 checks (57 properties, 494 tests) in 217.3 seconds. The publication
timeout did not recur, with the same SQL and 1,500ms statement deadline. The
earlier failure remains recorded as an intermittent timing observation; neither
this replay nor the isolated plan measurement proves the fleet-capacity target.

The next physical run passes primary private HTTP and WebSocket access after
explicit browser sign-in. Its alternate-host cookie assertion failed because
the pinned Playwright 1.59.1 network.filterCookies implementation prepends a dot
and suffix-matches even host-only cookie domains. The helper now inspects exact
stored domains rather than that URL filter and also checks actual navigation
request headers: the first request to each application host must carry no
inherited Audi session cookie. It retains only counts, never header or token
values, in diagnostics. This strengthens the host-only test without changing
production cookie behavior. Remaining browser and fleet scenarios await rerun.

The cookie-corrected physical run passes the complete browser scenario:
owner HTTP/WebSocket access on primary and alternate hosts, exact stored cookie
domains, no inherited session on first navigation, and denial for the unshared
user. Native OpenSSH also reaches the real guest with independently pinned outer
and inner keys. The subsequent background SSH heartbeat unit exits before its
marker: the built client's systemd ManagerEnvironment PATH contains filesystem
utilities but not SSH/curl, unlike the successful foreground login environment.
The helper now explicitly sets its user HOME and application-tool PATH. All
background stream readiness waits are bounded and fail immediately on a failed
unit. The run was stopped after this definitive helper failure instead of
waiting for an impossible marker. Live SSH revocation and later isolation and
recovery checks still require the next run.


## Physical fleet acceptance completed, 2026-09-18

The corrected immutable Audi fixture passes the full `audi-fleet` Nix check in
653.19 seconds (local privileged store with nested KVM). The run verifies real
DNS-validating Pebble issuance, public HTTPS, private primary/alternate browser
HTTP and WebSockets, exact cookie scope, unshared-user denial, native nested SSH,
and live platform-key revocation. Three actual Firecracker guests across two
Lilly hosts reject same-host/cross-host guest and host-service connections,
including guest socket-mark attempts. Control-plane suspension expires live web
authority and DNS publications; resumed authority restores access. Independent
DNS failover and gateway restart with Pebble stopped pass, preserving the VMM.
The `audi-configuration` check also succeeds for the same immutable source.

This closes the authored physical fleet acceptance gap, including the corrected
background SSH helper. It does not close the 100-host/10,000-VM measured-capacity
target or the complete crash/storage-failure matrix. In particular, a CA response
with a long Retry-After whose custody update fails can leave only the earlier
one-minute reservation after a crash. That recovery finding remains unresolved.
ADR-0047 and ADR-0052 remain partial; their evidence and the access-flow guide
are reconciled without changing accepted decisions. The run pins the Audi source
through a504d12, including its known production inputs; concurrent later Lilly
cleanup/relocation changes are not covered by this run.


## Unknown CA outcomes and result-write recovery

The one-minute reservation finding has a concrete implementation refinement:
`Backoff.reserve/4` durably marks selected outcomes unknown and checks current
custody as well as scheduler state. Unknown markers do not expire; only a saved
result or explicit offline issuer-informed reconciliation replaces them. The
worker retries failed result writes with their original absolute deadline before
more CA work. Task exits keep unknown markers, while readiness remains independent.
This preserves ADR-0047's issuer restrictions instead of guessing a safe retry
window after a lost response. Offline reconciliation requires a stopped scheduler
and an operator-established issuer-safe time; it cannot verify that external fact.

Properties exercise killed reservation holders, arbitrary elapsed time, stale
scheduler state, rejected writes, reload, and preservation of unrelated unknown
records during reconciliation. The first Audi gate passes 122 checks (39
properties, 83 tests) and zero Dialyzer findings. The integration scenario is now
also extended to restore certificate readiness with unknown issuance markers and
the CA stopped; the final gate passes the same 122 checks and zero Dialyzer
findings. Contract discovery and semantic review covered Backoff, custody, the
issuance worker, its callers and the fixed operational event vocabulary. No new
external authority or protocol boundary is introduced. Earlier physical fleet acceptance does
not cover this subsequent retry refinement. Power-loss/filesystem fault injection
and measured fleet capacity remain outside the evidence established here.


## Issuance fairness under permanently pending orders

A new property reproduces starvation in the prior selector with four active
orders and one other due VM: the fifth VM is never selected. The implementation
now rotates active orders and other due VMs independently. When both groups are
due, active orders take at most three of four slots; an empty group leaves all
four slots available to the other. Unselected active orders retain their state
across rounds. This refines ADR-0047's bounded fair scheduling without changing
CA admission budgets, authorization, custody or external APIs.

The regression passes across varying inventory sizes and negative/positive
clocks, with a finite visitation bound for both groups. Single-group properties
also cover full slot utilization and rotation; future retry deadlines remain
excluded. The full Audi gate passes 123 checks (40 properties, 83 tests), with
zero Dialyzer findings. ADR and contract structure checks pass; semantic review
covered the selector, cursor advancement and preservation of unselected active
orders. These are scheduler correctness claims, not evidence of achieved fleet
throughput. The readiness loop still waits for
all jobs in a batch before fetching its next catalog; slow probe/report work can
delay healthy refreshes. That scheduling behavior requires separate measurement
and a bounded independent-completion design if it cannot meet route deadlines.


## Independent readiness completions and DNS failover preconditions

Readiness routes expire after five seconds, but the former worker waited for an
entire batch with ten-second task limits before fetching its next catalog. One
stalled job could delay healthy refreshes. The new bounded readiness pool launches
at most sixteen jobs, rotates due work on each completion, and reuses a slot only
after monitored process death. Catalog revisions are allocated before handing
work to the pool, preserving tombstone ordering across later launches. Changed
bindings cancel their old job before a replacement can start. Independent job
watchers enforce owner death and the original catalog deadline, including while
the scheduler is suspended. No external authority or route deadline changes.

The full Audi gate passes 127 checks (42 properties, 85 tests), with zero Dialyzer
findings. Properties cover healthy progress with blocked peers and bounded slot
reuse; tests cover suspended-scheduler expiry, binding replacement and owner
death. The existing real TLS/control integration passes with the new pool. These
checks establish scheduling behavior, not the 100-host/10,000-VM capacity target.

The physical run of the prior retry-recovery snapshot passes public/private web,
WebSockets, SSH, key revocation, guest isolation and control-plane outage expiry,
but fails the next single-node DNS assertion. That scenario immediately followed
the global outage without checking both replicas had recovered the VM record;
successful browser access can use cached DNS. The test now requires both direct
answers before stopping one node, then demands three immediate successful answers
from the surviving node, with the actual bounded DNS response on assertion failure.
The failed run did not capture that response, so its precise DNS failure remains
undetermined. These fixture changes and the new readiness pool need a new physical
run; the earlier complete fleet pass does not cover them.


## Bounded retry staging under storage failures

The retry writer previously chose a new random temporary name for every attempt.
A persistent write/rename failure could retain a new file each round. It now uses
one exclusive staging path per issuer. Failed writes preserve that path and block
further writes until recovery; no existing file is silently discarded. The offline
`Custody.recover_retry/2` operation requires stopped issuance, validates both
committed custody and the complete private staged record, then fsyncs the file,
renames it atomically and fsyncs the directory. Repeating completed recovery is
idempotent. Unknown outcomes remain subject to separate issuer-informed
reconciliation. This refines ADR-0047's private custody recovery without changing
platform authority, CA quotas or the accepted unknown-outcome rule.

The focused suite passes eight checks (seven properties, one test). New properties
vary interrupted bytes and repeated attempts, prove the retained file set stays
bounded and unchanged, reject insecure staging, and recover exact deadlines with
idempotent replay. These tests model retained filesystem artifacts; they do not
claim real disk-full or power-loss fault injection. The full Audi gate passes
129 checks (44 properties, 85 tests), with zero Dialyzer findings. Contract
review covered the exclusive write path, validation, file/directory sync ordering,
idempotent recovery and Backoff's error propagation; ADR and contract structural
checks also pass. The active physical fleet run pins the preceding readiness-pool snapshot and does
not include this later staging refinement.


## Full-catalog publication measurement

The earlier 10,000-endpoint bound test has only one publishable route. A separate
opt-in capacity test now models 10,000 publishable routes across 100 gateway
identities. It uses the real Ash publication action with unchanged 1,500ms SQL
and five-second response bounds, checks all route/label/address counts and emits
only aggregate timing data. Synthetic host/pool/placement/completed-operation
rows remain in the test's rollback-owned database sandbox. The first setup attempt
failed a host/pool foreign key; cloning matching pools corrected the fixture.

Ten successful publication samples measured 142894, 144095, 141544, 160419,
197045, 201336, 181240, 211899, 223941 and 253329 microseconds. Setup and simulated
freshness updates are excluded from those durations. This narrows one capacity
gap but does not measure readiness-write rate, network transport or guest traffic.
The test is explicitly selected with `--only capacity --include capacity`; the
ordinary suite excludes the new tag so a resource-sensitive measurement does not
masquerade as an always-run acceptance check. Architecture impact is verification
evidence for ADR-0047, with no production behavior change. Full Marshall precommit
passes: 551 checks (57 properties, 494 tests), with the one opt-in capacity case
excluded and run separately above. Distributed checks are included. Forced
Dialyzer passes with its one existing upstream exclusion and no unnecessary
exclusions; runtime, compiler, browser-state, ADR and contract gates also pass.
The measurement used the pinned Elixir 1.20.4/OTP 29.0.6 runtime with four BEAM
schedulers and the isolated `_audi_publications_merged` database partition.


The subsequent physical fleet run passes in 601.56 seconds with the independent
readiness pool, fair issuance scheduler, and explicit DNS recovery preconditions.
It verifies the entire authored scenario: real certificates and guest ingress,
browser/WebSocket access, SSH and revocation, three-guest isolation, control-plane
outage expiry, three surviving-node DNS answers, and gateway restart without the
CA while preserving the VMM. This run pins source through 7de073f; the later
bounded retry-staging change has its separate 129-check application gate and is
not included in this physical run. The prior failed DNS response was not captured;
the new pass establishes the corrected scenario, not a retrospective root cause.


## Authenticated readiness action baseline

The opt-in capacity fixture now also measures one gateway refreshing 100 distinct
VM routes within its 10,000-VM inventory. It installs a valid ephemeral service
token digest and invokes `Ingress.report_ready_route/2`, including the existing
service/host/execution locks and checks. Three sequential rounds take 861416,
792206 and 779782 microseconds; their slowest individual requests take 22644,
10570 and 10919 microseconds. All 100 routes remain fresh after each round under
the unchanged five-second lifetime. Both capacity cases pass together.

This is not concurrent-fleet throughput: a rollback-owned SQL sandbox serializes
database access, and this baseline excludes local certificate validation and
TLS/HTTP transport. A concurrent measurement needs independent committed database
connections and isolated fixture ownership. No production behavior or authority
rule changes. Full Marshall precommit passes 551 checks (57 properties, 494 tests),
with the two opt-in capacity cases excluded and separately passing. Forced
Dialyzer passes with the existing upstream exclusion and no unnecessary exclusions;
all runtime, ADR, contract, compiler and browser-state gates pass.


An exploratory committed-load diagnostic then used an exclusively created database,
100 gateway workloads, 16 BEAM schedulers and a 32-connection pool. Each request
used an independent unboxed database checkout; a separate connection maintained
synthetic host freshness once per second. Three 10,000-route rounds completed in
4688791, 4715606 and 4724320 microseconds, with all 10,000 actions successful and
all routes still fresh at each round's end. The [aggregate data](../measurements/2026-09-18-audi-readiness.json)
contains no credentials or fixture identities. The first diagnostic setup attempt
failed on a missing local alias and rolled back; the corrected run committed its
fixtures, validated deferred constraints, and completed. Its dedicated database
was then dropped; shared test databases and other work were preserved.

This is close to the five-second limit and excludes certificate/HTTP/DNS/guest
work. It is three rounds, not sustained deployment acceptance. The exploratory
script was derived from the current fixture; integrating a reusable committed-load
harness and measuring the actual network path remain required before broad fleet
capacity claims.


### Reusable capacity harness publication — 2026-09-18

Scope: extract the existing publication fixtures into shared test support and
commit a reproducible isolated-database harness using the actual Audi HTTPS
client, Bandit TLS listener and Marshall ingress API. No production behavior,
protocol, authorization or accepted deadline changes; ADR-0047 remains partial.

The first HTTPS measurement failed the unchanged five-second target in all three
rounds (5.20–5.43 seconds), with 9,373–9,642 of 10,000 routes fresh despite 10,000
successful updates each round. This is an outstanding capacity acceptance gap,
not evidence that the earlier Ash-only measurement meets the fleet target.
Aggregate results are retained in the
[measurement artifact](../measurements/2026-09-18-audi-readiness.json). Investigate
transport/database contention and validate deployment resources before claiming
capacity. Larger-runtime and sustained-load measurements remain unexecuted.
The harness uses only caller-owned databases and loopback TLS fixtures; the
operator procedure preserves its failure status while dropping that run's data.

Publication validation: Marshall `mix precommit` passed with 551 checks
(57 properties, 494 tests), two opt-in capacity exclusions, and forced Dialyzer
with one existing upstream exclusion and no unused exclusions. Both explicit
capacity tests then passed with the shared fixture. ADR and contract structural
checks passed. These regression results do not override the failed concurrent
HTTPS measurement or establish acceptance on the latest merged deployment.


### HTTPS allocation comparison — 2026-09-18

The unchanged 100-gateway/10,000-route HTTPS harness was run with 32 BEAM
schedulers/64 database connections and eight schedulers/16 connections. Both
configurations failed all three rounds: respectively 5.76–6.31 seconds with
7,924–8,727 fresh routes and 8.95–9.50 seconds with 5,294–5,532 fresh routes.
Every round completed 10,000 successful updates. Neither increasing nor reducing
these allocations met the unchanged acceptance bound. No production settings
were changed. A separate aggregate database-timing diagnostic is the next step;
these observations alone do not identify the bottleneck. The earlier statement
that larger-runtime measurements were unexecuted is superseded by these results.


An exploratory telemetry handler then aggregated query count, total, queue,
execution and decode durations from `[:marshall, :repo, :query]`, without SQL,
parameters or credentials, resetting before each measured round. At 16
schedulers/32 connections each round emitted 120,001 query events (12 per update
plus the final freshness count). Connection queue time totaled 3.62–3.84 seconds
across all concurrent requests, versus 52.8–95.1 seconds total database timing;
these sums are not wall-clock durations. Profiled rounds took 5.54, 6.63 and 4.93
seconds: two failed freshness and one passed. Instrumentation overhead is
included. This does not support claiming a pool increase fixes capacity and does
not yet identify the dominant application cost. All aggregate observations are
retained in the measurement artifact; temporary timing instrumentation is not a
production feature. Investigate repeated request coordination and client/server
CPU costs before selecting an optimization, then verify the actual deployment.


### Remove the redundant readiness route lookup — 2026-09-18

The coordinator previously read a route by VM ID without a lock and then read
that same route by its primary key with `FOR UPDATE`. It now uses one Ash read by
the unique VM identity with `FOR UPDATE`. Service authentication and shared host
locking still precede the exclusive VM lock, which remains held through route
creation or mutation. Thus concurrent reports for one VM still serialize even
when no route exists. Certificate checks, expiry bounds, audit behavior and
current-execution validation are unchanged. ADR-0047's accepted requirements and
partial implementation status are unchanged.

The new generated sequence test alternates certificate fingerprints and verifies
one stable route identity and exactly one revision increment per accepted report.
The focused route suite passed (two properties, eight tests). Existing cases
cover denied generation/execution bindings, revoked credentials, stale hosts,
certificate expiry and audit creation versus refresh. Contract discovery and
structural checking passed; load and full-gate results are recorded below.


At 16 schedulers/32 connections, three profiled HTTPS rounds passed in
4.75–4.87 seconds. Query counts fell from 120,001 to 110,001 per round, confirming
one fewer statement per update. A subsequent unprofiled 12-round run failed its
first round (5.187 seconds); the next eleven passed at 4.623–4.894 seconds.
All 10,000 updates succeeded and all routes remained fresh after each round.
The first round remains included in the result, and the five-second bound is
unchanged. These results establish the query reduction and observed timings,
not reliable fleet capacity. The measurement artifact retains every round.

The full Marshall `mix precommit` gate passed: 552 checks (58 properties,
494 tests), two opt-in capacity exclusions, and forced Dialyzer with one existing
upstream exclusion and no unused exclusions. ADR and code-contract structural
checks passed. The real HTTPS load runs above were executed separately. Both
caller-owned load databases were dropped after retaining aggregate results.
No Nix fleet rerun is claimed for this query-only change.


### Bound the execution-history result — 2026-09-18

`Ingress.Execution.current!/3` now uses `Ash.exists?/2` with the same VM,
placement, execution epoch, generation, completed status and start/provision
predicates as its previous record scan. It retains service/host/VM locking and
all freshness, relocation and gateway checks. This shared check is called by
readiness, current-route reads, issuance, web streams and web login flows.
Their existing caller contracts continue to require current persisted authority;
none gains authority from a raw stored route. The publication SQL already uses
the same existence predicate, so it requires no eligibility change. ADR-0047
remains partial. No production dependency or API changes are introduced.

A generated sequence test changes only the sandbox fixture's operation status
and kind, asserting that both readiness admission and current-route lookup
accept exactly completed start/provision states. The focused route suite passed
(three properties, eight tests). The change returns a boolean instead of
materializing operation records. Performance and full-gate results follow below.


The subsequent unprofiled HTTPS run passed all twelve rounds with 10,000
successful updates and 10,000 fresh routes each. The first round took 4,998,463
microseconds, leaving approximately 1.5 ms below the unchanged five-second bound.
This is a passing recorded run, not evidence of comfortable resource margin,
stable deployment capacity or a statistically significant speedup. The aggregate
artifact retains all rounds and previous failures. The remaining capacity work
must exercise the actual multi-node deployment and independent gateway producers.


Validation completed: Marshall `mix precommit` passed with 553 checks
(59 properties, 494 tests), two opt-in capacity exclusions, and forced Dialyzer
with one existing upstream exclusion and no unused exclusions. ADR and contract
structural checks passed. The separate twelve-round HTTPS measurement passed as
recorded above, and its caller-owned database was dropped. This change has not
been claimed as a fresh Nix fleet acceptance run.


### Current-state documentation and merged-main fleet verification — 2026-09-18

The architecture overview and ADR-0047 mixed early "unimplemented" statements
with later evidence. They now contain a current-status summary, while preserving
the implementation journal and its historical failures. Accepted decisions and
partial status are unchanged. The latest synthetic twelve-round HTTPS run is
listed as passing with approximately 1.5 ms first-round margin, not actual fleet
capacity. Broader relocation, crash and storage-failure acceptance remains open.

A specific remaining obligation is update-health and rollback coverage for both
Audi roles. The current Audi fleet scenario tests gateway restart/custody recovery
and DNS-node failover; those do not establish package-update health or failed-
update rollback. The service modules and the recorded tests must not be presented
as satisfying that separate ADR invariant.

A fresh full fleet check was launched from an immutable archive of merged main
`20730a0422e5f4d19376ebfa5a261e933f648a13`, including the readiness query changes
and main's Lilly cleanup changes. This launch is not yet a passing result; its
terminal outcome will be recorded separately. No source files in the running
snapshot are changed by this documentation reconciliation.

### Merged-main fleet result and private updater readiness — 2026-09-18

The captured `20730a0` fleet script completed successfully in 596.87 seconds.
The log records every Audi subtest completed: real guest web, browser HTTP and
WebSockets, native nested SSH, live key/policy revocation, guest isolation,
control-plane outage expiry, independent DNS failover, and gateway restart with
the CA stopped. The original tool session handle was lost during interruption;
the completed test-script log and absence of remaining build/test processes
establish that the test script is terminal. No new updater-readiness code was
included in that immutable source snapshot.

The updater previously omitted Audi from its explicit consumers and health
units. Both roles now appear in the candidate manifest and must return exact,
role-bound affirmative readiness over private mode-0600 Unix sockets. Startup
validates the socket's canonical path, trusted ancestors and private owned
directory. Existing non-socket entries and active sockets are preserved/refused.
Status probes execute one check at a time, kill work after five seconds, consume
no request bytes and return no credentials, identities or remote diagnostics.

Gateway health requires its managed listeners and current authenticated gateway
catalog. Configured web listener ports must also accept local connections.
DNS health requires its managed UDP/TCP listener, a fresh local replica and an
authenticated control identity. Neither check grants sessions, issues certificates
or refreshes local authority. The existing updater deadline bounds all roles and
only exact version/role/ready responses can advance healthy state. Stale or
unavailable control authority fails health even when the unit remains active.

Architecture impact: ADR-0047's existing update-health obligation is now wired
into the ADR-0036 updater. No domain ownership or authorization decision changes.
Application and focused updater checks cover response bounds, role confusion,
exceptions and conjunction across enabled roles. Actual gateway update/rollback
and dual-role package recovery remain separate acceptance obligations.

Verification: the Audi full gate passed 136 checks (45 properties, 91 tests) and
forced Dialyzer with zero findings. A subsequently added stalled-check recovery
test passed with the other three status-socket tests; all eight focused updater
tests passed. The packaged DNS Nix check passed in 48.84 seconds, including
negative initial readiness, affirmative fresh readiness, control-outage rejection,
restart recovery and mode/ownership inspection. Nix configuration checks passed.
The generic updater machine check passed in 91.31 seconds, including failed
activation, health-only retry, fixed candidate selection and preservation of the
last healthy revision. It verifies the shared updater runtime change; its fixture
does not run Audi roles and therefore does not establish Audi-specific package
rollback acceptance. The captured DNS/configuration/updater snapshot contains
the production changes; the later additions only extend unit regression tests.

### Dual-role update-recovery acceptance — 2026-09-18

The fleet scenario now asserts deployed private gateway/DNS readiness before,
during and after a control-plane outage, and after gateway restart with the CA
stopped. The first run containing those checks used merged main `6f0e518`
plus the captured scenario. That run terminated at the first private DNS probe:
the fixture's Marshall/DNS host had no `python3` on PATH (exit 127). It did not
reach the readiness assertions. Python is now explicit in the Audi fleet test
packages, and a corrected run includes the update-recovery scenarios below.

Further fixture changes add distinct source-built Audi releases to both gateway
and DNS candidates. A controlled regression returns negative readiness while
keeping the service running. The test requires failed health to preserve the
previous healthy revision, then publishes a corrective revision using the
working package and verifies restored traffic and unchanged Firecracker process
identity. DNS recovery additionally checks the independent surviving replica.
This follows ADR-0036's corrective-update semantics: automatic code rollback
after migration is not the accepted behavior and no schema rollback is attempted.

Evaluation caught two fixture omissions before runtime: the Marshall node
function needed its `config` argument for candidate closures, and enabling its
updater required a 49-connection budget including migration reserves. The fixture
database already permits 64 connections; serving pools remain ten per replica.
Both omissions are corrected. Evaluation alone did not establish package-recovery
acceptance; the runtime observations follow.

The corrected full run passed live readiness for both roles, guest web/browser/
SSH, revocation, isolation, outage expiry/recovery, DNS failover and CA-stopped
gateway restart. It also passed the first real gateway release update and
rejected the deliberately unhealthy gateway with `health_timeout`, preserving
the previous healthy revision and guest process. The corrective update then
failed verification. Its invoking system used the fixture's shortened 20-second
health timeout; the first working update had used the normal 120-second window.
The log does not establish which readiness condition was pending at timeout.
The fixture-only short override is removed from both roles so every stage uses
the accepted default 120-second window. This retains the failed observation;
corrective recovery and DNS updates were unproven at that point.

The next complete run passed in 1008.57 seconds with terminal build exit zero.
Its immutable source snapshot used merged main `6f0e518` plus the two fleet fixture
files in this change. Both roles passed working-package updates, rejection of
running but unhealthy releases with `health_timeout`, preservation of
`lastHealthy`, and recovery through a corrective revision. Gateway traffic
returned with the CA still stopped; the independent DNS replica served answers
during the first replica's health failure. The original guest process identity
remained unchanged. The gateway and DNS update subtests took 190.03 and 190.80
seconds respectively. Live role health across control outages and all existing
web, SSH, revocation, isolation and restart scenarios also passed.

Architecture impact: this supplies bounded physical evidence for ADR-0036 and
ADR-0047's existing update-health and corrective-recovery contracts; it introduces
no new production behavior. The run excludes later concurrent Inception changes
on main. Fleet capacity and the broader relocation/crash/storage-failure matrix
remain open. Structural ADR and code-contract checks passed separately.

### Relocation acceptance in progress — 2026-09-18

The `audi-relocation-fleet` composition enables the real transfer service on
both Lilly hosts and appends a move to the existing Audi scenarios. Shared
relocation helpers retain the existing admission and physical-cleanup assertions.
The added scenario requires unchanged stable naming and client configuration,
HTTPS lookup of the destination gateway key, independent retained guest SSH
identity/data, stream termination and refusal of stale source addresses. It
observes actual publications and never writes route or execution authority.
Architecture impact: verification of existing ADR-0047 and ADR-0037 relocation
contracts; no production behavior changes. Runtime acceptance remains pending.

Source review caught three composition issues before machine execution: transfer
network addresses differ from registered gateway addresses, administrative SSH
already occupies port 2222, and restarting Pebble regenerates its in-memory issuer
identity. The first build was explicitly cancelled while compiling dependencies,
not after an observation timeout. The corrected snapshot resolves gateway
addresses exactly as enrollment does, advertises transfer SSH on 2223, and
suspends/resumes the same CA process around the outage scenario. The ordinary
Audi and relocation compositions retain their existing behavior. The corrected
build has completed source release compilation and reached machine startup.
At publication, its immutable snapshot is based on `620057f` plus the captured
test changes; the live run remains in progress. No physical relocation result is
claimed yet. Python syntax, unchanged AST for the extracted existing relocation
scenario, ADR structure (54 decisions) and code-contract structure checks pass.

The corrected run is now terminal with build exit one. All preceding Audi
scenarios passed, including gateway and DNS corrective updates (191.43 and
186.53 seconds). The move completed baseline and final incremental receive,
destination import, committed handoff, source-authority revocation and destination
guest readiness. Repeated `storage_busy` receive failures delayed progress;
`import_execution_unconfirmed` was also observed before import recovered. The
total 1800-second relocation deadline then expired waiting for source cleanup,
which reported `source_cleanup_unconfirmed`.

Bounded local diagnostics showed an inactive source unit with `deleted.json`,
`intent.bin`, `vm.json` and ready disk-claim markers still present. The destination
unit was active, with received import state and ready disk-claim markers. Neither
side reported a native resume token. These observations do not establish the
specific failing cleanup guard. The final stable-name, destination SSH lookup,
HTTPS and stale-source assertions were not reached. No timeout was extended and
no successful relocation claim is made. Investigation must distinguish pool-lock
contention from other cleanup refusals before changing recovery behavior.

The next diagnostic change preserves the source driver's guard order and
authority checks while distinguishing post-tombstone console removal, snapshot
retirement and disk deletion failures. Only those closed atoms and pool-lock
`storage_busy` pass through the cleanup worker; rejected values stay private.
A generated regression exercises plain and wrapped failure payloads, requiring
unchanged pending receipts, bounded duplicate reporting and no private text in
logs. This implements observability for ADR-0037/ADR-0047 investigation, not a
cleanup fix or successful physical acceptance. Component verification follows.

The focused diagnostic suite passes 11 cases (two properties and nine tests).
The first full gate used the original workspace's development shell and failed
one stream test because its native helper contained unrelated local exit-code
changes while this worktree's Elixir decoder did not. Forced Dialyzer reported
zero findings, but that gate exited two and is not a pass. Running from this
worktree's own pinned shell passes the complete Lilly gate: 295 cases (32
properties, 263 tests) and forced Dialyzer with zero findings. The mismatched
helper was not used in the Nix fleet snapshot. A new immutable fleet snapshot
uses merged main `0c17ded` plus these diagnostics; its physical result is pending.

That diagnostic run is now terminal with build exit one. All preceding Audi
checks passed again, including gateway corrective updates (192.40 seconds) and
DNS corrective updates (188.07 seconds). Relocation failed at the unchanged
900-second baseline-stage deadline, before final transfer, handoff or source
cleanup. Early receive attempts reported `stream_failed` and `storage_busy`.
Attempt 103 later reported 1,029,575,656 bytes, but no verified receipt arrived
before the deadline. Permit renewal alone did not reset that deadline.

Terminal local diagnostics showed the source unit active with ready disk markers
and no deletion tombstone. The destination unit was inactive, with an active
import journal in `receiving` state, no ready disk markers and no native resume
token. Byte progress and absence of a resume token do not prove a completed,
verified receive. This run did not exercise the new cleanup stage classifications
or the post-move ingress assertions. The next investigation must distinguish
native stream completion from receipt verification and delivery; increasing the
test deadline would not establish either. The retained local evidence is
`/tmp/audi-cleanup-diagnostics-fleet.log`, from immutable snapshot
`/tmp/audi-cleanup-diagnostics-w34b9hz5`.

The failure-only fleet diagnostic now also captures bounded selected native
process states and numeric parent relationships. It reads neither argv nor
environment nor descriptor contents, emits closed wait/descriptor categories,
and explicitly marks incomplete scans. This changes test observability only;
ADR-0037/ADR-0047 transfer authority, receipt checks and deadlines are unchanged.
One hundred generated synthetic private-path/malformed-state cases plus process
count and missing-proc checks passed locally. These checks validate diagnostic
privacy and bounds, not native stream completion. Physical diagnosis still
requires a new fleet run with this observation available at failure.

The process-diagnostic run (`/tmp/audi-process-diagnostics-fleet.log`, snapshot
`/tmp/audi-process-diagnostics-kcbzxb1y`) completed the physical relocation:
baseline and final receipt, destination import, committed handoff, readiness,
both revocations, source cleanup, source dataset absence and reservation release
all passed the existing relocation helper. A transient generic cleanup refusal
recovered without changing authority checks. This contradicts a claim that the
earlier generic error alone establishes a permanent cleanup defect.

The overall build still failed: the concurrent HTTP stream helper exited one,
and the post-move check found its systemd unit failed. Its readiness marker had
already established real guest bytes. The helper incorrectly required curl to
exit nonzero after stream termination, excluding a clean EOF; it exited after
12.898 seconds, before the relocation completed. The fixture now accepts clean
EOF or curl's partial-transfer/empty-response/receive-error outcomes (0/18/52/56),
while rejecting client timeout (28) and other failures. This changes only the
transport-termination oracle, not relocation deadlines or production behavior.
Stable DNS, destination key lookup, retained guest SSH identity/data, post-move
HTTPS and stale-source rejection remain unverified because that assertion stopped
the run before those checks.

The clean-EOF rerun (`/tmp/audi-relocation-eof-fleet.log`, immutable snapshot
`/tmp/audi-relocation-eof-y570fufe`) exited one at the unchanged 900-second import
stage deadline. Gateway and DNS corrective-update checks passed in 191.71 and
191.35 seconds. Baseline receipt verified 1,029,575,656 bytes; the final receipt
verified 1,581,464 bytes after receive retries. Destination import remained
unconfirmed, so no handoff or post-move access assertions were reached.

Failure diagnostics showed both units inactive. The source retained ready disk
markers and VM ownership without a deletion tombstone. The destination retained
an active import journal in `received` state, without disk-ready markers, VM
ownership or launch intent. Its bounded process snapshot included a running ZFS
child of a host-lock process; both process scans reported incomplete coverage.
This narrows investigation to import/adoption after verified receive, but does
not establish which import guard or native operation failed. No deadline,
receipt requirement or execution fence was relaxed. ADR-0037/ADR-0047 acceptance
remains partial; the clean-EOF correction is not yet physically verified by a
complete relocation run.

The destination execution guard now classifies jail cleanup, network detach,
disk-adoption callback and VM ownership publication with four closed error atoms.
Preconditions and effect order are unchanged. Both callers (relocation and clone
adoption) continue to reject all failures; no receipt or launch authority is
introduced. The runtime allows these atoms while suppressing duplicates and
redacting wrapped values. The focused suite passes 11 cases (two properties and
nine tests), including generated import/cleanup reasons with private payloads.
This is an ADR-0037/ADR-0047 observability refinement, not a native failure fix;
the complete Lilly gate and a stage-diagnostic physical run remain pending.

The complete Lilly gate now passes 296 cases (32 properties, 264 tests), with
forced Dialyzer reporting zero findings. This validates the application changes,
not native import recovery. The next immutable fleet snapshot is
`/tmp/audi-import-stages-kfm4ka54`, with output retained in
`/tmp/audi-import-stages-fleet.log`; physical acceptance remains pending.

That stage-diagnostic run is terminal with build exit one. All preceding Audi
scenarios passed, including gateway recovery (192.38 seconds) and DNS corrective
updates (186.94 seconds). The new reason located a transient import failure in
the adoption callback; it subsequently recovered. Handoff, both revocations,
destination readiness, source cleanup, dataset absence and reservation release
completed. The corrected stream-termination assertion also passed.

The first post-move DNS assertion then timed out after 60.58 seconds: querying
`m2` did not satisfy the expected destination address `192.168.1.5`. A fresh
destination-placement ingress route had already been observed. This does not
prove that the DNS answer was stale rather than absent, because the assertion
did not retain the answer. SSH key lookup, retained-data SSH, HTTPS and stale-source
checks were not reached. Investigation now concerns publication eligibility,
DNS consumption and the expected address; physical relocation completion alone
does not establish stable-name access acceptance.

The expected destination address uses the same client-side host resolution as
gateway enrollment. A local UDP check using the actual Audi wire encoder and
`dig +short` returns only the expected IPv4 address, excluding an unconditional
encoder warning as the explanation. The fixture now retains bounded answers from
both DNS replicas and selected route/service/host eligibility facts on failure.
It still requires the exact destination address within 60 seconds. This changes
failure evidence only, with no publication writes or relaxed authority checks.

The local publication branch was updated to origin/main `981ffc8` on September 18.
Existing uncommitted relocation work was archived and retained in a separate
stash before the fast-forward; all ten original file contents were verified
against that stash after restoration. Overlapping import diagnostics now retain
the upstream disk-adoption/ownership reason names, add the local claim,
tombstone, intent and unit distinctions, and preserve storage/import contention.
The receive-runtime property includes these reasons and checks duplicate
suppression, unchanged pending receipts and rejection of wrapped private payloads.
DNS failure diagnostics are best-effort: a diagnostic failure cannot replace the
original assertion failure. No accepted architectural decision or authority
deadline changes (ADR-0037/0047); physical relocation access acceptance and the
broader capacity/recovery obligations remain open.

Verification of the restored local tree passes the pinned Lilly precommit gate:
298 checks (32 properties, 266 tests), zero forced Dialyzer findings, 61 ADRs and
the contract checker. Python syntax and whitespace checks pass. This does not
verify the newly merged main features or establish physical DNS relocation
acceptance; the running Nix snapshot predates this merge.

An offline execution of the actual DNS diagnostic exception block also passes
100 generated cases (seed 918): DNS command failures, SQL diagnostic failures,
nonzero responses and oversized answers retain the original assertion, truncate
answers to 4,096 characters and exclude private exception text. This validates
failure reporting only, not live DNS publication.

The DNS-diagnostic snapshot `/tmp/audi-relocation-dns-hkm89bdc` subsequently
terminated with build exit one (`/tmp/audi-relocation-dns-fleet.log`). It timed
out at the unchanged 900-second import-stage deadline, before handoff or DNS
assertions. The final incremental receipt was verified; the destination retained
an active/received import journal but no disk claim, disk readiness, launch intent
or VM ownership marker. Both placement units were inactive. Bounded process
observations were incomplete and do not identify the failed native operation.
The only effect reason was `import_disk_adoption_unconfirmed`; that older snapshot
collapses storage/import contention into this reason. It provides no new DNS
answer evidence and does not invalidate the prior completed physical move.

The next captured tree `/tmp/audi-main-diagnostics-o09ckhmb` contains main
`981ffc8` plus the preserved local changes and refined diagnostics. Its adjacent
JSON manifest records the base revision and modified-file hashes. Nix evaluation
is in progress; physical acceptance has not been run on that tree yet.

Evaluation of that captured tree subsequently passed. The full
`audi-relocation-fleet` build is now running, with output retained in
`/tmp/audi-main-diagnostics-fleet.log`. No physical result is claimed from
evaluation or release compilation.

The publication regression now also models a completed handoff in its isolated
database sandbox. It requires an unchanged endpoint label, rejection of the
retained source report, no publication before the destination report, and exactly
the destination address afterward. The current-route lookup must agree with the
complete DNS projection. All 13 focused publication checks pass (one property,
12 tests; two capacity checks excluded). This covers persisted predicate behavior
only; synthetic completion does not prove transfer, cleanup or physical DNS.
The full Marshall gate is running for this test extension. No production predicate
or architecture requirement changes; ADR-0037/0047 acceptance remains partial.

That full Marshall gate subsequently passed: 684 checks (60 properties,
624 tests; two opt-in checks excluded), browser-state checks and forced Dialyzer.
The one documented upstream exclusion remains used, with no unsuppressed findings
or unnecessary skips. Output is retained in
`/tmp/audi-postmove-publication-precommit.log`. This verifies the updated local
tree's application gate, including the completed-handoff regression; the running
physical snapshot predates that test-only extension.

The updated-main physical run is terminal with build exit one. All preceding
Audi scenarios passed, including gateway and DNS corrective updates (191.49 and
200.09 seconds). Final receive, import, committed handoff, revocations, guest
readiness and physical source cleanup completed. The new import diagnostic
reported `storage_busy` and recovered without changing authority or deadlines.

The DNS failure evidence identifies a fixture error: both replicas returned an
authoritative NOERROR answer containing exactly the expected destination
`192.168.1.5`, with TTL 20, but dig first tried their IPv6 addresses and printed
connection-refused text before falling back to IPv4. All selected route/service/
host eligibility observations were true. The exact stdout comparison consequently
timed out. The fixture uses the DNS module's IPv4 default (`0.0.0.0`) and now runs
`dig -4` for the assertion and failure diagnostics. It retains exact address
comparison and the original 60-second timeout. A local UDP check confirms the
explicit-IPv4 command returns only the address. This is not a production DNS fix;
the post-move SSH/key-lookup/HTTPS assertions were not reached in that run.

Failure diagnostics also now read a bounded kernel lock table and the selected
pool-lock inode, returning only held/unheld/unknown plus a numeric owner PID.
The helper does not read command arguments or change any lock. Native flock
acquisition/release and 100 generated parser/privacy cases pass, including
oversized, malformed, missing-inode and invalid-encoding evidence. Contract
discovery/format and ADR checks pass. This extra observation is not present in
the completed snapshot and does not prove which process caused its contention.

Publication review against origin/main `cbf5bdb` also found a fixture composition
collision introduced by the new Customer-isolation scenario: it assigned its
endpoint to the primary VM's `policy` variable. The later relocation scenario
would then request the Customer VM's gateway key instead of the VM being moved.
The Customer scenario now uses `customer_policy`; its authorization and network
checks remain unchanged. Python syntax and an AST check confirm that only primary
VM setup assigns `policy`. This preserves ADR-0047/0064 behavior and changes no
production authority. The live IPv4 rerun is based on the earlier immutable
snapshot, not this newer Customer/passkey merge.

On that merged tree the focused publication suite passes again: 13 checks
(one property, 12 tests; two capacity checks excluded). Contract structure and
all 64 ADR records also pass. Logs are retained in
`/tmp/audi-merged-publication-focused.log` and
`/tmp/audi-merged-publication-structure.log`. The 684-check full gate above belongs
to the earlier base; it is not presented as a full gate for these newer main
changes. The access guide now states Customer's owner-only exception explicitly.

The next recovery extension exercises ADR-0052's independent guest lifetime and
live-stream fencing through the packaged Lilly service. It opens actual nested
SSH and streamed HTTPS, kills only Lilly's main process, requires both streams to
finish without accepting client timeout, and compares guest process identity
before and after. It then requires a different Lilly main PID, fresh admitted SSH
and HTTPS, and an unchanged strict SSH profile. The VM's public policy is restored
to private before the existing key-revocation scenario. This adds physical
verification without changing production behavior. The main-process crash case
passes as recorded below; broader actor/storage/capacity obligations remain open.

Evaluation of that recovery extension against current main found a fixture
integration gap: mandatory Ziggy on each Lilly lacked its required encrypted
secret document. The [fleet Ziggy module](../../../nix/verification/tests/machines/fleet/ziggy.nix)
now retains the real service, issues independent Ziggy credentials through the
real Marshall operator after host enablement, and seals them through the existing
runtime SOPS/recovery-recipient path. Provider discovery uses a local TLS fixture
on m1 with synthetic provider keys and an isolated trusted CA. Both Lilly nodes
must pass Ziggy's actual readiness response, including real control identity,
before enrollment completes. No fake inference admission or live provider calls
are introduced. This preserves ADR-0063 as carried forward by ADR-0064; it does
not expand Customer egress or establish inference acceptance.

Python parsing, contract format/discovery and all 64 ADR structures pass. A native
HTTP probe of the provider fixture passed 304 cases (seed 918), checking valid
discovery, generated invalid credentials/hosts, denied control paths and POSTs,
bounded responses, and absent request logging. This probe does not establish TLS
or packaged-service acceptance. The corrected `audi-relocation-fleet` Nix dry-run
evaluation passes on an immutable snapshot of main `1efb7c0` plus local work
(`/tmp/audi-ziggy-recovery-eval.log`). The complete VM driver build also passes,
including generated-script type checking and linting
(`/tmp/audi-ziggy-recovery-driver-build.log`). Physical execution of that exact
snapshot has started (`/tmp/audi-ziggy-recovery-fleet.log`); its result remains
pending.

That live snapshot has passed real enrollment in 171.70 seconds, including the
two Ziggy readiness assertions after runtime SOPS delivery, plus Audi DNS/gateway
credential setup in 38.77 seconds. This exercises packaged Ziggy's TLS provider
discovery against the isolated catalog and real Marshall control identity.
It establishes fixture startup/readiness, not inference workload acceptance.
Subsequent guest/crash results are recorded below; the full suite remains pending.

The immutable IPv4 rerun (`/tmp/audi-ipv4-relocation-lop3ftoj`, based on `981ffc8`
plus the preserved local transfer changes) terminated unsuccessfully at the
900-second baseline-transfer deadline. Its log is
`/tmp/audi-ipv4-relocation-fleet.log`. The source VM remained active and no
handoff, final import or post-move DNS/SSH/HTTPS assertion was reached. The
destination emitted three `storage_busy` and two `stream_producer_failed`
diagnostics; the latest observed attempt counter was 59 with zero bytes. Final
local observations showed a held source pool lock (numeric PID 62200), an
unheld destination pool lock, and an active destination import journal still
marked receiving. The bounded process scans were incomplete. These are
point-in-time facts, not proof of a particular holder causing starvation or a
successful transfer. The earlier completed physical move remains separate
evidence; this rerun does not establish the DNS fixture correction's end-to-end
acceptance. Transfer reliability remains an open prerequisite for that check.

Tracing the failed producer exposed an observability gap in the source's
[export entry point](../../../lilly/lib/lilly/transfer/endpoint.ex): all failures
became exit status 1 without a journal reason. It now emits the fixed
`lilly.transfer_export_failed` event and a closed reason allowlist through the
existing stderr JSON logger, flushing before exit. Arbitrary failures and
exceptions use fixed fallback reasons. The SSH stdout data channel, success/failure
status, permit checks, native ownership and lease rules are unchanged. This
preserves ADR-0037 and ADR-0042, improves evidence without claiming a transfer fix,
and is not included in the already-running immutable recovery snapshot.
New property tests reject wrapped and arbitrary private failure payloads and
assert empty stdout; successful classification remains silent. Lilly's test
suite and full precommit gate pass 303 checks (34 properties, 269 tests), including
forced Dialyzer with no findings (`/tmp/audi-export-logging-precommit-final.log`).
The initial gate identified a missing `no_return()` specification on the new exit
helper; that was fixed before the successful full rerun. Loading the newly compiled
endpoint module explicitly into the packaged runtime also confirms exit 1,
empty stdout and the closed stderr JSON event for an invalid synthetic request.
That runtime probe does not substitute for a newly built release or real export
failure acceptance.

The immutable Ziggy/recovery snapshot subsequently passes real guest HTTP
(84.57 seconds), public-to-private live-response closure (7.38), browser identity
and WebSockets (31.46), and strict nested SSH (13.35). The new Lilly main-process
crash subtest passes in 26.10 seconds: active SSH/HTTPS streams close without
client timeout, the independent guest retains its process identity, Lilly
restarts with a new PID, fresh strict SSH and verified HTTPS succeed, and the
client profile hash is unchanged. Platform SSH-key revocation then passes in
7.14 seconds. These are executed Firecracker results from
`/tmp/audi-ziggy-recovery-fleet.log`, not completion of the still-running fleet
suite or the broader actor/storage/load matrix.

The source-export logging change is committed as `c8e8bb8` and merged with
upstream `1728e11` in `bc75fba`. The clean publication worktree's complete Lilly
gate passes 302 checks (34 properties, 268 tests), with forced Dialyzer reporting
zero findings (`/tmp/audi-export-publication-precommit.log`). The earlier
303-check gate includes the separately preserved local transfer changes; these
two scopes are intentionally distinct. All 20 working-file hashes matched the
pre-publication backup after the merge. The live physical snapshot still uses
its earlier captured tree and does not include the new source-export event.

The published `bc75fba` source-built Lilly release also builds successfully
(`/tmp/audi-export-published-build.log`). Three isolated release-executable probes
confirm the invalid-request entry point exits 1 with the closed endpoint reason,
an exporter-expiry classification exits 1 with its closed reason, and successful
classification exits 0 without a failure event. All three leave stdout empty;
synthetic request data and the invalid configuration path are absent from stderr.
This verifies the packaged logging boundary, not a real source-transfer recovery.
The access guide now also reflects the already-recorded twelve-round capacity
measurement, including its 1.537 ms worst-round margin and unchanged scope limits.

Before committing the fixture extension, `audi-relocation-fleet` also evaluates
successfully against merged main `bc75fba` plus the preserved local work
(`/tmp/audi-recovery-current-eval.log`). This checks the newer provider-selection
configuration; the physical results above still belong to the earlier immutable
snapshot. Gateway package-update rejection and corrective recovery have also
passed in that live run (199.42 seconds); DNS update and relocation remain pending.

The same immutable run subsequently passes DNS package-update recovery in
192.13 seconds and begins relocation. After initial `storage_busy` reports it
transfers approximately 1 GB of baseline data with the existing implementation;
that byte counter alone does not prove receipt or handoff.

Review of contention handling found that transfer preparation/receipt and source
registration previously abandoned their entire attempt after a single unavailable
pool acquisition. They now opt into a two-second monotonic acquisition-retry
window. Only `:host_already_owned` acquisition results are retried, with short
jittered waits; callbacks, exceptions and uncertain acquisition results are never
replayed. Native handshake/release retain their own bounds, and all other pool
callers keep a single attempt. The service/host/VM authority, pool/permit ordering,
lease checks, stable lock inode and native cleanup requirements remain unchanged
under ADR-0017/0037. The initial two opt-in transfer call sites and remaining 20
default call sites were inspected for this distinction.

Four focused unprivileged native-lock checks pass (one property and three tests),
covering release during contention, callback-at-most-once even when it returns a
busy error, persistent contention, exceptions and cancellation. The full Lilly
precommit gate passes 307 checks (35 properties, 272 tests), with forced Dialyzer
reporting no findings (`/tmp/audi-pool-retry-precommit.log`). Integrated execution
remains pending. This change is absent from the
live fleet snapshot and cannot explain its recovery or establish a starvation
fix.

The same bounded acquisition policy now also covers import-journal reads and
native disk adoption, where the physical run subsequently reported contention.
The shared disk-adoption caller used by cloning retains its existing placement
and destination activity/stream guards; only pre-effect pool acquisition retries.
Four call sites now opt in, while the other 18 retain a single attempt. The full
gate passes again for this extension: 307 checks (35 properties, 272 tests) and
forced Dialyzer with no findings (`/tmp/audi-pool-retry-import-precommit.log`).
An immutable snapshot with all four call sites is building its VM driver
(`/tmp/audi-pool-retry-driver-build.log`) for integrated verification.
Independently, the unmodified physical
run has verified the final receipt, imported the disk, committed handoff, and
revoked both transfer sides; destination activation and cleanup remain pending.

The immutable Ziggy/crash/relocation run then completes successfully: the full
script finishes in 1803.68 seconds and the build exits zero. Its relocation
subtest passes in 705.05 seconds. The destination is running and ready; physical
source cleanup completes with one retained disk reservation. Both explicit-IPv4
DNS assertions return the destination. The gateway key lookup changes to the
destination while the strict client profile hash stays unchanged, and nested
SSH reads the retained guest marker. Verified HTTPS serves the original name
after the guest application restarts, while forced stale-source HTTPS and SSH
connections fail. Log: `/tmp/audi-ziggy-recovery-fleet.log`; immutable source:
`/tmp/audi-ziggy-recovery-3qupc8jx` (manifest in the adjacent `.json`).

This closes the captured end-to-end relocation-access and Lilly main-process
crash cases, while preserving the earlier failed runs as reliability evidence.
It does not include the newly added pool-acquisition retries, later upstream
private-inference changes, or source-export logging. The capacity and broader
actor/storage-failure matrix remain open; ADR-0047 stays partial.

The subsequent bounded-pool-retry snapshot
(`/tmp/audi-pool-retry-rqbtfod0`, based on `b57e093` plus preserved/local changes)
builds its complete VM driver successfully, including generated-script type
checking and linting. Its implementation hashes match the tree that passed the
307-check Lilly gate. Full physical execution has started in
`/tmp/audi-pool-retry-fleet.log`; its outcome remains pending and is separate
from the completed 1803.68-second baseline above.

The next targeted storage-failure extension revokes access to the existing
certificate-custody directory, restarts the packaged gateway while its CA remains
unavailable, and requires expired route publication plus denied SSH and direct-IP
HTTPS. A `finally` block restores permissions. Recovery must serve the same
public TLS certificate, preserve the custody directory inode and guest process,
and restore strict SSH access. No key/record contents enter diagnostics and no
stored files are replaced. This exercises ADR-0047's private-storage validation
through the actual service rather than inferring it from parsing tests. Scenario
and generated Python parsing, contract discovery/format and ADR structure checks
pass; physical execution is pending. The currently running bounded-pool-retry
snapshot does not contain this newer scenario.

The custody-fault snapshot (`/tmp/audi-custody-fault-zhvzp16d`, based on `b57e093`
plus the captured local changes) successfully builds the complete VM driver,
including generated-script type checking and linting
(`/tmp/audi-custody-fault-driver-build.log`). It is prepared for physical
execution after the ongoing contention-retry run; no fault-injection pass is
claimed yet.

The capacity harness previously checked fresh-route count only after each round,
which could miss an expiry followed by recovery during the next round. It now
queries freshness independently at roughly 100 ms intervals and fails any
post-bootstrap round with an observed missing/expired route. Sample count and
maximum gap are explicit aggregate diagnostics, without credentials or route
identities. This strengthens ADR-0047 verification without changing production
authority or its five-second lifetime. Sampling has measurable overhead and
does not prove continuous or physical fleet availability. Runtime validation
of the sampler now completed in a disposable database: three rounds emitted
53–54 samples with maximum gaps of 112–113 ms. Post-bootstrap sampled minima
(8,919 and 8,761) were lower than endpoint counts (8,965 and 8,864), confirming
that endpoint-only reporting missed observed lows. All 10,000 requests succeeded
each round, but the run exited 1 on freshness and timing failures. Concurrent
native-fleet and compilation/test load makes these timings diagnostic only;
the measurement artifact records that limitation. The database was dropped
by the fixture cleanup. Contract/ADR structural checks passed. Marshall's full
gate passed 717 checks (64 properties, 653 tests; two opt-in checks excluded)
and forced Dialyzer with zero errors or skips
(`/tmp/audi-sampled-capacity-precommit.log`).

The user subsequently removed the large-fleet capacity investigation from scope.
Existing measurements are preserved, but scale acceptance is no longer a
completion gate. The active multi-process diagnostic terminated with status 143;
all workers exited and its disposable database was dropped. The unfinished
experiment was archived in `/tmp/audi-cancelled-capacity-experiment.tar.gz`
before removal from the pending implementation. The previously exercised
freshness sampler remains; no further capacity investigation is planned.
Remaining work returns to integrated relocation/recovery verification and the
required project checks; no production authority or safety deadline changes.

The same immutable custody-fault snapshot also builds the complete native
`zfs-transfer` driver, including generated Python type checking and linting
(`/tmp/audi-transfer-driver-check.log`). Physical execution of that storage
suite is now running separately to verify the updated closed import-intent
failure classification against actual retained storage. Driver construction
alone is not a native storage acceptance result.

The bounded pool-retry fleet run has now passed with terminal exit zero
(`/tmp/audi-pool-retry-fleet.log`, immutable snapshot
`/tmp/audi-pool-retry-rqbtfod0`, based on `b57e093` plus captured local changes).
The full script takes 2004.31 seconds; relocation takes 899.33 seconds. Import,
destination running/readiness and eventual physical source cleanup complete;
both DNS replicas, retained guest data through the unchanged strict SSH profile,
stable-name HTTPS and stale-source refusal pass. Source cleanup required retries
with closed `storage_busy` and `source_cleanup_unconfirmed` observations. This
proves eventual completion in this run, not the cause of each retry or a general
starvation guarantee. It covers the current native failure classifications and
all four bounded acquisition call sites, but not the newer custody fault.

The prepared custody-fault snapshot has now started physical execution in
`/tmp/audi-custody-fault-fleet.log`. Its relevant source files match the current
tree. The full run remains pending; the preceding passing retry run must not be
used as evidence that permission-loss recovery has passed.

The separate native `zfs-transfer` run also passes with terminal exit zero in
461.17 seconds (`/tmp/audi-native-transfer-check.log`), using the immutable
custody-fault snapshot. It covers real streams, interrupted receive/resume,
lineage rejection, journal recovery, adoption interruptions, cancellation cleanup
and nonrecursive source reclamation. The revised import-intent assertion runs
against actual retained storage. This is native local-storage evidence, not
independent-host or SSH authentication evidence; the separate fleet run provides
the latter boundaries.

Integration with upstream `8446a41` is merged as `d6d7a36` without conflicts.
The merge preserves all Lilly transfer changes and Audi scenario sources.
Upstream adds optional Ubuntu fixtures and shares the guest address parser;
the default Audi guest still uses the same validated /32 addressing and host
gateway. The merged tree passes 54 focused Marshall checks (four properties,
50 tests; two opt-in cases excluded), 66 ADR structure/link checks and contract
validation (`/tmp/audi-latest-main-integration.log`). Its immutable clean snapshot
`/tmp/audi-integrated-main-5yble5f0` builds the complete Audi relocation driver
with generated-script type checking and linting
(`/tmp/audi-integrated-main-driver.log`). This build is not a new physical run;
the still-running custody test retains its earlier recorded snapshot.

Final application gates on the merged tree also pass: Audi has 140 checks
(46 properties, 94 tests), and protocol has 129 checks (49 properties, 80 tests).
Both Dialyzer runs report zero errors or skips; Audi uses forced checking.
Logs are `/tmp/audi-final-application-precommit.log` and
`/tmp/audi-final-protocol-precommit.log`. These complement the 307-check Lilly
gate and 717-check Marshall gate plus the focused post-merge integration run.

The new unreadable-custody scenario passes in 11.06 seconds within the running
`/tmp/audi-custody-fault-fleet.log` test. It observes route expiry and empty A
answers from both DNS nodes, denies direct-IP HTTPS and strict SSH, restores
permissions in the existing custody directory, and verifies the same TLS
certificate fingerprint, directory inode and guest process with the CA offline.
The script continues through package updates and relocation; this subtest pass
is not yet a terminal result for that complete run.

The custody-fault run subsequently terminated with exit 1: relocation timed out
at cleanup after import, committed handoff and destination running/readiness.
The source retained its deletion tombstone, ready disk claim and inactive unit.
Its point-in-time pool lock owner was a native helper with a ZFS child in state
`D`; the destination pool was unheld. Only two closed cleanup failures had been
emitted (`source_cleanup_unconfirmed`, then `storage_busy`, with identical later
failures suppressed). A single process sample does not establish kernel deadlock,
the responsible ZFS operation or lock starvation. The earlier 2004.31-second
full pass remains valid for its snapshot; this later failure is retained too.

Source snapshot retirement and final disk deletion now opt into the same bounded
two-second pool-acquisition retry already used by transfer preparation/import.
The latter uses a new optional `Disk.delete/3` argument; ordinary deletion keeps
its default single attempt. No protected effect is repeated, no lock inode is
replaced, and source quiescence, identity, tombstone and native deletion checks
are unchanged. This addresses immediate contention refusals, not proven long
kernel stalls, and has not yet established recovery from this failure.

Native utility uncertainty now reports a fixed utility/reason, elapsed
milliseconds and optional numeric lock-helper PID for timeouts, output limits
and lost ownership. Arguments, executable paths and output stay private;
successful and ordinary nonzero utility exits remain silent. The numeric owner
can be correlated with the bounded lock observation without reading process
arguments. Property tests exercise private arguments/output and native timeout
handling. Application/native verification is pending.

Focused verification passes seven checks (two properties, five tests), using
real native command output limits and a timed-out FIFO copy under the lock owner.
The first test invocation failed during setup because `:file` is reserved ExUnit
metadata; renaming the fixture field fixed the setup without changing behavior
or assertions. The complete Lilly gate then passes 310 checks (36 properties,
274 tests) and forced Dialyzer with no findings
(`/tmp/audi-cleanup-contention-precommit.log`). The immutable next fleet snapshot
is `/tmp/audi-cleanup-retry-0faohuzw`, based on published `f46fb30` plus ten captured
local files, including the cleanup retries and utility logging. Its build/run is
active in `/tmp/audi-cleanup-retry-fleet.log`; native recovery remains unproven.

The new snapshot builds its complete native fleet driver with Python type
checking and linting enabled before beginning VM execution. Contract review
traces both disk-deletion callers: ordinary deletion retains zero acquisition
retries, while source retirement opts in only after quiescence and durable
deletion fences. Utility-result values and argument arrays are unchanged; the
bounded caller review prioritizes 64 native-storage, transfer, VM and network
references rather than claiming an exhaustive review of unrelated callers.
The logging boundary never passes arguments/output to the logger, independently
of which inspected caller invokes it.

### Subsequent main integration

Committed cleanup refinements `626715f` merge with upstream `a4c1e5f` as
`695ee8f`, without conflicts or discarded local work. Upstream introduces Brady
and Porsche changes. At the shared utility boundary it adds the fixed
`flow_label` utility enum without changing uncertainty logging. Brady remains
disabled by default in the Audi fleet composition. Upstream also changes Lilly
network setup/teardown and Marshall publication query planning, so the earlier
native snapshot is not evidence for these merged changes.

The merged Lilly gate passes 331 checks (39 properties, 292 tests), contract
validation and forced Dialyzer with zero errors or skips
(`/tmp/audi-brady-merge-lilly-precommit.log`).
The immutable cleanup-refinement fleet run continues against its original
snapshot. This integration adds no new Audi architecture decision; ADR-0047
acceptance remains open, with upstream Brady boundaries recorded in ADR-0069.

The remaining merged gates finish with terminal exit zero in
`/tmp/audi-brady-merge-consumers-precommit.log`: protocol passes 134 checks
(51 properties, 83 tests), Audi 140 (46 properties, 94 tests), and Marshall 725
(64 properties, 661 tests; two opt-in cases excluded). All three Dialyzer runs
report zero errors or skips. The clean merged snapshot
`/tmp/audi-brady-integrated-v7uw6ba3` also builds the Nix fleet driver with type
checking and linting, terminal exit zero, in
`/tmp/audi-brady-integrated-driver.log`. That build is not physical acceptance.
The cleanup-refinement physical run has passed custody recovery and gateway
updates and is checking DNS updates; relocation remains pending.

### Cleanup-refinement physical acceptance

`/tmp/audi-cleanup-retry-fleet.log` finishes with terminal exit zero: the complete
script takes 1668.42 seconds and relocation takes 551.84 seconds. This run uses
`/tmp/audi-cleanup-retry-0faohuzw` with both new cleanup acquisition retry sites
and private utility diagnostics. It passes unreadable-custody recovery (11.45
seconds), gateway corrective updates (199.14 seconds), DNS corrective updates
(193.17 seconds), actual source cleanup, both destination DNS answers, retained
guest data through unchanged strict SSH, stable-name HTTPS and stale-source
refusal. An intermediate `source_cleanup_unconfirmed` result was retried before
eventual completion; this pass does not establish absence of transient failures
or prove the cause of the preceding failed run.

The built merged snapshot `/tmp/audi-brady-integrated-v7uw6ba3` now runs the same
complete physical scenario in `/tmp/audi-brady-integrated-fleet.log`. It includes
the new main Lilly network setup/teardown changes with Brady disabled in this
composition. This is the outstanding physical integration check; no scale
experiment has been resumed.

### Final merged acceptance and completion audit

The merged run terminates successfully with exit zero in
`/tmp/audi-brady-integrated-fleet.log`. The complete script takes 1520.47 seconds;
relocation takes 409.34 seconds. Custody recovery passes in 11.12 seconds,
gateway corrective updates in 200.51 seconds, and DNS corrective updates in
192.42 seconds. This is clean source snapshot
`/tmp/audi-brady-integrated-v7uw6ba3` at `695ee8f`; a final diff confirms that
subsequent branch changes affect only architecture and access-guide documents.

The requirement table above is the final scope audit. Its source links, four
completed application gates and complete native scenario now establish every
listed implementation requirement. The four gates total 1330 passing checks,
including 200 properties; Marshall separately excludes two opt-in cases.
Required contract, compiler, formatter and Dialyzer checks pass. The native
driver also passes generated-script type checking and linting. The separate
native ZFS recovery suite passed in 461.17 seconds as recorded above.

Final inspection confirms that relocation acceptance calls the shared helper
which requires the source ZFS dataset and VM service to be absent and exactly
one disk reservation to remain. The scenario then queries both real DNS nodes,
checks the unchanged strict OpenSSH profile and retained guest marker, verifies
TLS at the original hostname, and rejects forced stale-source HTTP and SSH.
No route readiness or physical progress is fabricated by SQL writes.

Architecture impact: ADR-0047 changes implementation status to implemented;
the accepted ownership, authorization and deployment design is unchanged.
ADR-0037/0052 transfer and local-connector fences remain intact. This completion
does not mark unrelated platform decisions complete, establish arbitrary fault
tolerance, deploy publicly, or restore the user-excluded scale investigation.
The earlier failures remain part of the evidence; two subsequent full passes
establish the tested recovery behavior without claiming a proven kernel or
lock-starvation root cause for the earlier failure.

The final publication also merges upstream `87c50fb`, which moves Dungarees'
administrative OpenSSH and its remote-builder endpoint from port 22 to 2222.
Those two fleet deployment files do not enter this test composition; Audi,
Lilly, Marshall, protocol and native test sources remain identical to the
successful snapshot. The initial non-fast-forward push was rejected safely;
the upstream commit is preserved through an ordinary merge, without force.
