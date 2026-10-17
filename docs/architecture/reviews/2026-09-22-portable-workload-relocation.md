# Portable workload relocation

## Scope and evidence

This review covers the creation, restart, clone and relocation boot-artifact
boundary in protocol, Lilly and Marshall; capacity accounting; public host-name
projection; the Marshall web relocation control; and native test coverage. It is
a substantive change to storage, transfer, authorization-facing projections and
the public machine API. ADR-0092 records the replacement decision and supersedes
ADR-0089 while carrying forward its Porsche receipt and automatic-placement
rules.

Affected decisions are ADR-0037, ADR-0046, ADR-0055, ADR-0072, ADR-0089 and
ADR-0092. Code evidence is linked from ADR-0092.

## Findings

### Host-local boot artifacts made the dataset incomplete

Severity: high. ZFS transfer carried all guest drives but the jail mounted kernel
and initrd from the destination image catalog. A valid existing VM could therefore
fail activation solely because a compatible host did not retain the catalog
entry. This was an implementation/design discrepancy with the requested portable
relocation boundary. Fresh creation now publishes a closed bundle into the owned
dataset before disk readiness, and every existing-workload launch consumes it.

### Repeat digest verification used the wrong authority

Severity: high. The immutable image digest is appropriate at fresh creation,
before bytes enter a placement. After that point, placement ownership, exact file
shape, durable readiness and ZFS snapshot/GUID lineage are the relevant authority.
Clone and relocation adoption no longer query a destination image catalog.
Malformed, missing or workload-mismatched bundles still fail closed.

### Portable bytes were absent from capacity commitments

Severity: medium. Adding artifacts to a dataset without reserving their logical
upper bound would make admission and transfer holds undercount the workload.
Shared VM reservation arithmetic now includes bounded kernel, initrd and metadata
space, automatically feeding provision, clone and relocation commitments.

### Stable host names are useful; placement identifiers remain authority

Severity: medium. ADR-0089 prohibited all topology in public relocation results,
but the current requirement explicitly calls for showing which machine executes a
Firecracker VM. Marshall now resolves only the current stable host name into
authorized list/detail projections. Host UUIDs, placement UUIDs, pools and
relocation endpoints remain absent. This is a deliberate replacement of that
ADR-0089 visibility invariant, not an accidental implementation drift.

### Existing manage authorization already expresses relocation rights

Severity: low. Owners, shared managers and team administrators already receive
`manage`; viewers and operators do not. Porsche and LiveView both call the same
Compute action and neither accepts a destination. No new policy subject or direct
host-selection authority is needed.

## Decisions and open questions

ADR-0092 is accepted and partially implemented under the user's explicit
2026-09-22 authorization. No design question remains. The exact Porsche clone
round trip now has passing native evidence. Implementation remains partial until
the remaining component gates and affected native tests complete.

## Verification performed

Protocol bundle and disk-layout tests pass. Lilly and Marshall compile with
warnings as errors, and focused Lilly jail tests pass. The remaining component,
Python/Nix verification is intentionally not claimed here until run.

The typed Porsche fleet scenario now creates a source, clones it, relocates the
clone across hosts and relocates it back through the public SSH command. Each
move asserts the durable `ssh_requests` relationship, exact request replay,
changed host and placement identities, real guest boot/data, stable public host
projection and removal of the old ZFS dataset. Ruff formatting/linting and ty
passed for the scenario, and both `porsche-fleet.driver` and
`cloning-fleet.driver` built. The isolated `cloning-fleet` native run completed
all Porsche/cloning subtests in 889 seconds with exit zero.

Broader `porsche-fleet` runs completed the Porsche subtest but later reproduced
the independent capacity-race fixture's timing-sensitive one-versus-two admission
result. That unrelated full-suite failure is not counted as passing evidence and
the capacity assertion was not weakened for this change.

Production Porsche acceptance passed against revision
`a5ddfc7838d62946ef955f8f23323f8d7bf96c95` on both physical hosts. Porsche
created source `overalls-relocation-20260922-121310-source`
(`605ebc7f-b4c4-4432-98a6-60ec38c7682b`) on Overalls and cloned it as
`overalls-relocation-20260922-121310-clone`
(`123fa0fb-d4c3-472c-b116-2b54de2d1441`). The clone moved Overalls to Dungarees
under operation `c8a7896f-14a6-4845-85c3-ba3c96d1542a`, returned running with
`host: dungarees`, and reported 62 seconds of downtime. Exact replay of request
`c592dfa8-de42-4fb1-9a31-3192e1fa8aa2` returned that same completed operation.
The clone then moved Dungarees to Overalls under operation
`cccbaf8f-abd4-4723-aba0-ebf9492c98ec`, returned running with `host: overalls`,
and reported 67 seconds of downtime. Exact replay of request
`42073895-5e9d-42d5-bf7c-e01b72d41da8` returned that same completed operation.

Deletion requests `8d213e62-991d-44f0-8c93-d66dda202a6c` and
`276ad0eb-d757-40ff-b805-74ea14b12c6c` then removed only the clone and source.
The complete Porsche listing had no matching fixture name, no next page, and two
unrelated machines remained. During the first move, destination activation
finished before delayed source ZFS teardown; Lilly retained `source_cleanup`,
retried its guarded non-forced destroy, and completed without operator mutation.
This is positive evidence for durable handoff and retry behavior, not for the
negative malformed-bundle or missing-catalog cases encoded by native tests.

## Follow-up work

Run all remaining component precommit gates and affected native ZFS scenarios
before marking ADR-0092 implemented. ADR/code-contract validation for this
evidence update must also pass.
