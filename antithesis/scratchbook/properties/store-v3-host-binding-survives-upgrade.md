# store-v3-host-binding-survives-upgrade

P0; high confidence; safety. Planned `Always` message: **"Lilly Store v3 refuses foreign or changed host binding without reinterpretation"**. Restarting Runtime with a state directory whose persistent `identity.json` is bound to another host or Store format must fail before actor execution and leave every prior command file byte-for-byte intact. This is **Store v3**, distinct from Execution wire v4 and Control envelope v1. The [fresh assertion scan](../existing-assertions.md) finds this SDK assertion **missing**. `Always` applies to every completed startup attempt and file inventory.

Source: `lilly/lib/lilly/control/store.ex:11-26,75-101,122-148` checks exact host/version binding and each command's version/host/placement before use; `:32-56` preserves command identity and epoch/generation monotonicity. `lilly/lib/lilly/control/runtime.ex:148-170,231-251` acquires host/state ownership and runs migrations only after binding. `lilly/lib/lilly/control/profile_rename.ex:1-46,112-165` rewrites only retired `antithesis` profile fields to `standard` under host/pool ownership, preserving other JSON values and lifecycle identity. An unsupported v4 wire response cannot silently convert receipt-only v3 state into execution authority. This source contract is not a proven crash-safe guarantee. Additional optional-path `AlwaysOrUnreachable` message: **"Bound profile rename preserves placement identity after Store v3 binding"**; the legacy record may be absent, but every reached rewrite must retain VM, placement, epoch and generation.

Workload and oracle: snapshot exact owner/identity/command file digests and a physical VMM inventory, stop Runtime through its supervisor, attempt restart with another host UUID, Store format 2/4, and corrupted per-command version; check startup refusal, unchanged file hashes and no new launch. Then restore the valid binding, restart the real Runtime, and verify the original placement/generation remains readable and reconciles. In a separate legacy-state fixture with valid binding, run the profile rename and compare parsed field-by-field records to the pre-migration ledger: only `profile` spelling changes, current identity and archive bytes remain stable. A failed binding is a permanent configuration/data refusal; an I/O error is uncertain and should be separately classified. `Reachable` **"Lilly Store v3 reopened exact host-bound command after compatible restart"** is the meaningful positive path.

Value menu: fresh/existing state directory; same/foreign host; binding version 2/3/4/missing; command version 2/3/4/corrupt; legacy/current/mixed profile names in live and tombstone records; exact duplicate/stale/new generation; stop before/after command sync; one/two placements. Hosted Linux with real Runtime/files/locks covers format and refusal. Physical VMM continuity and ZFS claim migration require native execution. Open question: which failure-injection seam permits changing the configured host/version between complete Runtime lifetimes while retaining the same physical state directory and ownership requirements?

Status: `(partial: Retain complete-lifetime ownership/config seam partial; local Store.open refusal remains source-backed)`

Next probe: Runtime accepts Config in start options and acquires host ownership before Store.open, but passes Store version 3 as a literal. A whole-root stop/restart with a different configured host can probe host binding. To probe version refusal, alter only the persisted identity version while ownership is released; there is no Runtime version switch. Compare raw file hashes after each refusal.

### Investigation Log

#### Which seam changes host/version across complete Runtime lifetimes while retaining real ownership?

- Examined: `lilly/lib/lilly/control/runtime.ex:149-170,231-251,791-815; lilly/lib/lilly/control/store.ex:11-26,75-101; lilly/lib/lilly/application.ex:14-57`.
- Found: Runtime accepts Config in start options and acquires host ownership before Store.open, but passes Store version 3 as a literal. A whole-root stop/restart with a different configured host can probe host binding. To probe version refusal, alter only the persisted identity version while ownership is released; there is no Runtime version switch. Compare raw file hashes after each refusal.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: partial; Retain complete-lifetime ownership/config seam partial; local Store.open refusal remains source-backed.Open questions:

- Which seam changes host/version across complete Runtime lifetimes while retaining real ownership? `(partial: Runtime fixes Store v3; full-root host rebinding fixture unproven)`

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger; current measured ZFS pool required for accepted placement. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R2`: The focused command must also emit a distinct `Reachable` at the actual incompatible/corrupt/restart/negative-status danger branch. Optional-path safety can pass without that branch; positive compatible traffic is insufficient. `R4`: Keep exhaustive fixed decoder/version/migration matrices in ordinary tests. In Antithesis, race representative invalid input with a real restart, authority change or valid effect and observe the independent outcome. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
