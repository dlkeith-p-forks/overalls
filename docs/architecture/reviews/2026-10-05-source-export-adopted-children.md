# Source-export adopted children

## Scope and architecture impact

Reviewed root/Lilly/native contracts, ADR-0037, production sender polling and
cleanup, the actual fd3/fd4 fixture and sibling native helper implementations.
This implements existing all-adopted-child custody and unreaped leader requirements;
protocol, source permit, transfer slot, storage ownership and deployment decisions
remain unchanged. ADR-0037 remains superseded and partial: ADR-0050 replaces its
capacity policy while retaining relocation custody requirements. ADR-0072 remains
accepted and partial. No ZFS or authenticated
remote transfer acceptance is inferred from these local kernel tests.

## Findings and repair

The generated `escaped_export_children_are_reaped_before_owner_exit` property
uses trusted absolute fixture executables, actual separate sessions and validated
positive PID publication. Independent `/proc` witnesses establish distinct direct
and escaped identities, group/session equality and actual sender retirement.
Fixed one/three-descendant histories precede two sampled one/two/three-count
histories. Helper cleanup must stay live until guarded explicit child death,
then return exact success with every adopted PID absent.

The original production selector failed the property in0.08seconds; targeted
package exit1 in75seconds, archive `1791219322823-1921057-0.jsonl`, log
`/tmp/overalls-source-export-escaped-baseline1.log`. Failed patch SHA256
`91783f7f8807201fb219c38fe35dce20606ff54eec45207c6dc5f4eb1e7d6498`,
`/tmp/overalls-source-export-escaped-baseline1-failed.patch`.
Rustix `waitpid(None, ...)` selects children only in the caller's process group;
the exporter treated that group's ECHILD as confirmation despite adopted children
in another session. Cleanup now uses the all-child `wait(...)` selector.

Final semantic review found sender polling used `Child::try_wait`, reaping its
leader before group signaling contrary to its existing contract. Polling now
uses `waitid` with NOWAIT and a checked PID conversion. `finish` signals the
retained private group, reaps the direct child and every adopted child; invalid
identity or uncertain wait errors return EXIT_IO rather than confirming success.
The original blocking reap policy is retained; no new cleanup deadline is claimed.

The observed false cleanup confirmation is high severity under ADR-0037 because
export completion must not serve as evidence that storage readers have stopped.
Inherited native locks are separately relevant; this property does not assert
physical transfer-slot release or storage snapshots. The leader-reuse and uncertain
error findings were source-backed contract discrepancies; no PID-reuse execution
or injected kernel-error reproduction is claimed.

## Verification and remaining work

The selector-only full package passed85seconds, archive
`1791219443566-2063578-0.jsonl`: two library tests and nine integration tests,
six deliberately ignored exec fixtures. That revision predates the leader repair.
Package3 passed exit0 in92seconds, archive `1791219599261-2213767-0.jsonl`, log
`/tmp/overalls-source-export-escaped-package3.log`. Two library Hegel properties
and nine integration tests passed (including the new property); integration
execution took1.33seconds. Rustfmt and all-target locked/offline Clippy passed
through the package gate. No fixtures were counted as passing application tests.

The targeted selector reversion mutant failed exactly the new property in0.06seconds:
one escaped child remained alive while helper exit status was success0. Package
exit1 in77seconds, archive `1791219716113-2303698-0.jsonl`, log
`/tmp/overalls-source-export-reap-mutant.log`. This diagnoses the predicted selector
failure, not collateral damage. The source and test fork were restored and verified
byte-for-byte, then retained at `/tmp/overalls-source-export-reap-restored`.
No mutant entered the user tree. See the
local ledger (`antithesis/scratchbook/mutation-testing/local-source-export-adopted-children.md` at overalls revision `9fe1e493`, repository deleted).

Main9a71e12a was fast-forwarded into this worktree after native verification;
it changes Enrico and documentation, not Lilly production or source-export code.
Native source scope is unchanged. Integrated Lilly and publication checks subsequently passed as recorded below;
normal commit hooks and integration with newer main follow. This is self-review.
Escaped caller EOF/revocation/deadline, uninterruptible I/O, real ZFS/authenticated
SSH and coordinated transfer-slot release remain separate unverified scope.
Transfer-stream has the same source-backed process-group selector issue and needs
its own generated regression and repair; no sibling pass is credited here.

## Integrated Lilly gate

Full Lilly precommit passed exit0:503checks (92properties,411tests),seed666647,
in73.4seconds. Forced Dialyzer passed11.78seconds with zero errors, skips or
unnecessary skips after PLT checking57.91seconds. Runtime, compiler, formatting,
contracts, logging, ADR and reviewed HLDD gates passed. The test PATH selected
the exact repaired source-built helper package. Log:
`/tmp/overalls-source-export-adopted-lilly-precommit.log`.
Pinned code-contract syntax/discovery, scenario generation, views and option
reference checks also passed. Final all-file hooks and evaluated HLDD passed exit0 in17seconds, archive
`1791221374656-3268397-0.jsonl`, log
`/tmp/overalls-source-export-adopted-publish-checks.log`.
Integration of other completed batches remains pending. These checks do not
establish escaped failure-path or physical storage acceptance.

Final diff review preserves retained ADR-0037 custody and ADR-0072; the repair
changes premature completion to confirmed all-child reaping without introducing
a new cleanup deadline or authority boundary. Self-review limitations remain.

## Failure-path extension draft on3a8748b2

`escaped_export_failure_retains_lock_until_actual_reaping` is present but has no
recorded native execution. It checks callerEOF, explicitX cancellation,
malformedL0 renewal, deadline, senderFailure, excessiveDiagnostics and SIGTERM.
Each of two generated cases includes all seven triggers with fixed counts1/3,
plus a generated trigger/count1/2/3. The existing completion property is retained.

Private fixture children publish actual direct/escaped PID witnesses and their
independent group/session before the sender holds. After the trigger, direct
sender retirement cannot substitute for escaped-child death. The helper must
remain alive and an independent open-file-description flock must refuse the
same stable lock. Explicit guarded descendant death must allow actual reaping,
exact status1/2/3/4 and successor flock. The deadline fixture uses5000ms; no
existing deadline or production code changes. This extends verification within
retained ADR-0037 custody and ADR-0072, with no architecture decision change.
Native package, mutation attribution, component and publication gates are pending
for this extension. Recorded completion evidence above applies to its historical
source scope and does not prove these newly added failure histories.

### Failure extension native result

Failure extension package passed exit0,126seconds, archive
`1791223765972-671788-0.jsonl`, log
`/tmp/overalls-source-export-escaped-failures-package4.log`. Two library properties
and10integration checks passed, including both completion/failure custody
properties; six executable fixtures were ignored. Integration completed21.03seconds.
Rustfmt and all-target locked/offline Clippy passed. All seven fixed failure
triggers ran with counts1/3 in each of two cases, plus generated trigger/count.
No assertion or production deadline was changed. Prior component503checks retain
scope on unchanged production/application source at3a8748b2; this new package
records the Rust property extension. A failure-oracle selector mutation and final
handbook/publication checks remain pending. No real storage/SSH claim is added.

### Failure-oracle selector mutation

The unchanged failure property falsified the group-only wait selector on
CallerEof/count1: helper completion was observed while the independently
witnessed escaped child remained live. Targeted property failed5.10seconds;
package exited1 in103seconds, archive `1791224263140-979856-0.jsonl`, log
`/tmp/overalls-source-export-escaped-failure-selector-mutant.log`.
Patch `source-export-failure-process-group-only-reap.patch` SHA256
`f31123729980d6cc90b65dc7d81ae687cbcbb43e1ee6d12eb7529bba1c0fa09d`.
The first EOF counterexample stops the mutant; other failure-trigger mutation
counterexamples are not credited. Source/tests were restored and compared
byte-for-byte, then retained at
`/tmp/overalls-export-failure-selector-restored-mbyjggbi`.
No mutation remains in the user worktree. Final publication checks remain open.

### Failure publication and audit fairness integration

Failure extension structural checks, all-file hooks and evaluated HLDD passed;
the evaluated check exited0 in16seconds, archive
`1791226477312-2096067-0.jsonl`. Normal commit hooks passed for f2752a91.
The audit fairness integration brings the already verified505-check Lilly tree
from35f7770f. That gate passed seed300233 in119.9seconds, with94properties and
411tests; forced Dialyzer12.45seconds, zero errors/skips/unnecessary skips, log
`/tmp/overalls-source-export-fairness-integrated-lilly-precommit.log`.

Compared with35f7770f, the combined tree changes only the source-export Rust
test file and research/handbook records. Compared withf2752a91, native
source-export source/tests are unchanged. The recorded native126-second package
therefore retains its exact native source scope, and the505-check consumer result
is reused for unchanged Elixir production/tests, protocol and shared tooling.
No fresh combined component execution is claimed. Merge receipts and structural
checks follow; latest origin/main integration and hosted/storage gaps remain open.

## Main29ad6228 integration checkpoint (2026-10-06)

Preserved source/tests are byte-identical to the waiting-intent tree0662d4f8.
The recorded native packages and mutants above retain their historical scope.
Fresh combined package/consumer gates, current handbook receipt review and
publication remain pending; no full merged execution is claimed.

### Fresh integrated package execution

Forced integrated rebuild passed exit0,111seconds,archive
`1791249901266-3984571-0.jsonl`,log `/tmp/overalls-integrated-source-export-rebuild.log`.
Two library properties and ten integration checks passed, six executable fixtures
ignored. Completion and escaped failure properties both passed; integration20.97s,
rustfmt and all-target Clippy passed. Verified package:
`/nix/store/vn9l44w58izzgkjdq190af1fwpnlcpgh-lilly-source-export-0.1.0`.
Pinned Nixpkgs input came from the existing launcher; package sources came from
the integration worktree. Full current consumer/handbook/publication gates remain
pending. Local process/lock acceptance does not establish actual ZFS/SSH transfer,
slot release or physical recovery. Accepted rationale and ADR statuses unchanged.
