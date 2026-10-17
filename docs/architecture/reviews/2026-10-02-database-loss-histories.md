# Database client-loss history verification

## Scope and architecture impact

Verification expansion under ADR-0126: actual source-built Marshall release
Repo, verified PostgreSQL TLS, one row-lock holder, three observed waiters and
ten captured connections. Production settings and the independent twenty-second
holder/thirty-five-second total reclamation bounds are unchanged. A healthy
twenty-second query and post-loss row reacquisition remain mandatory.

The six native cases combine idle/active holders with machine crash, silent
bidirectional loss and asymmetric client-to-server loss. Active holders retain
the acquired row during a real ninety-second server statement. Link faults
freeze client userspace while retaining live kernel sockets; server-side DROP
rules never send resets. Validated counters must establish exercised loss.
Seed 126 permutes the six distinct waiter submission orders across the cases.
Submission order does not establish queue order; the server must independently
observe all three active blocked statements before the fault.

## Recorded execution

Initial active-holder machine-crash capture
`1790971761080-1137410-0.jsonl` passed in 60.51 seconds, with all ten connections
reclaimed in 19.518 seconds and successful subsequent row acquisition. Command:
`nix build .#checks.x86_64-linux.database-recovery-active --no-link`.
This capture predates final formatting, failure-only holder diagnostics, DROP
counters and seeded submission orders. It proves the initial active-holder
variant only, not final matrix execution.

Ruff formatting/lint, ty and structural contract checks passed for the DROP
counter extension. Machine driver type checking additionally runs against the
Nix-composed driver. Fresh source review found no initial active-holder blocker;
matrix review and execution remain pending. Failure diagnostics omit statements
and credentials and cannot extend deadlines or convert a failed bound into a
pass.

Matrix review found an observer-address bug before final execution:
`inet_client_addr()` returned the local psql observer's address, not the holder
row's peer. The fixture now selects `pg_stat_activity.client_addr::text` for the
captured holder PID, then validates IPv4 before forming firewall syntax. The
already running first silent capture predates this correction and cannot verify
the final matrix. No fault or recovery result is inferred from that capture.

The first silent capture (`1790972141045-1389243-0.jsonl`) terminated with the
expected empty-address validation failure before packet fault injection. It
does not establish a recovery failure. The corrected six-case matrix is now
running with `--max-jobs 1 --keep-going`, preserving serial VM execution and
recording every case even if one fails. No final matrix result is claimed yet.

The first case of capture `1790972547094-1655251-0.jsonl` (active/asymmetric)
also stopped before fault injection: PostgreSQL's inet-to-text cast yielded
`192.168.1.2/32`, which correctly failed the bare-address validator. The driver
now selects `host(client_addr)` and retains IPv4 validation. The running matrix
predates this correction; its link cases cannot establish recovery behavior.

That matrix is now terminal failed: all four link-loss cases stopped at the
inet text/address-format mismatch before injection. The corrected capture runs
all six cases again with `host(client_addr)`, serial VM jobs and unchanged
deadlines. Combined all-file hooks, contract syntax, Ruff, ty and ADR checks
passed before this execution. Final native outcomes remain pending.

Capture `1790973269234-2111001-0.jsonl` reached the verified active/asymmetric
holder and queue, but nftables rejected the missing statement separator after
the chain declaration (lines 4097–4106). This is another pre-injection fixture
failure, not a reclamation result. Chain declarations now end with newlines;
the captured matrix retains the old syntax. It is now terminal failed: all four
link cases stopped before injection, while active/crash passed in 64.32 seconds
(all sessions reclaimed in 19.405 seconds) and idle/crash passed in 69.51 seconds
(all sessions reclaimed in 27.866 seconds). Both retained the independent holder
deadline and subsequent row reacquisition. The newline repair passed pinned
nftables `--check` for both rulesets in an isolated user/network namespace.
All-file hooks, Ruff, ty, ADR, generated reference/coverage and source view
checks passed after reviewed receipts. The complete corrected matrix is rerun
with unchanged bounds; no link-loss recovery outcome has yet been verified.

## Final matrix execution

The final six-case matrix passed in capture
`1790973915375-2537070-0.jsonl` (terminal success, shell exit zero).
All six cases preserved the twenty-second holder and thirty-five-second
all-connection assertions and reacquired the row after reclamation.

| Holder | Fault | Test seconds | All sessions reclaimed, seconds | Observed DROP packets |
| --- | --- | ---: | ---: | --- |
| Active | Asymmetric | 62.70 | 19.770 | Inbound 10 |
| Active | Bidirectional silent | 62.63 | 19.432 | Outbound 20 |
| Active | Crash | 62.08 | 19.527 | Not applicable |
| Idle | Asymmetric | 70.53 | 27.747 | Inbound 25 |
| Idle | Bidirectional silent | 73.38 | 27.518 | Outbound 35 |
| Idle | Crash | 71.92 | 27.882 | Not applicable |

Executed command: `nix build --max-jobs 1 --keep-going --no-link`
with all six `checks.x86_64-linux.database-recovery` variants (base,
`-active`, `-silent`, `-asymmetric`, `-active-silent`, `-active-asymmetric`).
The captured release uses the `ad999a42` base plus this verification expansion.
Later evidence/documentation updates do not change its exercised Repo parameters
or fixture executable inputs. Fresh source review found no remaining blocker;
the runtime nft syntax finding is corrected and retained above.

## Remaining coverage

An independent surviving release
contender, repeated generated loss/reconnect histories, uncertain commit replay
and hosted Antithesis execution remain separate. A local SQL observer reacquiring
the row cannot establish application-pool reconnection or admission completion.
