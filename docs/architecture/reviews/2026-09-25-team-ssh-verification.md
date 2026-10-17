# Teams SSH verification

## Scope and architecture impact

Campaign improvement 008 implements ADR-0046's durable SSH receipt boundary and
ADR-0077's Teams authority through the actual SSH HTTP interface and packaged
Porsche. These decisions remain accepted; ADR-0077 remains partial. No production
protocol vocabulary, domain ownership, deployment placement or guest authority
changes. User authorization covers verification fixes, isolated native tests and
incremental delivery. No production acceptance is performed.

## Findings and corrections

- A foreign active-name collision returned HTTP 503 `temporarily_unavailable`
  although the Teams coordinator correctly refused creation. The generated HTTP
  history reproduced this with seed `44008`, before any production correction.
  It now returns the existing HTTP 409 `conflict` response, which Porsche reports
  with exit 2. Pending or terminal transfer conflicts use the same category.
- Unknown transfer references were also unavailable: direct coordinator atom
  refusals passed through raw `Repo.rollback` and lost their typed reason in Ash.
  `Commands.unwrap!` now preserves atom refusals through the typed Ledger helper.
  Unknown team/transfer references return 404 `not_found`; absent membership and
  foreign authority return 403 `forbidden`. Responses contain no object details.
  Names are already globally unique; these categories do not confer authority.
- The existing transition rescue converted arbitrary exceptions to
  `invalid_transition`. Only the exact state-machine no-matching-transition
  exception now receives that permanent classification. Unexpected exceptions
  retain opaque unavailable handling and never expose database errors.
- Uppercase and malformed team names reached persistence validation and returned
  503. Public creation arguments and the stored attribute now reuse the same
  explicit name constraints. Only the create action's sole invalid-name argument
  error is converted to `invalid_request`; other Ash errors are preserved.

## Verification design

[HTTP properties](../../../marshall/test/marshall_web/teams_ssh_api_test.exs)
exercise a decisive sequence in every history plus generated replay, conflict,
missing-reference and changed-input suffixes. Full row inventories include active
and archived Teams, memberships, transfers, their versions, administrative audits
and durable SSH requests. Refusals and historical replays must change nothing;
a safe creator retry with a fresh request ID may append only its request receipt.
Transfer and removal are real HTTP commands. Trusted archival is explicitly a
fixture transition because no public archival command exists: a later accepted
creation gets a new identity while the original receipt remains pinned and cannot
restore membership. Separate generated name cases cover grammar and length bounds.
A synthetic audit-write failure exercises rollback and opaque 503 classification.

The [two-VM native driver](../../../nix/tests/machines/team-ssh/driver.py) uses
source-built Marshall and packaged Porsche, verified internal HTTPS and strict
OpenSSH host trust from an operator-read key. A completed bootstrap latch and a
separate unused administrator keep the three tested identities ordinary; the
stored flags are asserted before login, after identity proof and after mutations.
All tested team actions enter through the CLI. Full durable inventories, request
status, stable exit codes, current owner, audit and version counts are observed.
The fixture performs no guest provisioning or public network requests. Unexpected
CLI replies are projected through object-boundary validators; failure diagnostics
never contain response maps or raw bytes. A bounded onboarding-shaped response
checks formatted exception output for bearer URL leakage. The composed driver
keeps NixOS framework type checking enabled; an initial nested-dictionary typing
failure was corrected before execution.

## Execution

Focused HTTP and existing API tests passed **16 checks (2 properties, 14 tests)**,
seed `44008`, in 9.6 seconds. This includes malformed-name boundaries and a
synthetic PostgreSQL audit-write exception: its response remains opaque 503,
complete durable inventories are unchanged, and the same operation succeeds
after the fault is removed. Initial fixture table-name mistakes and an overlapping
local compilation failure were corrected; neither is counted as acceptance.
The complete candidate Marshall test suite on base `00343832` passed **1,029
checks (94 properties, 935 tests), with two separate exclusions**, seed `107122`,
in 340.9 seconds. Forced Dialyzer rebuilt its relocated dependency PLT, then passed application
analysis in 53.86 seconds with zero errors, zero skips and zero unnecessary skips.
The complete `mix precommit` command exited successfully.

The native `team-ssh` check passed in **60.61 seconds**, followed by 0.39 seconds
of VM cleanup; the Nix build exited zero. The composed framework type and lint
checks passed with both gates enabled.

- Test derivation: `/nix/store/p9qkmps56bmnjk5wyvxclksc7zfv7g9i-vm-test-run-kittens-team-ssh.drv`.
- Result: `/nix/store/6ihprd0pkaqskmxf5jwdcg7zv8h78gb1-vm-test-run-kittens-team-ssh`.
- Typed driver: `/nix/store/1nvb8yi844rblpi824i88zsx3j1wz0kv-nixos-test-driver-kittens-team-ssh`.

This captured artifact includes the final production fixes, name constraints,
redacted failure diagnostics and canonical UUID validation. Subsequent evidence
prose and scenario receipts do not represent a rerun of the packaged source.
All repository prek hooks, including ruff format, ruff check and ty, passed.
ADR, HLDD, generated options/coverage/views and Nix `hldd` checks passed on the
candidate; final evidence updates receive the same structural gates.

## Published-main integration

Candidate `115c39e6` was integrated with published main
`dce76fbb87fd97c5b52385e44d8c9955ac83418d`. The Customer sharing 403 mapping
and Teams 409/404/403 mappings coexist without manual production changes.
The final combined `mix precommit` passed **1,032 checks (96 properties,
936 tests), with two separate exclusions**, seed `496403`, in 260.4 seconds.
Forced Dialyzer passed in 54.62 seconds with zero errors, zero skips and zero
unnecessary skips. The original native artifact keeps its captured scope;
006's separate recorded guest fixture does not establish Teams guest access.

## Final contract review

The final diff preserves current authority and atomic pinned receipts. Reviewed
shared unwrap call sites, Teams creation/transfer consumers, SSHAPI and Porsche
client/runner classification; no contract violations remain in this scope.
The known refusal mapping is closed, invalid-name validation stays at its typed
Ash action, and unrelated exceptions retain opaque transport handling. No schema,
protocol dependency, deployment topology or new architectural decision is needed.

## Remaining limits

Native team-owned VM/integration access, transfer/retirement overlap across
independent Marshall replicas, and public archival remain separate gaps. SQL
sandbox histories do not prove committed multi-node races. The native fixture is
two NixOS machines on one physical test host, with one serving Marshall replica.
