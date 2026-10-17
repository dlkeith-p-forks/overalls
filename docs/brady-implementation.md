# Brady implementation ledger

## Production follow-up, 2026-10-02

The [production egress review](architecture/reviews/2026-10-02-https-egress-production.md)
records passing NixOS/Ubuntu guest trust, HTTPS, redirects, shallow Git clone,
shared public cache and protected/Customer refusal on Overalls before and after
guest stop/start. A new native HTTPS/ZFS scenario verifies full/range recovery
with the origin stopped. The [opt-in workflow](egress-acceptance.md) preserves
fixture ownership, failed requests and exact deployment evidence. These dated
results extend the original acceptance below without expanding its historical
scope to independent hosts or universal recovery.

## Original implementation

Authorized outcome: independent native Elixir OTP HTTP/HTTPS caching proxy on
Lilly hosts. Work is isolated in `feat/brady`, initially based on origin/main
9461cc8742d7bff10b039b953bd0f190711ec160. Preserve other worktrees, run all
applicable gates, integrate concurrent origin/main changes and push normally to
origin/main. Never force-push. CA development on another branch is out of scope;
consume a runtime signing interface and assumed guest trust without searching it.

The [networking and Squid comparison](brady-design.md) explains packet paths,
cache layout and the official upstream references.

## Agreed behavior

- Intercept guest TCP ports 80/443 and configured additional web ports before NAT.
  Other TCP retains existing filtered access. UDP is denied except configured
  public DNS resolvers. QUIC-capable clients fall back to TCP; QUIC-only clients
  fail. Remove HTTP/3 Alt-Svc advertisements. Keep IPv6 denied.
- Fail closed when the proxy is unavailable. Explicit operator TLS exceptions
  may tunnel to the original permitted destination without decryption or cache.
  Never automatically bypass interception after a TLS failure.
- Preserve direct guest isolation and private/protected-address denial for every
  proxy-originated socket. Validate original destination and HTTP/TLS authority.
- Native Elixir implementation under brady/, application :brady, namespace Brady.
  Separate release and systemd lifetime; guest lifetime independent of Brady.
- Share eligible public objects across guests/profiles on one host. Anonymous
  complete successful GET responses only, explicit public freshness; bypass
  credentials, cookies, Set-Cookie, private/no-store and signed URLs. Respect
  variants, age, validators and request cache directives. Large downloads are the
  first workload. Complete cached objects may satisfy valid ranges; uncached
  ranges pass upstream without storage. No partial object publication.
- Dedicated disposable ZFS dataset, no reservations, snapshots or replication.
  Quota min(10% usable pool capacity, 256 GiB); object maximum min(16 GiB, 10%
  quota). Evict at 90% down to 80%. Stop writes below 15% pool free, resume above
  20%, and respect Lilly's existing headroom. Unknown pressure denies writes.
  Pending writes share budget. Cache failure bypasses storage, never the proxy.
- Structured logs identify host, VM, placement, execution epoch and owner at
  request time from authoritative platform metadata. Never trust guest headers
  or stale/reused IP mapping. Mark missing attribution unresolved. Include only
  bounded method/status/cache/bytes/duration/reason values; exclude raw hostnames,
  paths, query strings, signed URLs, headers, bodies, credentials and TLS secrets,
  including dependency and crash diagnostics.

- Integrate Brady with overalls-fleet-monitor, Marshall’s bounded live cache actor,
  durable metric history and administration dashboards. Include service resources,
  request/error rates, cache outcomes and bytes, and cache storage/write pressure.
  Metrics use fixed names and process incarnations, never request or user labels.

## Completion checklist

- [x] Architecture decision, reciprocal supersession, overview/index and review.
- [x] Independent OTP release with runtime configuration and closed logging.
- [x] Bounded transparent TCP accept/HTTP parsing/streaming and TLS interception.
- [x] Runtime CA adapter and certificate lifecycle; verified upstream TLS.
- [x] Explicit TLS tunnel exceptions and protocol/authority validation.
- [x] Cache eligibility, keying, age/validation, variants and complete-object ranges.
- [x] Atomic disk publication, recovery, bounded memory/disk, eviction and pressure.
- [x] Lilly namespace rules, UDP policy, fail-closed behavior and proxy socket policy.
- [x] Authoritative current ownership/placement data from Marshall through Lilly.
- [x] Nix package/service, ZFS provisioning, resource accounting and log collector.
- [x] Fleet collector, strict ingestion, actor/history and admin monitoring panels.
- [x] Unit and property tests for semantics, secrets, accounting and recovery.
- [x] Native NixOS/Firecracker tests for HTTP/TLS, QUIC fallback, isolation,
      attribution, restart, ZFS pressure/quota and cache behavior.
- [x] Full required precommit gates for all changed applications and ADR checker.
- [x] Reconcile final diff/contracts; record actual validation and remaining limits.
- [x] Fetch/integrate latest origin/main, rerun affected gates, commit and push main.

## Acceptance evidence

The final source is integrated with origin/main `f46fb30` (merge `1406e53`). Published remote-builder
and Ubuntu decisions retain IDs 0067 and 0068; Brady is
[ADR-0069](architecture/decisions/0069-brady-egress-cache.md). Recovery stashes,
including `9b80851`, `af8cf68` and `920d149`, are retained. Unrelated worktrees were
not modified. The [architecture review](architecture/reviews/2026-09-18-brady-egress-cache.md)
maps every requirement to source and tested behavior.

| Gate | Completed result |
| --- | --- |
| Protocol precommit | 134 cases, 51 properties, zero Dialyzer errors |
| Lilly precommit | 328 cases, 38 properties, zero Dialyzer errors after the final main merge |
| Brady precommit | 49 cases, 7 properties, zero Dialyzer errors |
| Marshall precommit | 725 cases, 64 properties, two excluded, zero Dialyzer errors |
| Native network | Transparent HTTP/TLS, trust rejection, exact tunnel exception, Customer/protected denial, QUIC fallback, outage denial and secret-free journal |
| Native ZFS | Sibling dataset, public/range hits, restart recovery, secret bypass, stale observer, real quota changes, parent headroom and physical pool 15%/20% hysteresis; 114.69 seconds |
| Complete Firecracker fleet | Exact current VM/owner logs, independent restarts, unchanged legacy command/processes, actual monitoring history and retained-flow refusal after address reuse; 248.82 seconds |
| Governance | ADR links/status and contract structure passed; semantic review is recorded separately |

The native acceptance runs used the Ubuntu-integrated main `8446a41`. The later
Audi recovery integration preserves the tested Brady paths. After that merge,
Lilly’s complete gate, Marshall compilation and forced Dialyzer, and both release
checks passed. Refreshing the devenv evaluation cache was necessary to replace
the pre-merge transfer helper; no source or test assertion changes were needed.

The corrected systemd credential handoff and observer mount flags are covered by
native acceptance. Missing actor evidence remains unresolved during recovery;
fresh requests regain attribution only after current proof is available.
The new occupant's flow resolves to its own user while the old kernel tuple
remains unresolved even though its original label still exists.

Implementation, acceptance and normal Git publication are complete. Commit
`99b977f` was pushed to origin/main and independently verified with `git ls-remote`. CA issuance/trust rollout and production deployment are not
part of this change.
