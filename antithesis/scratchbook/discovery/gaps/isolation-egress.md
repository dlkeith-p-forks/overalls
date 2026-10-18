---
sut_path: /home/ghuntley/src/overalls-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
---

# G2: physical isolation and egress authority

This targeted discovery fills coverage-balance finding 2. It proposes six independent canonical candidates for catalog synthesis. They are source-grounded hypotheses about requirements, not confirmed defects, implemented SDK assertions, or passing executions. The current catalog's `stale-local-execution-cannot-forward-guest-bytes` checks an ingress stream fence, `brady-cache-complete-publication` checks object completeness, and `brady-cache-physical-headroom-and-leases` checks space pressure. None supplies the oracles below. The fresh `existing-assertions.md` scan reports no implemented SDK assertions. No retired harness/history, outside reference, test, build, remote system, or source mutation was used.

| Candidate and evidence | Priority; primary literal SDK assertion | Distinct oracle and topology |
| --- | --- | --- |
| [native-firecracker-confinement-survives-owner-recovery](isolation-egress/native-firecracker-confinement-survives-owner-recovery.md) | P0; `Always`: **"Current Firecracker execution retains its jail UID namespace and cgroup confinement"** | Root-owned `/proc`, systemd/cgroup and jailed API observations of the actual VMM, correlated with current intent; native KVM only. |
| [native-guest-packets-obey-profile-and-tap-boundaries](isolation-egress/native-guest-packets-obey-profile-and-tap-boundaries.md) | P0; `Always`: **"Physical guest packets cannot cross forbidden profile TAP or destination boundaries"** | Independent live peer/origin listeners plus kernel TAP/forward counters; native KVM for guest-origin claim. |
| [brady-flow-attribution-requires-current-incarnation](isolation-egress/brady-flow-attribution-requires-current-incarnation.md) | P0; `Always`: **"Brady resolves flow ownership only for the current labeled execution incarnation"** | Exact conntrack tuple/label, physical boot and owner ledger, closed Brady event; native KVM for full identity claim. |
| [brady-sensitive-exchanges-never-reuse-shared-cache](isolation-egress/brady-sensitive-exchanges-never-reuse-shared-cache.md) | P0; `Always`: **"Credentialed requests never reuse and private responses never enter Brady shared cache"** | Synthetic origin request counts and per-request content nonces, plus cache object inventory; TCG ZFS/router useful, native Firecracker separately. |
| [brady-forbidden-destinations-never-reach-upstream](isolation-egress/brady-forbidden-destinations-never-reach-upstream.md) | P0; `Always`: **"Forbidden original destinations never reach Brady upstream or shared cache"** | Kernel original destination, independent forbidden listener and cache inventory; TCG router proves Linux path only. |
| [brady-proxy-loss-preserves-web-and-quic-denial](isolation-egress/brady-proxy-loss-preserves-web-and-quic-denial.md) | P0; `Always`: **"Proxy loss never opens direct guest web or QUIC egress"** | Origin packet/effect ledger and nftables counters while Brady is absent; TCG router, then native guest campaign. |

## Proof boundaries and relationship

`storage-router` in `deployment-topology.md:94-96,147-174` can run real ZFS, nftables, TPROXY and Brady under a TCG Linux VM. It cannot establish actual Firecracker jail, UID, cgroup or physical guest identity. `native-kvm` is a separately executed campaign, not a Compose claim; one physical sample-host host still cannot establish independent hardware failure domains. `brady-network` uses veth stand-ins (`nix/verification/tests/machines/brady-network/driver.py:30-50`) and can prove policy mechanics, while fleet `network.exs:52-66,93-128,158-179` sends probes from real guests. Existing native test source and historical ADR results are design leads; exact current revision/derivation execution receipts remain pending.

The candidates use different adverse effects: an unconstrained VMM, a delivered forbidden packet, a misattributed connection, private bytes reused from cache, a forbidden upstream connect, or a direct route during proxy loss. They should not be merged into a generic “isolation holds” assertion. `brady-flow-attribution-*` concerns attribution metadata; unresolved attribution may still proxy a public request, so it does not imply network denial. `brady-sensitive-*` concerns response sharing; it does not duplicate complete-object publication. No ordinary diagnostic should contain request headers, URLs, bodies, credentials, or raw payload; fixtures use synthetic nonces in a private oracle ledger.

## Investigation log

- Read `AGENTS.md`, `lilly/AGENTS.md`, root/Lilly/network/Brady `CONTRACTS`, the architecture overview and ADR index; ADR-0064, ADR-0069 and ADR-0135; Antithesis research catalog/claim-validation guidance; `sut-analysis.md`, `deployment-topology.md`, current catalog, and `evaluation/coverage-balance.md`.
- Traced primary code and test paths cited in each evidence file. They establish implementation shape and existing fixture design; they do not independently reproduce a defect. In particular, source checks of `/proc` in `Lilly.VM.Observation` and generated nftables rules are claims until a real guest and packet oracle run.
- Open feasibility is concentrated in native KVM availability and a safe workload-owned monitor that correlates post-fault PID/cgroup and exact flow label to current intent without relying on SUT-generated success logs. The native campaign inventory records prerequisites and unresolved current execution separately.

Architecture/HLDD impact of this research-only addition: none; no design decision, documented service behavior, configuration, implementation or verification result changed. Final diff review should retain that boundary.
