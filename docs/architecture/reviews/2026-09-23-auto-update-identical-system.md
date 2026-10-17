# Automatic update identical-system recovery

## Scope and architecture impact

This review covers two host updater recovery paths in
[runtime.py](../../../nix/modules/auto-update/runtime.py): preflight for
`/dev/shm` and a new Git revision that builds the already-active system and
manifest. It affects ADR-0036's activation and health implementation, carried
forward by ADR-0038, ADR-0043 and ADR-0048. The existing candidate identity,
secret custody, migration and no-rollback decisions remain in force. No new
decision is needed.

## Findings and resolution

### High — an unusable shared-memory mount could strand consumers

The updater previously began the stop and switch sequence without confirming
that `/dev/shm` could support a PostgreSQL restart. It now rejects a missing,
read-only, non-tmpfs or incorrectly permissioned mount before stopping any
consumer. A failed check reports `shared_memory_unavailable` in the activation
phase and leaves the last healthy revision unchanged. The initial preflight
checked tmpfs type and permissions; review found that it also needed to check
the mount's writable flag.

### Medium — a source-only revision caused needless activation

A different Git revision may build the exact active system and manifest. The
updater previously staged secrets, ran migrations and switched that same system
again. It now verifies live roles and records the new healthy revision without
interrupting services. A changed system or deployment manifest continues through
the existing stage, preflight, migration and activation path. Secret-preparation
units are checked before either path.

## Verification and remaining acceptance

- Focused Python tests cover writable, read-only, wrong-filesystem and wrong-mode
  mounts, plus refusal before a consumer stop.
- The full `auto-update` NixOS machine check passed. Its new case published a
  second Git commit with the same deployment, confirmed healthy history advanced,
  and observed an unchanged live service PID and system generation.
- Repository-wide Ruff format, Ruff check and ty hooks passed. The ADR checker
  and code-contract structural gate passed.

The machine fixture does not establish production rollout. Production
activation remains a separate deployment check.
