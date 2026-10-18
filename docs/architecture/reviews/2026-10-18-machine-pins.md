# Machine pins architecture review

## Decision and scope

[ADR-0193](../decisions/0193-per-user-machine-pins.md) adds per-user machine
pins, a pinned-first ordering for the machines page and overview, an
owner-pin deletion guard in the lifecycle coordinator, pin removal at VM
archival, and Porsche `pin`/`unpin` commands. The change touches persistence
(a new Access resource and migration), authorization (a new public generic
action pair and internal action allowlist entries), the lifecycle admission
path and the shared protocol command catalog, so it is a substantive review.
The removal of the VS Code "create a new machine" advice is presentation only
and stays within ADR-0161.

## Source and authority reviewed

- **Domain boundary.** `Marshall.Access.Pin` lives in the Access domain beside
  grants; it carries no authority. Cedar is not consulted for pin rows; the
  coordinator reuses `Authorization.live_vm!/5` for the read decision, so a pin
  cannot substitute for a grant. A durable pin can outlive revoked access so its
  holder can still unpin; authorized views recheck access before projecting the
  machine. Non-user actors project an empty pinned set (Covenant I6).
- **Coordination.** `Pins.pin!/2` takes a per-user advisory transaction lock,
  then the VM row lock (`live_vm!` with `lock: true`), then the locked pin
  row. Lifecycle takes its request advisory lock, host locks, then the VM
  lock, and reads pins under it. Neither path takes the other's advisory key
  and pins never take host locks, so no lock cycle exists. The cap is counted
  under the user lock, so two concurrent pins cannot both pass at 19.
- **Deletion guard.** `admit_delete_with_pins!/2` runs after the existing
  `vm_deleted` check and before intent changes; a refusal rolls back the whole
  transaction, so no operation, generation or receipt is written. The account
  deletion exception archives only the owner's own pins (`remove_for_user_vm!`),
  leaving other holders' pins for the archive step.
- **Archival.** Both archive sites remove pins immediately before
  `Ledger.archive!(vm, :archive)` within the same transaction; the Hegel
  guard property checks no live pin survives the deleted outcome.
- **Views.** The pinned section applies the same per-row `allowed?/3` check
  and the same `view/2` projection; `exclude` is validated as at most 20
  UUIDs by the Ash action, matching the cap. The SSH wire view drops
  `pinned`, so `ls`/`show` field sets are unchanged (asserted in
  `commands_test.exs`).
- **Protocol and Porsche.** `pin`/`unpin` are non-physical mutations, so
  Porsche's runner neither polls nor waits; `rm` keeps its physical semantics.
  `machine_pinned` and `pin_limit` join the closed 409 set and Porsche's
  refined reasons; the `porsche-closed-conflict-reasons` contract prose was
  updated to name them. The hint text is fixed and carries no remote text.
- **Events.** Three catalogued events with `vm_id`/`reason` metadata only,
  emitted after the outer commit; the diagnostics trace schema was regenerated
  so the new reason atoms validate.

## Verification and remaining gaps

The incoming change reports checks in its task summary
(targeted Marshall tests with `--max-cases 4`, Marshall/Porsche/protocol
gates, the Lilly consumer compile and Dialyzer for the protocol change, ADR,
HLDD, conflict-marker and trace-schema checks). Evidence is BEAM-level: the
Hegel guard history drives the real domain action and the real SSH command
path against local PostgreSQL; LiveView tests cover the toggles, ordering and
the disabled Delete; the browser probe covers presentation on both themes.
Those imported reports have no exact execution receipt linked here. They do
not establish this integration checkout's passing gates; source-present
scenario evidence remains `present`, and final merged-source consumer checks
retain separate execution records.

The final frozen integration at `132bc28b5` subsequently passed the complete
Marshall gate: **1,712 passed, four excluded**, seed **576982**, Covenant
**27/27**, and forced Dialyzer with zero errors, skipped or unnecessary skips.
The pin property, unit, LiveView and SSH tests passed in that execution;
their modules contain no excluded distributed, host or capacity tags. The
[matrix review](2026-10-18-guest-os-matrix.md) records its exact frozen source
ledger and log digest. The final protocol gate also passed 303 tests;
Lilly's final gate passed 610 tests with Covenant15/15 and Porsche's passed
100 tests with Covenant4/4, both with zero-error forced Dialyzer and unchanged
runtime sources. Porsche's closed pin-refusal tests passed in that execution.
These results support the
recorded BEAM evidence without closing the native or cross-node gaps below.

Gaps: no NixOS machine test exercises a pin over a live Porsche SSH session or
in the packaged browser; cross-node pin/delete races are argued from the shared
VM row lock rather than observed; team-admin pinning is an open question.

## Affected decisions

- ADR-0193: new, accepted, implementation partial.
- ADR-0046, ADR-0074, ADR-0018/0175, ADR-0117, ADR-0161, ADR-0042: unchanged
  rationale and status; referenced as the authorities this change extends.

## OS matrix integration review

The integration preserves the exact Alma resolver/identity construction,
Arch root policy, native admission and completed Windows publication evidence
from the [guest matrix review](2026-10-18-guest-os-matrix.md). The new pin
resource is present in the generated Access ownership inventory; deployment
host/service placement is unchanged. The account-deletion exception, revoked
holder unpin and owner-only deletion fence remain explicit in the combined
handbook and scenario ledger. ADR-0193 remains accepted/partial.

The full current-Hegel Marshall run in the earlier checkout passed 1,694 tests,
Covenant 24/24 and zero-error forced Dialyzer, but excludes the pin
implementation and tests. Its result cannot verify this merged source;
protocol, Marshall, Lilly and Porsche checks must use the final integration.

An actual Chromium check found that wrapping the added machine-list pin control
accumulated vertical drift: the inherited `gap: 1ch` used 9.60002 px on both
axes against a 9.625 px half-line, eventually exceeding the unchanged 0.1 px
grid tolerance. The narrow correction uses a half-line row gap and retains
the one-character column gap. An on-page comparison removed the exact editor
and pin offenders at 1,440 and 1,000 px; asset, Monospace structural and
TypeScript/presentation gates passed. Full browser execution and its retained
failures have separate records in the matrix review. This preserves ADR-0161
and changes no template hooks, protocol, authorization or pin semantics.
