# Native prerequisite evidence

[The machine-readable record](native-prerequisites.json) binds each result to its Nix derivation, output, packaged application, executed source hash, and direct and wrapper log hashes. The shared worktree was dirty; later evaluations can produce different derivations. These are local prerequisite checks, not Antithesis run results.

| Check | Recorded result | What executed |
| --- | --- | --- |
| `galileo-release` | Passed, 2026-10-13 08:44 UTC | Packaged Galileo eval checked pinned runtime and metadata, independent modules, configuration refusal, and segment-aligned path stripping. |
| `enrico-release` | Passed, 2026-10-13 08:44 UTC | Packaged Enrico eval checked pinned runtime and metadata, independent modules, configuration refusal, and Git source-label validation. |
| `zfs-io` first attempt | Failed, 08:27 UTC | The first guest probe raised `MatchError` when it required a decoded protocol report to equal the original struct. No fault cases ran. |
| `zfs-io` retry | Passed, 08:41 UTC | A real NixOS guest with ZFS disks exercised source-built Lilly capacity and independent pool I/O sampling, outside-dataset reads and writes, malformed and timeout faults, actual export/import reload, and recovery. |
| `service-roles` first attempt | Failed, 08:54 UTC | The combined Marshall cookie check used a pipeline that returned 1 under `pipefail`; the log records a broken pipe. |
| `service-roles` retry | Failed, 09:59 UTC | Marshall health and cookie checks completed. Lilly's unit repeatedly failed, the ownership file did not appear, and the file wait timed out after 900.64 seconds. The startup cause remains under investigation. |

The ZFS retry's Nix log records all three fault commands and `test script finished in 45.77s`. The two release logs end with their application-specific payload verification markers. Release eval does not start listeners; the ZFS run is local KVM evidence, not production or remote Antithesis acceptance.

Six direct Nix logs and five wrapper JSONL logs were scanned for private-key headers, Basic/Bearer authorization headers, long credential assignments, and URL userinfo. No matches were found. The record includes no raw logs or credential values. This bounded scan does not prove that every possible secret format is absent.

The ZFS Python fragment has annotations and runtime JSON validation. This record makes no claim that the Nix-composed driver passed a static type checker. Future retries should be appended as new attempts with their own derivation, output validity, source hashes, and log hashes; an edited fixture alone cannot change an earlier result.
