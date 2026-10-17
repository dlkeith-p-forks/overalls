# Retry proof binding histories

## Architecture impact

Baseline `10c07e050bab4bc9ead8a50eb248fd2f2c018da5`. Verification-only changes
preserve ADR-0037 relocation authority and ADR-0133 accounting. No domain,
protocol, persistence, capacity or recovery decision changes. Native guest and
committed multi-instance acceptance remain separate from rollback sandbox tests.

## Generated histories and independent oracles

[Retry properties](../../../marshall/test/marshall/compute/retry_measurement_window_history_test.exs)
now add three properties to the existing received-window history.

Binding histories submit protocol-valid wrong operation, VM, placement, epoch,
generation, authenticated host and readiness descriptor through real actions.
Every refusal preserves complete authority, physical/audit, host and accounting
inventories. The original failed readiness receipt is instead acknowledged by
its historical ID without satisfying the newer retry. Matching current running
and offered readiness evidence then finish exactly once. Expected completion,
duration and bucket placement come independently from retained proof timestamps.

Historical histories deliver valid delayed running proofs for the original source
provision or destination activation. Those exact older operations are accepted
and retained inside the newer measurement window without changing current intent.
Pending scans cannot use them to finish the newer retry. After current running
and readiness, another older-operation receipt arrives with a later timestamp;
the measurement must still use current proof times. A further historical receipt
after terminalization adds exactly its physical row and cannot rewrite accounting.
No malformed retained evidence is fabricated with SQL.

The crossing property uses setup-only sandbox admission backdating to leave about
five seconds of the configured 600-second window. Missing-both/physical-only
witnesses remain pending on repeated scans. A bounded timer waits for PostgreSQL
`clock_timestamp()` to cross the unchanged deadline, then exactly one failure
records 600-second duration and the inclusive upper-bound bucket. This establishes
local database-clock crossing after setup backdating, not a ten-minute native
retry or physical recovery run. Execution confirms the five-second margin in the
recorded focused run; heavily delayed scheduling can exhaust that setup margin.

Fresh review repaired three oracle gaps: initial reconciliation now compares
inventories captured before it; historical pending scans compare unrelated
accounting and the complete attempt except `checked_at`; subsequent old receipts
check exact physical-row deltas, unchanged lifecycle events and accounting. First
terminal scans compare authority, proofs and unrelated accounting before/after.
Repeated terminal scans compare complete measurements and totals.

## Verification

The initial four-property run passed seed355749 in89.6seconds before the final
conservation repairs. It does not establish those later assertions.
The reviewed combined run passed four properties, seed `158289`, in 91.9 seconds,
with warnings-as-errors and terminal exit0. Log:
`/tmp/kittens-retry-binding-histories-reviewed-focused.log`.
The fresh reviewer found no further concrete defect in this scope.
Full Marshall precommit passed 1,422 checks (221 properties, 1,201 tests), two exclusions, seed930025,1133.1seconds; forced Dialyzer42.96seconds with zero errors, skips or unnecessary skips; terminal exit0.
Log: `/tmp/kittens-retry-binding-histories-full-gates.log`.
All-file hooks, generated-reference checks and evaluated Nix HLDD passed in that
command. Final evidence-record publication checks also passed with terminal
exit0: all-file hooks, ADR/HLDD/generated-reference checks and evaluated Nix HLDD.
Publication log: `/tmp/kittens-retry-binding-publication-gates.log`.
The previous 1,419-check result belongs to baseline10c07e05 and excludes these
three additions.

## Remaining scope

Wrong retained VM/placement/epoch/host bindings for one immutable operation are
rejected at ingestion; ordinary readiness cannot manufacture a different workflow
or generation for the same offered request. Arbitrary corrupt-row consumer tests
would require explicitly synthetic corruption controls. Committed publishers,
process restart, native retry/cancellation, real transport timing and hosted fault
histories remain open. A successful old readiness followed by ordinary destination
retry is not a reachable fixture because retryability requires failed readiness.
