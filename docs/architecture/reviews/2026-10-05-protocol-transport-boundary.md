# Protocol transport boundary reconciliation

## Scope and architecture impact

Integration of origin edee0815 into cd8ba8d3. Reviewed accepted ADR-0142,
Protocol/ancestor contracts and guidance, Connection socket operations, Client
credential callbacks and pending request handling, Galileo integration, codecs
and volatile View/Cadence primitives. Self-review only. This corrects guidance
against an explicit existing accepted transport decision; no new production
behavior or domain/resource/service is introduced.

## Finding and correction

Protocol CONTRACTS and AGENTS prohibited all host I/O, while ADR-0142 explicitly
placed Connection and Client socket transport in Protocol. The architecture
overview and handbook reference chapter repeated the old blanket purity claim.
The correction preserves codec/state/View/Cadence purity and limits socket
transport to the two named modules. Applications provide credential callbacks
and TLS trust. Ash, database access, host mutation and durable credential storage
remain outside Protocol. Existing contract IDs are preserved; no unrelated
constraint is removed. Transport fixtures may use owned nonprivileged loopback
and disposable TLS while codec/value tests retain their pure boundary.

ADR-0142 remains accepted/partial and its original migration rationale and native
fleet gaps remain. ADR-0012/0140 retain pure validation/state requirements.
The overview, ADR index and handbook01/02/17 now distinguish these boundaries.
No placement, domain ownership, options or authority changes need new diagrams.

## Recorded integration verification

Before this documentation/contract correction, full integrated gates passed:
Protocol245checks (93properties,152tests),seed861061,4.1seconds;
Lilly505checks (94properties,411tests),seed709815,140.4seconds;
Galileo31checks (11properties,20tests),seed734392,96.0seconds;
Marshall1465checks (239properties,1226tests),two exclusions,seed152050,
1591.6seconds. All forced Dialyzer gates passed with zero errors, skips or
unnecessary skips; Marshall40.37seconds. Log:
`/tmp/overalls-control-main-integrated-component-gates.log`.
Those results cover unchanged production/test source. This correction still
requires structural contracts/ADR/HLDD, all-file hooks and evaluated handbook
checks before commit. It does not establish native rollout or close the separate
first-envelope, pending-batch, heartbeat timer and terminal-retry review gaps.
Their new properties remain in the control review worktree and are not imported
as passing tests here.
