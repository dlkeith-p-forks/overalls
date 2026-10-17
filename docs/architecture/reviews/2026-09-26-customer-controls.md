# Customer owner controls and entry refusals verification

## Scope and architecture assessment

Improvement 102 began at published `c14ae27d`. The worktree additionally carries
`40c1e73b`'s one-line restoration of the `executorLoss` fleet parameter dropped
by the 020 merge (any fleet variant failed evaluation without it; identical
text, to be dropped by the rebase that pulls `40c1e73b`). Dedicated branch
`verify/102-customer-controls`.

No architecture impact: verification-only change. ADR-0046 (Porsche management
entries), ADR-0051/0053 (resize scope; no SSH resize), ADR-0069 (profile
capability policy) and ADR-0103 (current-authority evidence rules) are
unchanged. No production code, protocol, permission, schema, dependency or
deployment behavior changed; the diff touches tests, two fixture operators,
handbook evidence text and one fleet argument-list restoration.

## What was added

1. `marshall/test/marshall/ssh/commands_test.exs` — generated property driving
   real `SSH.execute` start/stop/rm histories across profiles `{oss, customer}`
   and actors `{owner, manager, revoked member, stranger, administrator}` with
   a complete durable inventory oracle (VMs/versions, placements, reservations,
   operations, physical outcomes, network addresses, SSH receipts, grant
   versions/changes, admin audit): refusals leave every table byte-identical,
   enqueue nothing and record no receipt; accepted commands add exactly one
   operation, receipt and dispatch; identical replays return the pinned
   receipt; changed-kind key reuse surfaces `idempotency_conflict` without
   durable work; settled deletion keeps history owner-pinned across archival
   and name reuse. Plus a fixed regression test for archived Customer receipt
   pinning and non-rebinding.
2. `marshall/test/marshall_web/machines_live_test.exs` — pins browser power-key
   semantics on Customer machines: a refused start leaves its key reusable
   (the refused intent persisted nothing) and the same key with a different
   kind submits fresh intent exactly once; an accepted key reused with a
   changed kind surfaces a conflict flash and enqueues nothing; member,
   stranger and elevated-administrator direct detail URLs redirect to
   `/machines` with each route's fixed notice (`Machine not found.` on the
   terminal route).
3. `marshall/test/marshall/access/customer_isolation_test.exs` — a real
   elevated administrator actor is refused Customer reads and lifecycle with
   zero new operation rows while successfully stop/start-managing an OSS
   control machine.
4. Native: `nix/verification/tests/machines/default-oss/driver.py` — owner Porsche CLI
   stop/start/rm on the real Customer guest with receipt replay (`request show`
   and same-command replay return the pinned operation), real Firecracker
   process/cgroup death and recreation around the retained ZFS dataset
   identity, reservation settle checks, member/stranger CLI refusals
   (forbidden/not_found) with unchanged intent inventories that persist across
   a fixture-promoted administrator flag, a member browser member-page refusal
   through a fresh magic-link login, and Customer egress re-probe after the
   real CLI restart. `operator.exs` gained only the sentinel-fenced
   `customer-promote-admin` fixture action; `nix/verification/tests/README.md` documents the
   extended scope; the `defaultOssBrowser` artifact covers `browser.py` typing.

## Suspected defect verdicts

1. **`commands.ex` receipt/2 after archived-VM deletion** — NOT reproduced;
   documented boundary. `Ledger.history!` + `require!(read)` keep archived
   receipts readable to the accepting owner, pinned to the deleted VM, refusing
   member/stranger/admin, with no rebinding to a name-reused successor. Pinned
   at property end-state and by the fixed regression test; also exercised
   natively after physical deletion.
2. **MachinesLive lifecycle key only rotates on success** — NOT reproduced;
   pinned. Because refusals roll back completely, key reuse with a different
   kind submits exactly one fresh operation (no false conflict); with an
   accepted key, changed kinds surface `idempotency_conflict` and enqueue
   nothing through either power entry.
3. **Resize exclusion of delete for Customer** — NOT reproduced. The existing
   four-profile `resize_history_test.exs` loop already refuses
   start/stop/delete during active resize; mutant M3 below confirms the
   exclusion is load-bearing.
4. **fleet-op fixture authority blindness** — fixed for the Customer leg by
   replacing privileged fleet-op lifecycle/restart calls with real entries
   (Porsche CLI + real browser member page). The legacy
   `customer-isolation-fleet` journey keeps its previously recorded scope and
   is untouched.

## Execution record

- Focused suites (`MIX_TEST_PARTITION=verify102`, `ERL_FLAGS="+S 6:6"`):
  - `mix test test/marshall/ssh/commands_test.exs`: **21 checks (3 properties, 18 tests), seed 0** — pass.
  - `mix test test/marshall_web/machines_live_test.exs`: **28 tests, seed 0** — pass.
  - `mix test test/marshall/access/customer_isolation_test.exs`: **5 checks (2 properties, 3 tests), seed 0** — pass.
  - Combined three-file run: 54 checks (5 properties, 49 tests), seed 22337 — pass.
- `nix build .#checks.x86_64-linux.default-oss-creation.defaultOssBrowser` →
  `/nix/store/8352qagnp2lfv7sll8xaaiswhss9v29q-default-oss-browser-typed` (4 s).
- Native `default-oss-creation` under the campaign HEAVY lock: drv
  `/nix/store/pij0g1wm6g6yjrph9cpbd5mn7gkp6q6p-vm-test-run-kittens-default-oss-creation.drv`,
  output `/nix/store/85j44gam1pr1f1qs2hr1z0az2b32b6bv-vm-test-run-kittens-default-oss-creation`,
  script 427.63 s, cleanup 2.98 s, nix wrapper 479 s, and
  native default-OSS journey passed in 427.63 seconds.
  The four new/extended subtests ran
  23.87 s (owner CLI lifecycle + receipts + real recreation), 11.25 s (CLI
  refusal matrix + promotion), 8.63 s (browser member refusal), 16.21 s (CLI
  removal + archived receipt pinning). Two earlier attempts failed at the
  browser member-page step (809 s and 768 s): first run's flash assertion was
  the wrong fixed text for the terminal route, which is asserted as a
  per-route regression in the LiveView suite; both failures left no fixture
  residue.

## Mutant table

| Mutant | Injection | Detector | Result |
| --- | --- | --- | --- |
| M1 profile conjunct drop | `Access.Authorization.allowed?/3` drops `(owner_id == actor.id or allows?(:sharing))` | `customer_isolation_test.exs` both admin tests failed (incl. the new elevated-admin lifecycle test); Cedar grant construction independently kept member/stranger refusals inside the generated property | DETECTED; reverted; suite re-green |
| M2 receipt without re-authorization | `commands.ex` `receipt/2` `require!` replaced with `:ok` | existing commands_test "revoked members cannot poll old work" failed | DETECTED; reverted |
| M3 resize busy drop | `Lifecycle` removal of the `Resize.busy?` guard | `resize_history_test.exs` lifecycle-exclusion loop failed | DETECTED; reverted |

A surviving mutant would itself be a finding; none survived the covered
assertions noted above. The M1 property-level survival for member/stranger
CLI rows is the intended defense-in-depth of the profile-filtered Cedar
entity, not an undetected mutation: the administrator bypass it unlocks is
caught by the isolation suite.

## Full-gate record

- Marshall `mix precommit`: FILL (checks, properties/tests, seed, Dialyzer).
- Governance: `check_adrs.exs` passed (124 decisions); `check_hldd.exs`,
  `hldd_coverage.exs --check`, `hldd_views.exs --check`, `hldd_options.exs
  --check`, `prek run --all-files`, `nix build .#checks.x86_64-linux.hldd`:
  FILL.

## Remaining gaps

- Customer guest SSH/terminal interactive journeys, packet/tool matrices and
  Ubuntu guests keep separate acceptance tracks; the property and native legs
  bound this change's scope.
- Browser member-page refusal is native for the member; stranger/admin browser
  entries are covered at LiveView level only.
- `customer-isolation-fleet` keeps its historical recorded scope and was not
  rerun.
- A failing generated history leaves shared-sandbox residue that masks later
  redraws in that property execution; green runs leave audited intent tables
  empty. Distributed three-node Customer lifecycle stories remain with the
  existing distributed suites.

## Coordinator integration scope

FILL after rebase onto current main: final commit ids and integrated checks.
