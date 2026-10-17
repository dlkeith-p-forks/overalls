# Native prerequisites for the Antithesis rebuild

## Scope and architecture impact

This review covers only the staged native prerequisite repairs and ingress
catalog TTL correction at base `c835eb1017d24a001215c319373fa4204d64269b`:
the Galileo/Enrico source-built release probes, role-machine secret fixture and
cookie assertion, updater resource replay assertion, independent ZFS I/O probe,
protocol catalog decoder and its boundary test, and Audi's corrected lease
contract note. It excludes concurrent service startup, Antithesis setup,
workloads and hosted runs. Those sources were still changing during review.

The repairs preserve the accepted service separation, runtime secret custody,
five-second catalog freshness and independent ZFS capacity/diagnostic I/O
boundaries. No new Ash domain, public API, deployment placement, credential
authority or production persistence contract is introduced. ADR-0017 and the
superseded verification contract in ADR-0033 retain partial implementation;
ADR-0142 and ADR-0149 retain their accepted rationale and partial implementation.
The ADR-0153 through ADR-0158 chain is unaffected: this fixture work establishes
none of those guest/editor/source/identity journeys. No replacement ADR is needed.

## Findings and evidence

The [execution ledger](../../../antithesis/verification/native-prerequisites.json)
binds each attempt to its derivation, embedded source or store path, log digest,
result and limitations. The shared worktree changed between attempts, so a
passing derivation is evidence for its captured input, not every subsequent
unstaged source edit.

| Check | Captured result | Boundary |
| --- | --- | --- |
| `galileo-release` | Passed, derivation `aapannmcgm84dw0jv014pyvq8lryjiag` | Pinned release/runtime metadata, module closure, absent host tools, invalid configuration refusal and path-prefix behavior; no listener or NixOS service startup. |
| `enrico-release` | Passed, derivation `apbi9sn6c9izczz2f3gdz8ckgk8vdmry` | Pinned independent release, absent host tools, invalid configuration refusal and Git-source grammar; no TLS listener or remote fetch. |
| `zfs-io` first attempt | Failed, derivation `2q193i3b3gnwgv29vfiqpqrhsyvvqv2w` | The guest created real pools, but the fixture matched a normalized decoded report to its original struct and exited before measured I/O or fault assertions. |
| `zfs-io` retry | Passed, derivation `hnv4wkrcrzxklbm7lywcgqnnpf1wyxd6` | Disposable KVM guest, source-built Lilly, two real pools, outside-dataset traffic, separate capacity and I/O, malformed/timeout/export-import failures, unavailable-rate refusal and recovery. No physical IOPS calibration, production host or composed-driver static type result. |
| `service-roles` first expanded attempt | Failed, derivation `vx5wm4yd9vhfzdssczr34hhijvd8h2r4` | The role fixture reached the release-cookie shell pipeline, then exited under `pipefail` with a broken `tr` pipe. It has no valid full-machine output; the revised full-stream cookie assertion and runtime-sealed Galileo/Ziggy fixture need an actual passing rerun. |
| `service-roles` retry | Failed, derivation `9prabnjpm6frqnwdlbcn3cjfcnlrshb2` | Marshall health and cookie checks completed. Lilly then repeatedly failed to start; `/var/lib/lilly/owner.json` did not appear and the driver timed out after 900.64 seconds. The startup cause remains unidentified. No valid full-machine output exists. |

The role fixture constructs synthetic credentials only in VM runtime memory,
seals them for its SSH-derived age identity and orders real SecretSpec/SOPS
preparation before required private services. This is source review, pending
successful role-machine execution. The updater fixture now checks that storage replay
updates the storage binding while preserving a newer enrollment revision;
its changed assertion has no separately recorded passing execution here.

The ingress decoder formerly accepted 30,000 ms although ADR-0142 already
requires five-second catalog and DNS snapshots. It now accepts at most
5,000 ms, with test cases at 5,000, 5,001 and 30,000 ms. Marshall's
[catalog producer](../../../marshall/lib/marshall/ingress/catalog.ex) already
issues 5,000 ms, so the current producer/decoder pair shares that limit. The
new check rejects stale
peer replies earlier and does not change the separately bounded 30-second
ordinary web/SSH grants. The Audi lease note now states that distinction;
it changes no executable lease logic. The later ordinary Protocol precommit
passed 262 checks with forced Dialyzer; ordinary Lilly passed 559 checks with
forced Dialyzer at runtime source
`90572c5991e7526883a467e9dea4044ba32d792d2e9348692cc2d20d6c322671`.
These project gates do not establish a final Marshall consumer gate, tested
rolling upgrade or end-to-end route withdrawal.

The ledger's scoped pattern scan found no credential values in five Nix logs
and four wrapper logs. That finite scan cannot prove arbitrary secret formats
absent. Neither the release probes nor the ZFS check establish current hosted
Antithesis setup or mutation coverage. The old harness remains retired as
recorded in the [reset review](2026-10-13-antithesis-reset.md).

## Follow-up and validation

Retain both failed service-role attempts and diagnose Lilly's startup before
crediting a later passing derivation and log. The separate `native-zfs` check
is pending at this milestone; the passing `zfs-io` check cannot stand in for
it. Run the updater and protocol consumer gates against the final source
identity where still pending. Validate the
final composed Python driver. The full Antithesis harness needs its own research, setup, workload,
hosted baseline and mutation records. Review receipts should be recorded after
concurrent source and handbook edits settle, with the affected protocol,
services, deployment and governance groups assessed individually.
