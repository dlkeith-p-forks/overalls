# Fleet dependency convergence (2026-10-18)

## Scope and architecture impact

This review investigates the reported Lilly hostd failure and blocked ordinary
SSH routing. The repair preserves [ADR-0030](../decisions/0030-nixos-deployment-and-tls.md)'s
source-built releases, [ADR-0159](../decisions/0159-remove-legacy-compatibility.md)'s
strict converged formats, [ADR-0176](../decisions/0176-host-concurrency-single-writers-and-effects.md)'s
hostd authority and [ADR-0199](../decisions/0199-memory-suspension-and-demand-wake.md)'s
current inventory contract. No decision or protocol changes. The existing
lock-snapshot equality check remains mandatory.

## Findings and forward repair

Read-only inspection found both hosts' Lilly and hostd services running without
restarts. Dungarees' Lilly emits the current six-field inventory containing
`checkpoint_compatibility`, while Overalls still serves the older protocol.
The ordinary CLI reports `SSH proxy unavailable`. A live process alone does not
establish working inventory or ingress, and administrative SSH is separate
evidence.

Both updaters target `ae783fdbe` but report build failures. The failed Porsche
release stops at the existing `cmp mix.lock "$MIX_DEPS_PATH/.overalls-mix.lock"`
guard. Its cached fixed-output dependency directory retains Hegel `8fe9786`,
while the declared lock requires `b0dec2a`. Comparing all eight applications'
retained snapshots with their current locks found the same mismatch in Marshall;
Audi, Brady, Enrico, Galileo, Lilly and Ziggy match exactly.

Refresh only Marshall and Porsche's reviewed dependency hashes through the
[pin registry](../../../nix/domains/artifacts/default.nix), keeping the current
lockfiles and all source/security changes. Build the clean releases and allow
normal forward deployment to converge. Do not broaden hostd's command grammar,
remove the snapshot guard, accept both inventory formats or roll back suspension.
Successful dependency fetching alone is insufficient: release compilation,
activation, fresh host reports and an ordinary CLI request need separate results.

## Verification and limits

The eight-way snapshot inspection and deployed service/version observations are
recorded above. The refreshed Porsche source-built release and
`checks.x86_64-linux.porsche-release` both passed, producing
`/nix/store/4jf06n1iawjk1fi2a93crrr7n8n5hjzy-overalls-porsche-0.1.0`;
local logs are `/tmp/porsche-final.log` and `/tmp/porsche-release-check.log`.
The current Lilly source-built release also exited 0, recorded in
`/tmp/osmatrix-lilly-current-release.log`. These results describe the pre-merge
worktree source snapshot, not deployed convergence. Marshall compilation,
post-integration gates, fresh reports from both hosts and an ordinary CLI
request remain pending in this checkpoint.

Integration also exposed a deployment assertion requiring disabled Peach and a
closed Audi decoder rejecting its emitted socket field. The repair keeps Peach
optional, emits null when disabled, validates configured bounded local socket
paths, and refuses reflection before authority admission when absent. Existing
Lilly/Ziggy/Galileo dependencies remain. This source repair does not enable
production reflection or establish enabled socket/credential acceptance.

No destructive guest operation, hostd restart or production database mutation
was used for diagnosis. This repair does not qualify the separate Windows
browser editor candidate or establish guest isolation or recovery.
