# Uploaded backup publication histories

## Scope and architecture

Baseline `feafe9439c1ebbb7333123cbe764427f79d1f6f3`. Verification extension under
ADR-0070; production decisions, configuration and authority are unchanged.
Real local encrypted Restic and production runtime are exercised. No S3,
systemd, ZFS, PostgreSQL or guest acceptance is added by this evaluation check.

## Property

`test_publication_interruption_history` adds two fixed plus four generated
histories: SIGTERM/SIGKILL after actual manifest upload, keep_last 1/2/3,
empty/nonempty bounded binary input and one/two/three cleanup/prune/restore replays.
Retention's supported keep_last minimum one and neighboring two/three values
form the configured-limit family. Payload generation tests arbitrary bytes, not
throughput or repository-size limits.

The existing delegate_then_block shim runs actual Restic and holds its completed
reply before the runtime records the manifest receipt. The marker is not itself
proof of upload success: independent run-tag snapshot lookup, inspect validation
and exact source-byte restore establish the committed point. Runtime interruption
leaves a failed/interrupted journal without a manifest receipt and preserves
previous last_success_at. Repeated cleanup preserves terminal journal bytes.
Retention keeps the published point and every component reference; exactly
keep_last newer complete points displace it, after which its exclusive references
are absent. The payload uses production materialization of ordinary recovery artifacts;
it does not require filesystem inspection or fabricate it. Every replacement changes source bytes so reference reuse cannot
hide premature deletion. Actual repository component capture includes paths.json.

## Contracts and review

Reviewed ancestor contracts, Fixture interruption/session-drain helpers,
Runner.capture/recover and Repository.retain/manifest. Fresh source review found no blocking issue and confirmed real Restic effects,
independent lookup and restoration rather than fabricated upload results. New test code is typed and production code is unchanged.

## Execution

The pinned operator derivation passed format/lint/ty before starting its complete
real-Restic suite. Initial archive
`1791018157914-4116832-0.jsonl`. The first full run ended exit 1 in 1175 seconds (13 tests in 1164.194 seconds):
all twelve original tests passed; the new property failed its initial backup setup.
the local fixture deliberately has unavailable filesystem tools. The corrected
property uses production materialize instead of paths; the corrected focused property passed in 286.602 seconds, exit 0, in
`/tmp/overalls-upload-focused.log`, with two fixed plus four generated histories.
The final complete pinned operator check passed in 1418 seconds, exit 0;
archive `1791019749568-892525-0.jsonl`. All 13 tests passed in 1406.863 seconds,
including the new two-fixed/four-generated publication histories. Independent
review confirmed the targeted property result and terminal archive status.
Historical fixed publication acceptance retains its original scope.

## Remaining gaps

Fault during upload, S3 transport and durability, systemd producer death with
native mounted snapshots, concurrent cleanup mutation, physical power loss and
hosted Antithesis topology remain separate. No historical execution authority
or production adoption is established.
