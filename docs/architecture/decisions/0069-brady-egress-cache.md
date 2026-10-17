# ADR-0069: Brady transparent guest egress cache

- ID: ADR-0069
- Date: 2026-09-18
- Status: superseded
- Implementation: implemented
- Components: Brady, Lilly networking, Marshall attribution and fleet monitoring, NixOS
- Supersedes: ADR-0064
- Superseded by: ADR-0135

## Context

The user authorized a native Elixir per-host HTTP/HTTPS cache, transparent guest
interception, public-only shared caching, QUIC blocking, ZFS storage, secret-free
structured logs with VM/owner attribution, and unit/property/native tests. Guest
trust of a separately developed CA was assumed for the original implementation;
[ADR-0113](0113-guest-trust-at-boot.md) now governs that CA's guest trust path.
Existing guest public
egress bypasses any application proxy.

## Decision

Carry forward ADR-0064 and its inherited requirements except unrestricted public
UDP egress and direct TCP egress on intercepted ports. Brady is an independent
OTP release. Customer egress remains denied, including through Brady; only
egress-enabled profiles are intercepted. Existing private services retain their
dedicated local admission path. Lilly owns privileged networking. Intercept TCP 80/443 and configured
additional web ports before NAT, fail closed on proxy outage, and deny UDP except
DNS to configured public resolvers. Clients may fall back from QUIC to TCP;
QUIC-only applications fail. Other TCP retains existing filtered egress.

Proxy-created sockets must preserve all private/protected-destination and direct
guest isolation rules. Verify original destination, HTTP authority and upstream
TLS identity. Operator-configured exact TLS exceptions may tunnel uncached; TLS
errors never create automatic bypass permission. Remove HTTP/3 advertisements.

Share only complete explicitly public anonymous successful GET responses across
host guests. Bypass credentials, cookies, signed URLs, private/no-store responses
and ambiguous semantics. Preserve freshness, validators and Vary separation.
Stream with bounded buffers; publish only complete objects atomically. Complete
objects may serve ranges; pass uncached range requests upstream without storing.

Use a dedicated disposable dataset on the existing ZFS pool without reservations,
snapshots or replication. Default quota is min(10% usable pool capacity, 256 GiB),
object limit min(16 GiB, 10% quota), eviction at 90% down to 80%. Pause writes below
15% free and resume above 20%, additionally respecting existing Lilly safeguards.
Include in-flight writes in the budget and conservatively deduct them from
physical headroom. Require at least 20% available headroom in the enrolled guest
parent in addition to the physical pool’s 15%/20% hysteresis. Root-produced native
observations must match the boot and the proxy-visible ZFS mount, expire within
three seconds, and constrain cache limits to the observed quota. Lost mount custody
stops only the cache subtree. Unknown pressure denies writes. Cache
failure permits uncached proxy streaming, never direct guest bypass.

Emit only closed structured events with authoritative host, VM, placement, epoch
and owning user at request time. Missing/stale attribution is unresolved, never
inferred from guest headers or a previous IP occupant. Exclude raw hostnames,
URLs, headers, bodies and all secrets from ordinary and crash/dependency logs.
New execution snapshots carry optional owning-user metadata derived from the
authoritative VM record, independently of the requesting administrator. This
metadata grants no execution authority. Upgrade Lilly's protocol decoder before
Marshall starts emitting owner-bearing commands; older strict decoders reject
the additional field. Retain legacy snapshots unchanged and report unresolved
attribution when ownership evidence is absent. Owner metadata alone is not flow
proof: connection attribution must also bind the accepted kernel flow to its
actual execution incarnation, including across guest address reuse.
A strictly newer authenticated command may establish an absent legacy owner.
Once established, newer commands may neither change nor remove that owner. Equal
generation metadata changes still conflict; stale ownerless deliveries retain
the newer owned command. This enables normal lifecycle upgrades without rewriting
historical snapshots or treating legacy absence as an owning user.
For already-running legacy commands, a separate authenticated version-3 metadata
endpoint returns at most sixteen exact host/session/VM/placement/epoch/generation
owner bindings. It cannot issue commands or mutate snapshots. Lilly refreshes
these round-robin outside Runtime into protected volatile storage (8192 rows,
five-minute expiry). Exact durable owner metadata takes precedence; cache loss,
expiry, missing bindings or API failure remain unresolved. Metadata lookup never
replaces the actor and kernel-flow proofs.
Lilly assigns a 128-bit conntrack label derived from host, placement, epoch and
launch generation on the first unconfirmed original TCP SYN from the validated
guest TAP. Existing labels and confirmed connections are never retagged. This
rule follows the source/MAC guard and conntrack association, precedes TPROXY, and
grants no traffic admission. Brady captures the complete accepted socket tuple
before reading guest bytes and retains one attribution result for the connection.
The privileged lookup must match the kernel label to current physical execution
and authoritative owner evidence; label presence alone is insufficient.
Adoption of an already-running guest may refresh this label table only after
verifying its physical confinement and existing host/guest/TAP claims under the
VM and network locks. Recheck confinement afterward. This must not restart the
guest, change addresses/routes or retag existing connections. A versioned root-
owned table marker and expected chain/rule shape avoid redundant reloads; only
Lilly and trusted root operators may mutate these owned tables.
Use a non-setuid native helper linked against pinned libnetfilter_conntrack for
one exact original IPv4 TCP tuple GET in Lilly's namespace. It cannot mutate or
dump connection state and emits only one fixed-size label after matching the
returned tuple. Missing labels, ambiguous results and deadlines remain
unresolved. Lilly supplies privileges; Brady receives no conntrack capabilities.
Expose that join through `/run/lilly-brady/attribution.sock`, under a root-owned
directory traversable by the Brady group. Lilly authenticates the configured
Brady UID using Linux peer credentials before parsing; Brady authenticates UID 0
and its configured host in the response. The pure shared protocol library owns
the independent version-1 fixed-size tuple/identity encoding, with two-byte length
framing and a 256-byte limit. At most 128 server workers may exist, each with an
independent two-second kill deadline. Client connect/send/read deadlines remain
bounded. No paths, headers, bodies or names cross this endpoint. Failure returns
unresolved attribution and cannot authorize direct guest egress.

Brady participates in the existing independent overalls-fleet-monitor collector,
Marshall live cache actor, durable metric history and administrator dashboards
from ADR-0060/0062. Export fixed aggregate counters and cache pressure gauges via
a private atomic snapshot. Require current systemd invocation and fresh snapshot;
use a new counter incarnation on producer restart. Missing metrics remain unknown.
Do not export request paths, authorities, owners or other per-request labels.
Monitoring remains outside admission and cannot authorize cache writes. Deploy
Marshall’s expanded strict ingestion schema before enabling Brady collectors;
older Marshall instances reject the new kind/role rather than silently discarding
fields. Existing collectors remain compatible. Enrolled host roles must include
Brady for intended-role filtering; observed roles continue to come from samples.

## Alternatives

The [networking and Squid comparison](../../services/brady-design.md) records the upstream
cache layout, freshness and TLS references alongside the chosen implementation.

Squid managed by OTP was rejected in favor of native Elixir. Per-guest caches lose
public artifact reuse. Unrestricted UDP permits QUIC bypass; UDP-443-only blocking
misses alternative ports. Automatic TLS bypass undermines mandatory interception.
Unbounded cache storage competes with guest disks. A quota alone cannot protect
shared-pool headroom as other datasets grow.

## Consequences

Brady adds an intentional trusted TLS termination boundary and a web availability
dependency without controlling guest process lifetime. Some pinned/mutual-TLS
applications require explicit exceptions. Sharing public content introduces cache
hit timing visibility. Resource/pressure accounting and ownership distribution
must be integrated; a scaffold is not evidence of operational interception.

## Invariants and verification

Unit/property tests cover eligibility, variants, freshness, redaction, resource
bounds, crashes and recovery. Real NixOS Firecracker tests must establish TLS
interception, upstream validation, QUIC fallback, direct isolation, owner binding,
fail-closed restarts and ZFS quota/pressure behavior. Full changed-project gates
and the ADR checker precede publication. Independent-host claims require separate
evidence and cannot follow from mocked networking.

## Implementation evidence

The [2026-10-02 production review](../reviews/2026-10-02-https-egress-production.md)
records actual NixOS and Ubuntu guest HTTPS, signer-chain verification, redirects,
shallow Git clone, shared public cache hits, current owner/generation attribution,
protected-address and Customer refusal before and after stop/start on Overalls.
It also records native HTTPS/ZFS full/range recovery with the origin stopped.
Single-host acceptance and the retained failed Ubuntu provisioning request do
not establish independent-host or universal recovery behavior.

The independent [OTP application](../../../brady/lib/brady/application.ex),
[HTTP proxy](../../../brady/lib/brady/proxy.ex),
[TLS adapter](../../../brady/lib/brady/tls/certificates.ex), and
[closed formatter](../../../brady/lib/brady/log.ex) implement the serving path.
The adapter validates matching runtime CA material; the Nix module copies
systemd-delivered credentials into private `0400` runtime files before startup.
The fleet CA custody was implemented under ADR-0109; ADR-0113 replaces its
image-baked guest trust path with boot delivery. Native activation still
requires separate evidence.
[Cache policy](../../../brady/lib/brady/cache/policy.ex),
[budget arithmetic](../../../brady/lib/brady/cache/budget.ex),
[disk storage](../../../brady/lib/brady/cache/store.ex) and
[independent recovery](../../../brady/lib/brady/cache/recovery.ex) provide bounded
public-only storage and uncached streaming on cache failure.

The packaged [native network check](../../../nix/verification/tests/machines/brady-network/driver.py)
passed transparent HTTP/TLS, upstream trust rejection, explicit TLS tunneling,
Customer/protected destination denial, fail-closed proxy outage, actual HTTP3
fallback after UDP rejection, and secret-free journal assertions. It exercises
Lilly's generated nftables rules, routing and a Brady process restricted to
`CAP_NET_RAW`; veth peers stand in for guests. It does not establish Firecracker
identity or lifecycle acceptance.

The [native ZFS check](../../../nix/verification/tests/machines/brady-network/storage.py) passed
separate-dataset preparation, complete-object/range hits with the origin stopped,
restart recovery, credential/cookie/query bypass, stale-observer fallback,
quota shrink/restore, guest-parent headroom eviction/recovery, and physical pool
15% stop / 20% resume hysteresis. The root
[storage helper](../../../nix/domains/system/brady/storage.py) uses enrolled GUIDs and
read-only native pressure observations. The
[module](../../../nix/domains/system/brady/default.nix) preserves actual parent/cache
mount write flags inside the observer sandbox: `ProtectSystem=strict` otherwise
appeared to ZFS as a host readonly-policy change. Configuration assertions and
the sandboxed native check cover this integration. Unit tests additionally cover
proof expiry, boot/mount changes and bounded pending reservations.

[Command snapshots](../../../marshall/lib/marshall/compute/command_snapshot.ex)
derive owner metadata from the VM record. The
[execution decoder](../../../protocol/lib/overalls_protocol/execution.ex) and
[durable store](../../../lilly/lib/lilly/control/store.ex) retain legacy command
compatibility and reject conflicting same-generation metadata. Legacy owners are
refreshed separately through the
closed batch codec (`protocol/lib/overalls_protocol/egress_owners.ex` at overalls revision `9fe1e493`, repository deleted),
[authenticated read-only API](../../../marshall/lib/marshall/compute/provisioner_control.ex),
[bound HTTPS client](../../../lilly/lib/lilly/control/client.ex) and
volatile cache (`lilly/lib/lilly/network/owner_cache.ex` at overalls revision `9fe1e493`, repository deleted).
Component tests cover host/session fencing, exact binding, expiry and absence of
execution-intent mutation.

[Lilly flow labels](../../../lilly/lib/lilly/network/flow_label.ex), the
[native exact-tuple helper](../../../lilly/native/flow-label/src/lib.rs),
[execution view](../../../lilly/lib/lilly/execution.ex) (flow routing; ADR-0140 replaced the runtime index and actor snapshot calls with lock-free view reads),
[current actor proof](../../../lilly/lib/lilly/vm/actor.ex), and
[resolver](../../../lilly/lib/lilly/network/attribution.ex) join kernel flows to
current execution authority. The packaged
[native helper check](../../../nix/verification/tests/machines/brady-flow/default.nix) passed
label bit order, existing-flow retention after rule changes, and unlabeled-flow
refusal. The Rust port of that helper (3b38f5e0) passed host-order IPv4 integers
to conntrack, so on x86 every exact GET queried a byte-reversed address and all
native Brady requests logged `attribution: "unresolved"`; `brady-flow` failed
until the 2026-10-02 fix restored inet_pton's network-order layout, now pinned by
the `flow-selector-wire-layout` property. The [local server](../../../lilly/lib/lilly/network/attribution_server.ex)
and [client](../../../brady/lib/brady/attribution.ex) authenticate kernel UIDs and
use a closed bounded wire format. Socket and actor/index tests establish component
behavior; the complete Firecracker scenario additionally proves current
VM/owner attribution, legacy refresh, restart survival and old-flow refusal
after IP reassignment to a different owner.

The [aggregate producer](../../../brady/lib/brady/metrics.ex),
collector (`nix/domains/system/fleet-monitor/runtime.py` at overalls revision `a99f74f0`, repository deleted),
ingestion schema (`marshall/lib/marshall/fleet/sample.ex` at overalls revision `a99f74f0`, repository deleted) and
panel catalog (`marshall/lib/marshall/fleet/dashboard_catalog.ex` at overalls revision `a99f74f0`, repository deleted) extend
the existing collector, actor, durable history and administration dashboards.
Tests cover incarnation/freshness, missing-data rate gaps, unknown versus zero,
secret-field rejection and database/dashboard behavior. Real collector-to-history
acceptance passed in the complete fleet run; no deployment is claimed.

Complete application gates passed after integration of main `8446a41`: protocol
134 cases (51 properties), Lilly 323 (37 properties), Brady 49 (7 properties),
Marshall 725 (64 properties, two excluded), all with zero Dialyzer errors.
The complete [Firecracker fleet scenario](../../../nix/verification/tests/machines/fleet/scenarios/brady.py)
passed in 248.82 seconds with the shared NixOS/Ubuntu guest networking. Native
ZFS quota/headroom/hysteresis acceptance passed in 114.69 seconds. ADR/contracts
and configuration checks provide complementary structural evidence.
After the Audi recovery integration (`f46fb30`, merge `1406e53`), Lilly’s full gate
passed 328 cases (38 properties), Marshall compilation and forced Dialyzer passed,
and Lilly/Brady release checks passed. Native acceptance above remains scoped to
`8446a41`; the later transfer-only changes preserve those Brady paths.
Published remote-builder and Ubuntu records retain IDs 0067 and 0068; this
decision was assigned the next free ID, 0069, during integration.
The [implementation ledger](../../history/ledgers/brady-implementation.md) and
[review](../reviews/2026-09-18-brady-egress-cache.md) record scope and validation.

The [cache history verification](../reviews/2026-09-26-cache-history-verification.md)
adds generated real Cache/Store publication, privacy, process ownership, expiry,
pressure and restart histories with an independent public-byte model. It also
reconciles the admission predicate's source note with this decision's existing
complete-object range reuse. Production behavior and decision status are
unchanged; new component results and historical native executions retain their
separate source and environmental scopes.

### 2026-09-28 production correction: HTTPS origin verification

Production acceptance of [ADR-0128](0128-repository-launch-links.md) showed guest
HTTPS to rotating names (github.com) failing intermittently: Brady required the
TLS SNI to resolve to the dialled IP in Brady's own DNS view, but guests and Brady
use different public resolvers and receive different addresses. For intercepted
HTTPS the decision's "verify original destination ... and upstream TLS identity"
is satisfied by pinning the original IP and verifying the upstream certificate
for the SNI host there, so
[Destination.acceptable?](../../../brady/lib/brady/destination.ex) no longer
requires DNS agreement for HTTPS. Plain HTTP authority and operator TLS-exception
tunnels (never TLS-verified by Brady) still require the hostname to resolve to
the original destination. Evidence:
[destination properties](../../../brady/test/brady/destination_test.exs). The same
acceptance found Lilly's router namespace inheriting the host's
`src_valid_mark=1` (Tailscale exit nodes), which dropped every intercepted SYN;
[Lilly now pins it to 0](../../../lilly/lib/lilly/network.ex).

The [generated startup properties](../../../brady/test/brady/invalid_boot_property_test.exs)
distinguish invalid schema refusal before supervision from invalid signer
material failing the first supervised child before cache or listener startup.
The [property review](../reviews/2026-09-29-antithesis-property-audit.md) records
local test-build evidence, private fixture custody and the Metrics-only unset
control. These checks do not replace native interception, guest trust or ZFS
acceptance; the existing runtime signer and secret-custody decisions are unchanged.

## Open questions

No unresolved implementation or product-policy decision remains in this scope.
The original Brady implementation did not inspect CA work on another branch.
ADR-0109 supplies runtime signers, while ADR-0113 governs public guest trust. Production
deployment and throughput benchmarking remain separate acceptance claims.

## Related decisions

[ADR-0109](0109-brady-fleet-ca.md) supplies the fleet signing hierarchy;
[ADR-0113](0113-guest-trust-at-boot.md) supplies the boot-time guest trust path.

[ADR-0054](0054-inception-development-profile.md),
[ADR-0031](0031-sparse-zfs-storage-and-capacity.md),
[ADR-0052 capacity](0050-usage-based-overcommit.md),
[ADR-0009](0009-assurance-and-testing.md).

[ADR-0064](0064-customer-workspace-isolation.md) supplies the retained Customer isolation policy.

[ADR-0135](0135-streaming-public-artifact-cache.md) carries forward this rationale
and boundaries while adding decoded chunked publication and built-in public
commit-pinned GitHub archive policy. Historical evidence above retains its scope.
