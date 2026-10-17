# Hegel migration for NixOS verification

## Scope and architecture impact

This change makes Hegel the property engine for the selected composed NixOS
machine drivers. It extends the existing `hegel.runTest` wrapper and binding
with state-machine worker handles, concurrent scheduling, strict replay
mismatch failures, and an imperative-failure epilogue. It migrates the driver
properties for OTEL burn delivery, OTEL request recorder commit/reply loss,
fleet runtime readiness and submission recovery, and ZFS actor recovery. The
remaining machine suites and evaluation checks retain their imperative or
fixture-specific evidence because they either exercise exact installation,
firmware, browser, image, guest-side, or one-shot behavior, or are not live
NixOS drivers.

The change has no product architecture impact. It adds no modules, hosts,
services, domains, protocols, persistence, authorization, isolation boundary,
or deployment role. `properties` is consumed by the test composer and removed
before `runNixOSTest` receives its arguments. The Hegel worker concurrency is
confined to verification processes and does not change the runtime topology.

## Verification inventory

The canonical inventory contains 92 machine directories, 77 standalone
`default.nix` suites, and feature fragments composed into fleet tests. The
roughly 47 checks under `nix/verification/tests/evaluation` are build or
`runCommand` checks and remain outside Hegel. Existing Hegel suites for
agent-cli, underclass-service, secret-custody and zfs-transfer remain in place.
The new live-driver migrations are:

- `otel-burn-delivery`: generated alert routing and label-refusal histories;
- `otel-request-recorder`: producer histories and committed-reply/gap loss;
- `fleet`: runtime readiness and submission recovery histories;
- `zfs-guest`: native actor recovery histories.

Fixed acceptance subtests remain in each driver and execute before the Hegel
epilogue. Generated cases reset or restart the relevant fixture state where
needed. Concurrent state machines use cloned test-case handles and require
fixture synchronization; libhegel reports concurrent schedules as
nondeterministic, so they are evidence of schedule coverage and do not claim a
shrinkable replay blob.

## Evidence and limits

Structural validation passed for Python compilation, Nix parsing and diff
whitespace. The explicit `hegel-framework-packages` check now builds the pinned
native engine and binding and passed the smoke suite: value properties,
shrinking, replay, cross-property and malformed-blob rejection, state
machines, and a concurrent worker schedule. Full KVM execution of every
migrated suite remains an execution task
for the target environment; no unrun machine is described as passing here.
Guest-side Hypothesis helpers used by evaluation/packaged fixture runners are
not silently relabeled as native Hegel machine evidence. Inception failures
remain known and out of scope.
