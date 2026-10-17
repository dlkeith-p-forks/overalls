# Brady egress cache architecture review

Scope: the complete Brady change in the isolated `feat/brady` worktree, integrated
with origin/main `f46fb30` (merge `1406e53`). The user authorized native OTP interception, safe
shared caching, QUIC fallback, ZFS storage, secret-free VM/owner-attributed logs,
fleet monitoring, tests, ADRs, and a normal push to main. No separate CA branch
was inspected. [ADR-0069](../decisions/0069-brady-egress-cache.md) preserves the
Customer isolation policy while replacing unrestricted egress on intercepted
web ports and unrestricted public UDP.

## Requirement audit

| Requirement | Implementation and decisive evidence |
| --- | --- |
| Independent OTP proxy per Lilly | [Application](../../../brady/lib/brady/application.ex), [module](../../../nix/domains/system/brady/default.nix); source-built release and both real fleet services start with separate lifetimes. |
| Transparent HTTP/HTTPS and verified upstream | [Proxy](../../../brady/lib/brady/proxy.ex), [TLS](../../../brady/lib/brady/tls.ex); packaged namespace tests and actual Firecracker HTTP/HTTPS requests pass. Upstream trust rejection and explicit uncached exceptions pass. |
| QUIC fallback and fail-closed networking | [Policy](../../../lilly/lib/lilly/network/policy.ex); native HTTP3-capable curl falls back after a measured UDP rejection. Customer/protected denial, stripped Alt-Svc and proxy-outage denial pass. |
| Cache only eligible public responses | [Policy](../../../brady/lib/brady/cache/policy.ex); unit/properties and native credential/cookie/query bypass, public hits with stopped origin, complete-object ranges and restart recovery pass. |
| Bounded atomic ZFS storage | [Store](../../../brady/lib/brady/cache/store.ex), [observer](../../../nix/domains/system/brady/storage.py); native sibling dataset, quota shrink/restore, guest-parent eviction/recovery and physical pool 15%/20% hysteresis pass. Unit tests cover pending leases, incomplete publication, reader pins and custody loss. |
| Secret-free structured logs | [Formatter](../../../brady/lib/brady/log.ex); properties discard arbitrary fields/reports. Native journals exclude synthetic signed-query/authentication values, hostnames and bodies. |
| Authoritative current VM/owner | [Resolver](../../../lilly/lib/lilly/network/attribution.ex); real guest events match host, VM, placement, epoch, generation and owner. Kernel UID authentication, bounded protocol and fresh actor checks are exercised. |
| Legacy guests and restart survival | Owner cache (`lilly/lib/lilly/network/owner_cache.ex` at kittens revision `9fe1e493`, repository deleted); fleet tests refresh an owner-less command without changing its hash or guest process identities. Brady/Lilly restarts preserve the guest and fresh requests regain proved attribution. |
| No stale owner after address reuse | [Fleet scenario](../../../nix/verification/tests/machines/fleet/scenarios/brady.py); a retained old TCP label survives confirmed deletion and IP reassignment. The new flow resolves to a different VM/owner; the old exact tuple remains unresolved. |
| Existing custom monitoring and administration | Collector (`nix/domains/system/fleet-monitor/runtime.py` at kittens revision `a99f74f0`, repository deleted), dashboard catalog (`marshall/lib/marshall/fleet/dashboard_catalog.ex` at kittens revision `a99f74f0`, repository deleted); the actual collector sends Brady observations through the fleet actor into durable history. Unit/database/dashboard tests cover rates, incarnation resets, unknown values and secret rejection. |
| Architecture and contract maintenance | ADR-0069 supersedes ADR-0064 with reciprocal links; ADR-0060/0062 record the monitoring extension. The overview/index and local contracts match the implementation. ADR-0047 records the publication-query plan correction verified by Marshall's scale test. |
| Preserve concurrent work and publish safely | Main integrations retain Customer, Ziggy, remote-builder and Ubuntu work. Recovery stashes are retained; no resets discard local source and no force push is authorized. Normal push of `99b977f` to origin/main was verified with `git ls-remote`. |

## Completed validation

All four full `mix precommit` gates passed with the pinned Elixir 1.20.4 /
OTP 29.0.6 runtime: protocol 134 cases (51 properties), Lilly 323 (37 properties),
Brady 49 (7 properties), Marshall 725 (64 properties; two excluded). Forced
Dialyzer checks reported zero errors. Structural contract and ADR checks passed;
they are not substitutes for the runtime evidence below.

The native [network check](../../../nix/verification/tests/machines/brady-network/driver.py)
uses the packaged proxy, generated Lilly policy, real sockets and only
`CAP_NET_RAW`. The [ZFS extension](../../../nix/verification/tests/machines/brady-network/storage.py)
passed actual publication, quota/headroom changes and hysteresis in 114.69 seconds.
These checks use veth peers and establish their stated kernel/storage scope.

The complete [Firecracker fleet scenario](../../../nix/verification/tests/machines/fleet/scenarios/brady.py)
passed in 248.82 seconds on the Ubuntu-integrated source. It uses three Marshall
nodes, the real database, authenticated Lilly/Ziggy enrollment, two provisioners,
actual Firecracker guests and production Brady/monitor services. It proves the
VM/owner, restart, legacy refresh, history and retained-flow claims above.
The source-built release, configuration, storage-custody and collector checks
provide complementary component evidence.

The subsequent Audi recovery merge changes transfer imports and their closed
errors, preserving Brady’s attach/adopt attribution paths. Pool locking retains
a single attempt by default; optional retries occur only before ownership and
never replay callbacks. Post-merge validation passed Lilly’s full gate (328 cases,
38 properties), Marshall compilation and forced Dialyzer, and Lilly/Brady release
checks. The native acceptance above remains scoped to main `8446a41`; those tested
Brady paths are unchanged by this integration. No architectural decision changed.

## Findings resolved

- The development shell initially reused the pre-merge native transfer helper,
  producing two error-classification test failures. Refreshing devenv’s evaluation
  cache selected the current packaged helper and all 328 Lilly cases passed.
- The pressure service's read-only sandbox changed the ZFS mount flags visible
  to inspection. Explicit parent/cache `ReadWritePaths` preserve native flags;
  the observer still issues only read-only ZFS queries. Sandboxed native tests
  verify pressure admission and recovery.
- Systemd supplied signing credentials as `0440`, conflicting with the adapter's
  strict private-file check. The service now copies credentials to its private
  runtime directory as `0400`, following the existing Ziggy pattern. Native TLS
  and the full fleet test verify that handoff without weakening key custody.
- Restart tests now require new attributed requests after actor recovery; they
  cannot pass using old journal records or require a frozen unresolved request
  to change identity retroactively.
- Lilly's endpoint log tests captured unrelated concurrent transfer diagnostics.
  Serializing that module preserves its silence/secret assertions and passes the
  complete suite. The host-usage test uses its measured sampling interval.
- Marshall's existing 10,000-endpoint publication check exposed a stale-statistics
  query-plan regression. Materializing the current-publication set preserves the
  same single-statement authority and time bound; the full suite passes.

No implementation finding remains open within this scope. Runtime CA issuance
and guest trust rollout are explicit external assumptions; the separate CA work
was not inspected. This review establishes implementation and test acceptance,
not a production deployment or a fleet throughput benchmark.
