# Enrico git-mirror native service refresh verification

## Scope and plan (pre-implementation record)

Campaign 046 uses `verify/046-git-mirror-refresh` and its own worktree,
starting from published `c14ae27dc0fbbca400e73ae5c6f1567104ab9801` (tree
`77375008a893f80ca4b8094c965e03e85e44980a`). The user authorized incremental
verification and bounded repairs, with one agent/worktree per improvement and
coordinator integration. No deployment or live GitHub request is part of this
work. This record was written before any implementation or native run.

- User operation: browse and administer Git mirrors — register, refresh, cache
  reads and an unavailable mirror. This improvement scopes to the packaged
  Enrico native service boundary: the existing `enrico-service` machine check
  ([fixture](../../../nix/verification/tests/machines/enrico-service/default.nix),
  [driver](../../../nix/verification/tests/machines/enrico-service/driver.py)) recorded as
  `present` in the `git-mirrors` scenario row, with the merged 017 review
  retaining its force-push/outage evidence only historically.
- Allowed result: the source-built Enrico service behind verified private TLS
  and its service token clones the isolated HTTPS Git fixture, serves bounded
  tree/blob reads, and publishes new heads on update refreshes.
- Refusals: a request without the service token gets HTTP 401 and no cache
  read. A refresh carrying invalid owner/repo labels gets HTTP 400 with no
  attempt state and no mirror directory (currently unit-covered only at the
  `Git.valid_source?` predicate; a bounded native API assertion is planned).
- Failure/recovery: an upstream outage settles a refresh attempt as `failed`
  while the last published commit stays readable; an upstream force-push keeps
  the previously published commit readable even after cache-side
  `git gc --prune=now`. Post-restoration recovery refresh has no native stage
  yet; a bounded addition is planned.
- Independent oracle: Git-level assertions executed inside the VM against the
  fixture and the service-owned bare mirror — exact blob contents, exact
  40-hex head SHAs, old-commit survivability after pruning and attempt status
  transitions — independent of the service's own claims.
- Native boundary: the recorded run of `vm-test-run-kittens-enrico-service`
  itself: one QEMU NixOS VM, the packaged Enrico release, a verified local
  HTTPS Git fixture and real Git clone/fetch/gc. Store path, duration,
  per-stage results and cleanup/process drain are recorded below. Physical
  tunnel, ZFS quota/100 GiB cache pressure, large-repository durations and
  production rollout stay outside this boundary.
- Dependencies: `nix/verification/tests/machines/enrico-service/`, the `enrico` NixOS
  module, the packaged Enrico release and the serialized native-build lock
  `/tmp/kittens-native-build.lock`.
- Required checks: all-file prek (Ruff/ty cover the driver), ADR, HLDD
  receipt/generated-reference and views gates, the Nix `hldd` check, and the
  Marshall precommit gate because `marshall/priv/hldd/scenarios.json` changes.

## Assertion inspection and bounded additions

The merged 017 evidence covers the Marshall Catalog/Worker with generated
histories, six three-BEAM schedules and one recorded browser journey on
captured `f4de549a`-based source; its native Enrico service evidence retained
historical scope only. The driver on current source asserted the token
boundary, initial clone/read, update, force-push retention and outage
preservation. Inspecting current documented behavior against those stages
found three unexercised boundaries that no covered test duplicated:

1. Invalid source labels through the packaged API. ADR-0097 fixes GitHub
   owner/repository labels as the only source and forbids caller-controlled
   remotes; the `git-fixed-public-source` and `enrico-closed-fleet-api`
   contracts require the same. Only the `Git.valid_source?/2` predicate had
   unit coverage. The driver now refreshes with owner `../marshall`: HTTP
   400, the attempt stays `missing`, and no mirror directory appears.
2. Idempotent replay of a completed refresh attempt. The
   `mirror-attempt-single-flight` contract requires a repeated attempt ID to
   return its recorded status without another fetch; no test exercised it.
   The driver now repeats the force-push attempt POST and requires the same
   succeeded status and head.
3. Failure recovery after the source returns. The user journey refreshes
   "through failure", but the driver stopped at the failed attempt. The
   driver now restarts the fixture HTTPS source, force-pushes a fourth commit
   and requires a fresh refresh to publish it while the published head
   changes from the third commit.

No production source, schema or protocol change resulted; the additions are
test-infra only. The machine contract in
[nix/verification/tests/machines/enrico-service/default.nix](../../../nix/verification/tests/machines/enrico-service/default.nix)
was updated in the same change to describe the extended boundary.

An intermediate amended driver failed the strict composed-driver `ty` gate
(`dict[str, object]`-annotated JSON narrowing to `Never` keys in two `get`
assertions). The helper was replaced with the existing any-narrowing pattern,
and the strict driver build passed before the runtime was attempted again.

## Architecture and contracts

ADR-0097's accepted source policy, service custody, token boundary, quota and
retention rationale are unchanged; its implementation stays `partial` pending
physical tunnel and cache-pressure acceptance. No new decision is required.
The reviewed contracts are `enrico-private-mirror-machine` (extended in this
change), `git-fixed-public-source`, `enrico-closed-fleet-api`,
`mirror-attempt-single-flight` and `mirror-attempt-retention`, plus the
nix-test real-packages and isolated-inputs directory contracts: the fixture
pins `github.com` to loopback with a dedicated CA and disables redirect
following, and the driver asserts against the packaged release only. The
root documentation contracts bind the scoped claims below.

## Execution evidence

**Run of the as-merged driver on current source** `c14ae27dc0fbbca400e73ae5c6f1567104ab9801`
(tree `77375008a893f80ca4b8094c965e03e85e44980a`): derivation
`/nix/store/2msldk28n3xs8s9ki8jdi60nfmlg3lmq-vm-test-run-kittens-enrico-service.drv`,
result `/nix/store/5hgvqsl9m7465aaknizp6b0qgzr7m6yb-vm-test-run-kittens-enrico-service`.
Built under the serialized `/tmp/kittens-native-build.lock`; wall 1,872 seconds
including lock queueing behind another campaign machine run. The test script
finished in **22.77 seconds** and cleanup in **0.00 seconds**. All five existing
stages passed: unauthorized refusal (0.04 s), clone and read (1.21 s), update
(1.28 s), force-push retention after pruning (1.41 s), source-outage
preservation (1.21 s). After the command exited, no `nixos-test-driver` or
`-name mirror` QEMU process belonging to this run remained; one unrelated
host-side Enrico beam started later by another session (PID 2606752, parent
init, first seen 11:57) was explicitly left untouched and never entered the VM
boundary.

**Amended-driver runtime.** The strict composed driver
`/nix/store/b5fbvs1354jc8xbx9q4572q6hizsrgaj-nixos-test-driver-kittens-enrico-service`
passed the framework lint and pinned `ty` checks ("All checks passed!") after
the intermediate `Never`-key narrowing failure described above; that failed
attempt (`a9369wx2` run derivation) never executed a runtime. The corrected
native run under the same lock: derivation
`/nix/store/a99n9r6ay23zkydjazwm2knhs4zwisp0-vm-test-run-kittens-enrico-service.drv`,
result `/nix/store/09cbhcyy8d12xblm5qj1a4nh2hx7wdan-vm-test-run-kittens-enrico-service`,
wall 30 seconds with dependencies cached.
The complete amended journey passed in 23.85 seconds with cleanup in 0.14 seconds.
Per-stage: unauthorized
refusal 0.04 s; invalid source labels refused with the attempt `missing` and no
mirror directory 0.08 s; clone and read 1.18 s; update 1.24 s; force-push
retention after pruning 1.36 s; repeated attempt replaying its recorded
succeeded head without a new fetch 0.03 s; source-outage preservation with the
attempt settling `failed` 1.21 s; recovery after the source returned publishing
a distinct force-pushed head 1.34 s. After exit, the only test driver on the
host was another session's `kittens-brady-fleet` run; no driver or QEMU process
of this run remained.

The independent oracle held at every stage: Git-level assertions compared exact
blob bytes (`first`/`second`/`third`/`fourth`), 40-hex heads, attempt status
transitions and the absence of mirror state, against the fixture and the
service-owned bare mirror rather than the service's own claims. Both runs used
the packaged release inside one disposable QEMU VM with the CA-pinned loopback
fixture; nothing touched live GitHub or a production host.

## Remaining scope

ADR-0097 stays `partial`: independent physical tunnel acceptance, ZFS quota and
100 GiB cache pressure, large-repository durations and production rollout
remain separate, unrun acceptance boundaries. The runs are one QEMU VM on one
physical host, not production performance or multi-host evidence. The browser
cache checks in 017's journey retain their ordinary-filesystem scope. The
intermediate strict-typing failure is recorded as test-authoring history; it
produced no runtime claim.
