# Git mirror user-operation verification

## Scope and plan

Campaign 017 uses `verify/017-git-mirror-journeys` and its own worktree,
starting from published `f4de549ac74d2f19a100439b6cfac2879213e720`.
The user authorized incremental verification and bounded repairs, with one
agent/worktree per improvement and coordinator integration. No deployment or
live GitHub request is part of this work.

The bounded plan was to inspect ADR-0097, Catalog, Worker, resources, browser/raw
routes and existing tests; reproduce current-authority and stale-result source
concerns through real actions before repairs; add independent generated catalog
histories and three-BEAM schedules; exercise ordinary browser reads and elevated
mutations against disposable packaged Marshall/Enrico and local HTTPS Git; then
run mandatory application, type, contract, architecture and handbook gates.

Existing `enrico-service` machine evidence already covers the packaged private
service, local HTTPS cloning, update, force-push with retained old refs, service
token refusal and source outage. Existing worker tests cover resumed attempts and
transient status failures. Those are retained with their original scope. They did
not establish the Marshall browser catalog or generated public-action histories.

## Reproduced findings and correction

### Current administrator authority escaped the mutation transaction

On the unchanged production source, an elevated administrator's real
`Catalog.register` stopped at a disposable trigger on its actual repository
INSERT. A second independently started Marshall completed the real
`set_administrator(false)` action while registration was blocked; registration
then committed under the stale check. A third independent process observed the
committed states. The intended serialization oracle failed at `:overtook` with
seed `17003`, and again in the three-case baseline with seed `17004`.

Catalog now holds the current actor User row through the mutation transaction,
rebinds the stored login and checks recent passkey elevation/current Cedar admin
authority after locking. Existing administrator demotion, MFA reset, session
revocation and retirement take that target row lock. Catalog takes no installation
lock after the actor row, preserving existing installation-to-target order.
Refresh/removal then lock the current repository before checking eligibility and
writing intent/audit/job. Repeated removal returns `:removing` without duplicate
intent. Denied and rolled-back mutations append no intent or job.

### A replaced attempt published an obsolete head

Worker A awaited a verified local HTTPS response. Worker B observed A's attempt
as missing, recorded abandonment and began a distinct durable attempt B. Releasing
A's success while B was refreshing published A's head with B's retained attempt
identifier. The third process observed `phase: :ready`, A's head and B's attempt
ID. The exact-current-attempt oracle failed with seed `17004`.

Attempt admission now locks and rechecks the observed phase and attempt ID.
Success and failure settlement each lock/reload the repository and require
`refreshing` plus the exact owned attempt. A result arriving after replacement, removal or another worker's settlement
produces no state/audit/diagnostic outcome. Network calls and polling occur
outside those lock transactions. Outcome diagnostics use `Ledger.after_commit`,
so an enclosing rolled-back transaction does not emit a successful outcome.

The separate removal baseline did **not** restore browser access: AshStateMachine
already atomically rejected `removing` to `ready`. It raised from the obsolete
worker's update. The new current-attempt check settles that obsolete job without
raising. This result is not evidence of a pre-existing removal-authority bypass.

## Architecture and contracts

ADR-0097's accepted public GitHub source policy, administrator/elevation boundary,
ordinary signed-in reads, PostgreSQL/Oban authority and retained publication remain
unchanged. ADR-0074's durable state transitions remain authoritative. There is no
schema, protocol, deployment topology or dependency change. Existing rows and jobs
are compatible; all serving releases need the repair to enforce the new checks.

Reviewed contracts include repository evidence/diagnostics, Marshall durable
authority, Enrico current-admin/reader and durable-audit requirements, Ledger lock
lifetime and outer-commit callbacks, current Security/Cedar authority, account
target-row ordering, web stored-login/raw checks and isolated Nix inputs. New
contracts require exact attempt settlement and independently observed public
histories. The review traces Catalog's admin LiveView callers, Worker entrypoints,
resource transitions, Enrico client, and existing authority-change coordinators.

No new architecture decision is required. Final author and coordinator reviews
found no remaining contract or architecture discrepancy in the bounded changes.
They traced current authority through the catalog transaction and exact attempt
ownership through publication, with network waits outside row locks. The execution
section records gate scope; the accepted ADR remains partial.

## Execution evidence

- Existing catalog baseline: **5 passed**, seed `17001`.
- Pre-repair three-case baseline: **0/3 passed**, seed `17004`. Two intended
  consistency defects above and the safe removal rejection were observed.
- First corrected focused run, including existing catalog/worker tests and three
  distributed schedules: **10 passed**, seed `17005`, 10.6 seconds.
- Generated histories and six independent-process schedules: **7 passed
  (1 property, 6 tests)**, seed `17007`, 9.4 seconds. The reviewed complete
  refusal inventory and peer-completion refinements also passed **7 (1 property,
  6 tests)**, seed `17008`, 11.8 seconds. The property runs 18 bounded
  generated histories of actual registration, manual refresh, worker outcomes,
  ordinary-user refusal, removal and same-label re-registration. It checks a
  separately retained head, exact audit actor/attempt tuples, queued job identities
  and no service request from stale repository handles. The six schedules cover
  both demotion orders, removal before success, replacement before success/failure,
  and duplicate success settlement. Three independently started BEAM processes
  share PostgreSQL; the coordinating test process is not counted.

All barriers belong to disposable fixtures. HTTP replies and PostgreSQL gates are
released and remote tasks are drained before deleting fixture rows. Unresponsive
peers are stopped before cleanup. A peer-side completion envelope distinguishes
returned exceptions from RPC/transport/task timeouts; an unknown completion stops
the peer before cleanup. Proven completed exceptions retain a healthy peer.
Refused generated operations compare complete repository/audit/job inventories.
These tests prove local database and action ordering, not physical
host failure or actual Git fetch behavior.

The new `git-mirrors-browser` fixture passed its complete native journey after
correcting the initial fixture UI expectation described below.
It uses packaged Marshall/Enrico, one NixOS VM, local verified HTTPS Git,
Chromium and a virtual WebAuthn authenticator. The browser creates elevation and
catalog intent; an ordinary account visits tree/blob/history and raw downloads;
successful refresh, source outage, retained old content, anonymous/stale refusal,
audit attribution and actual cache deletion have explicit assertions. It does not
disable TLS validation or request a public provider. The standalone browser
artifact and composed driver have explicit pinned type gates.

The new fixture uses the service's ordinary cache directory on the disposable VM
filesystem. Cache content/read/deletion checks do not establish ZFS quota or
100 GiB pressure behavior.

The initial strict composed driver and standalone browser artifact passed pinned
Nix typing/linting (`h8ql5hcc` driver, output `03dmrkqc`; browser artifact
`1kpknq45`). Explicit development ty also passed with the pinned Playwright Python
environment. All-file prek, contracts, ADR, options, coverage and views checks
passed. Nix HLDD initially rejected a formatter-only inventory-oracle delta;
after reviewing that change and recording its no-impact rationale it passed as
`/nix/store/vx2fmy5ahb2rm8x9rir226mc0ijg57sd-kittens-hldd-check`.

The initial native candidate was
`/nix/store/1clwpivgdh2w9j37lndk5g6kx7sc0lwl-vm-test-run-kittens-git-mirrors-browser.drv`,
with tree `39678bf05b190c0cc9e7cdef8864bd89a0a622a7` on `f4de549a`.
It includes the reviewed history/remote-completion refinements. Its driver
`vjsv6z67` passed strict typing/linting and built
`/nix/store/ggnqgrryhf6vfsfwgg7vpp19p22qnyn4-nixos-test-driver-kittens-git-mirrors-browser`.
The full Marshall suite passed **1,059 (104 properties, 955 tests)** with two
explicit exclusions, seed `910622`, in 444.1 seconds. Browser-state gates passed.
Forced test-environment Dialyzer passed with **zero errors, zero skips and zero
unnecessary skips**, 53.47 seconds after a 3m19s PLT rebuild.
A post-test database audit found zero users, repositories, mirror audit rows,
mirror jobs, fixture triggers and gate functions. After the gate exited, no
database sessions remained. The complete gate exited zero.

The native `1clwpivg` run booted the packaged services and signed in the fixture
administrator, then failed expecting the pre-elevation Add mirror button to be
absent. `LiveAdminAuth` deliberately exposes administrator controls by current
role and redirects mutation events to passkey verification when elevation is
missing. This was an incorrect test expectation, not an established product
defect. The corrected fixture submits the real pre-elevation form, requires the
security-page redirect and unchanged repository/audit/repository-job inventories,
then performs actual browser WebAuthn enrollment/elevation before registering.
No clone, ordinary browsing, refresh or removal acceptance comes from this failed
run. Cleanup completed in **0.50 seconds**; agent and coordinator independently
confirmed driver `694254` and QEMU `694561` absent after the native command exited.

The final test helper also tags every paused HTTP reply with a fresh reference.
Cleanup fallback replies cannot satisfy another request on a reused Bandit
connection process. This changes only the test fixture, with the full gate's
earlier scope retained. Focused generated/distributed checks passed **7 (1 property,
6 tests)**, seed `17009`, 8.8 seconds. Forced test-environment Dialyzer passed
with **zero errors, zero skips and zero unnecessary skips**, 59.44 seconds.
The subsequent database audit again found no fixtures, gates or sessions.
All-file prek, final contracts, ADR/options/coverage/views and Nix HLDD passed;
the final Nix HLDD output was
`/nix/store/jznx3lwbjh4z97zclxq9m80c8k6lpw2m-kittens-hldd-check`.

The corrected native retry is captured at tree
`89e03703a4db2bbe9fc8add3e329262d9f46651c`, base `f4de549a`, with derivation
`/nix/store/kajhias57qm7icallpx5wkdnd12g8m20-vm-test-run-kittens-git-mirrors-browser.drv`.
Its strict driver `glkrvx3s` passed pinned typing/linting and built
`/nix/store/g8gzv8ps5k0qhsampfw0zl8k7qzkyiwi-nixos-test-driver-kittens-git-mirrors-browser`.
The standalone browser artifact is `qa3b0151`.

The complete native browser journey passed in **53.43 seconds**, with cleanup in
**0.49 seconds**. The result is
`/nix/store/7w5bhgimzlw8blwaadblkp876jz0d2w9-vm-test-run-kittens-git-mirrors-browser`.
The owner command exited zero and its session drained. Agent and coordinator
independently confirmed driver `992635` and QEMU `993306` absent before releasing
the runtime slot. This establishes the assertions above on the captured tree;
the initial failed run remains separate evidence.

After native completion, published `38edcbea09233d19750c9b30b1e538c4077a8e48`
was integrated. Its independent Galileo verification adds no production
application code. Both reviews and scenario records were retained, and generated
coverage was regenerated. The native run and full suite remain attached to their
captured `f4de549a`-based source. Combined focused checks and final governance gates
complete integration verification without relabeling that earlier native result.

The combined Enrico and introduced Galileo ordinary tests passed **6 (3
properties, 3 tests)**, seed `17010`, 26.5 seconds. That invocation excluded eight
distributed tests by the repository default. The explicit `--include distributed`
run then passed **8**, seed `17011`, 10.5 seconds: all six Enrico and both Galileo
schedules. Both commands exited zero; independent process checks found their
peers absent. The database audit found zero users, repositories, mirror events
and jobs, Galileo integrations and peer tokens, VMs, hosts, fixture gate triggers
and functions, or other sessions.

An overlapping type check failed because the test alias rebuilt a consolidated
beam despite `--no-compile`. This was a tooling overlap, not a type finding; the
test run was drained before the sequential forced type retry. All-file prek and
the contract adapter, coverage and 19 checker regression tests passed. An earlier
mistyped contract command named a nonexistent script; the actual documented Node
adapter was then run successfully.

The sequential forced `MIX_ENV=test` Dialyzer retry passed with **zero errors,
zero skips and zero unnecessary skips**, 59.75 seconds after its PLT check. The
owner command exited zero. Final comparison against captured tree `89e03703`
found identical Enrico production code, generated/distributed tests and helpers,
and native Git fixture. The integration adds the already published Galileo tests
and evidence without changing that executed implementation. ADR, generated
options/coverage and Ash/deployment view checks passed on the combined source.

## Remaining scope

The accepted ADR remains partial. Independent physical hosts/tunnel acceptance,
100 GiB cache pressure, large-repository duration, physical authenticators and
production rollout remain separate. The finite browser test does not verify
every Git view or arbitrary repository content; source-outage preservation and
force-push retention retain the older service machine's exact scope. Distributed
ordering tests use synthetic service replies, not a network-partitioned Git
provider. No native transport claim comes from generated or database tests.
