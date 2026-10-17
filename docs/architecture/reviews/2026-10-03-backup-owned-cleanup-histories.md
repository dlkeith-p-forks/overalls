# Backup owned cleanup histories

## Architecture impact

Baseline `bf231090049603c801f64cd0aa317a43cb85bde0`. This verification change
preserves ADR-0070's durable cleanup intent and native snapshot ownership rules.
Production backup actions, storage formats, credentials and deployment are unchanged.
The evaluation check explicitly selects pinned Python 3.13 and Hypothesis, and
uses that interpreter for runtime and type verification.

## Properties and contracts

`HostProofHistoryTest` invokes the real `HostCapture.cleanup` and `release` using
controlled ZFS/findmnt responses. A separate fixture records destructive calls
and independently supplies actual snapshot GUID `456`; filesystem work stays
inside a disposable temporary directory.

Generated refusal prefixes and repetitions include changed dataset/snapshot GUID,
foreign local nonce, inherited nonce, foreign or duplicate mounts, mounted absent
snapshot and unavailable inspection stages. Every refusal retains byte-identical
descriptor bytes and makes zero destructive calls. After valid proof, exact owned
unmount/destroy calls occur once. Uncertain post-destroy inspection retains intent;
repeated uncertainty never destroys again, and a valid retry converges.

The second property generates snapshot presence, mount presence and recorded GUID,
with fixed pre-GUID witnesses. Missing recorded GUID permits cleanup only with
matching dataset and local nonce proofs. Confirmed absence converges without
destruction; a mount claiming an absent snapshot refuses and retains intent.

Reviewed contracts include `backup-completion-and-cleanup`,
`host-snapshot-cleanup-owned-only`, both new property contracts, and isolated
fixture and verification claim boundaries. Fresh source review found no blocker.
The actual native command implementation and owning directory remain authoritative;
no test response grants production snapshot authority.

## Recorded execution

The `backup-types` Nix check passed in 10 seconds, terminal exit 0. Ruff format,
Ruff lint and ty passed using the explicit pinned Python 3.13 environment.
Execution passed eight state tests, thirteen workflow tests including the two
new Hypothesis properties, and two status tests. Workflow execution took
1.186 seconds. Fixed witnesses accompany generated examples (up to eight generated examples
for presence/mount/GUID and 24 refusal histories plus two explicit full prefixes).
Log: `/tmp/kittens-backup-host-properties-nix.log`; archive
`1790992985431-1448302-0.jsonl`.

Shared governance, ADR/HLDD references, generated options/coverage/views and Nix
handbook checks passed. Merged Marshall precommit passed 1,424 checks (223
properties, 1,201 tests), two exclusions, seed `15254`, in 1,865.6 seconds.
Forced Dialyzer passed in 69.22 seconds with zero errors, skips or unnecessary
skips; terminal exit 0. Log:
`/tmp/kittens-backup-merged-full-gates-repaired.log`. Publication remains pending.

## Remaining gaps

Controlled command results do not establish native ZFS ownership, real mount
identity, systemd cleanup, arbitrary power loss or complete disaster recovery.
Existing native backup recovery evidence retains its original revision and scope.
Generated native proof changes and interrupted real inspection/destruction still
need separate bounded machine histories. No new hosted Antithesis execution is
claimed.
