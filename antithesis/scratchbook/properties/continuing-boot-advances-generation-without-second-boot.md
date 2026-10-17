# continuing-boot-advances-generation-without-second-boot

P0; high confidence; safety. Proposed `Always` message **"Logical generation adoption retains one physical boot and fences old delivery"**. Instrumentation is **missing** per [fresh scan](../existing-assertions.md). Host connection epoch, VM execution epoch, logical generation and physical boot challenge are four distinct identities.

Source: `lilly/lib/lilly/vm/boot.ex:64-86` advances journal generation only for a proved confined running VMM at the same placement/VM epoch and preserves challenge; `:95-120` requires exact current intent for authority. `lilly/lib/lilly/vm/driver.ex:1222-1245` uses adoption before readiness; `:702-729` binds trust journal to generation plus boot. The guest trust wire receipt itself checks placement/VM epoch/challenge/nonce/digest (`lilly/lib/lilly/vm/guest_trust.ex:94-111`), while workspace delivery journal also binds logical generation and source digest (`lilly/lib/lilly/vm/workspace_source.ex:245-275`). `lilly/lib/lilly/vm/driver.ex:828-875` rechecks current authority around delivery. Existing `lilly/test/vm/boot_generation_adoption_property_test.exs:12-65` models journal histories but explicitly disclaims confined VMM proof. ADR-0157 covers the retained boot semantics.

History: boot a real guest, pause its trust/workspace reply, commit a newer running logical generation at the same placement/VM epoch, restart the actor or reconnect Control, and then deliver delayed old-generation replies. The VMM PID plus kernel start time and guest boot challenge must remain continuous; new journal generation becomes current, and old workspace delivery must not settle it. A valid trust receipt for the same physical boot must be interpreted through the current generation's trust journal rather than treated as proof of a new boot. Negative controls change placement/VM epoch or corrupt/miss boot state and require refusal rather than adoption.

Independent oracle: read native VMM identity from host process/cgroup evidence, guest boot challenge from the protected channel, persisted boot/intent and trust/workspace journals, plus actual guest workspace source/done state. Count physical VMM launches independently of operation or generation IDs. A `running` DB row or an old receipt alone is insufficient. Exactly one physical boot may correspond to multiple accepted logical generations in this case; a new VM epoch is outside this property.

SUT guidance: proposed `AlwaysOrUnreachable` **"Adopted generation preserved physical boot challenge"** at successful `Boot.adopt_generation/2`; proposed `Reachable` **"Delayed old-generation workspace receipt arrived after boot adoption"** anchors the race. Workload `Always` joins the physical VMM witness and current journals.

Values: generation delta 0/1/many within integer bounds; one/two actor restarts; trust reply before/after adoption; workspace reply old/current generation; same/foreign placement, same/new VM epoch; intact/missing/corrupt boot journal; guest readiness present/absent. Native TCG/host process evidence is needed for physical continuity. File/property tests establish journal logic only.

Open questions:

- Which native fixture can delay a guest workspace reply through a committed generation advance while retaining the VMM? `(partial: no native workspace reply barrier found)`

Next probe: Boot.adopt_generation and the property test preserve the journal boot challenge across a newer generation, but the inspected native fleet scenarios provide no guest workspace reply barrier. Probe a protected workspace-source reply delay while observing unchanged VMM PID/start time and guest boot ID, then commit generation N+1 and release N reply.

### Investigation Log

#### Which native fixture can delay a guest workspace reply through a committed generation advance while retaining the VMM?

- Examined: `lilly/lib/lilly/vm/boot.ex:64-86; lilly/lib/lilly/vm/driver.ex:776-875; lilly/test/vm/boot_generation_adoption_property_test.exs:12-65; nix/tests/machines/fleet/scenarios/user-ssh-journey.py:626-655`.
- Found: Boot.adopt_generation and the property test preserve the journal boot challenge across a newer generation, but the inspected native fleet scenarios provide no guest workspace reply barrier. Probe a protected workspace-source reply delay while observing unchanged VMM PID/start time and guest boot ID, then commit generation N+1 and release N reply.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: partial; Retain partial; separate journal adoption from a future native delayed-reply result.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: retained QEMU PID/boot challenge/overlay plus independent guest or connector effect; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
