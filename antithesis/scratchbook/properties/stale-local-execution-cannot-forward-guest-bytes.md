# stale-local-execution-cannot-forward-guest-bytes

Priority: P0. Confidence: high in the intended fence, medium in composed workload feasibility; no new hosted run. Type: safety, with a fresh-execution progress witness.

## Guarantee and proposed assertions

After Lilly withdraws local authority for a placement/epoch/generation and its old ingress guardian ends, a previously opened Audi→Lilly stream cannot deliver any *new* bytes to that old execution; a new connection for a different execution must use the current physical boot and exact binding. Proposed `Always(no_post_fence_old_execution_effect, "Retired local execution cannot receive new Audi guest bytes")` using a nonce sent after the guardian-death barrier and a guest-side physical boot recorder. Proposed `Sometimes(current_execution_nonce_observed, "Current local execution receives guest bytes after fencing predecessor")` is a semantic progress check. Both are missing in `../existing-assertions.md`. Existing in-flight bytes before the fence are excluded. A Marshall commit precedes Lilly's local adoption and is not by itself an immediate stream cutoff; neither a Control acknowledgement nor a closed client socket proves physical guest identity.

## Source and decision trail

- `audi/CONTRACTS:5-7` requires current local placement and execution epoch through Lilly's restricted connector. `marshall/lib/marshall/ingress/execution.ex:7-13,14-53` checks gateway service, current host session, placement, epoch, generation, running evidence and completed start/provision under locks.
- `lilly/lib/lilly/ingress/server.ex:181-200,203-235,252-285` authenticates the Audi peer UID, opens a backend/guardian before relay and stops pumping when its guardian dies. `lilly/lib/lilly/ingress/backend.ex:5-29` selects executor context from the current actor and refuses when the guardian dies.
- `lilly/lib/lilly/ingress/guardian.ex:4-8,31-75,79-95` repeatedly resolves exact Runtime/actor authority with an independent 1,500 ms probe deadline. `lilly/lib/lilly/private/server.ex:183-199,210-262` separately subscribes pre-NAT source identity and withdraws a changed private binding. The private subscription is an additional identity path, not a substitute for the ingress data-stream guardian.
- ADR-0052 (`docs/architecture/decisions/0052-fenced-local-guest-ingress.md:21-35,69-78`) originated the local fenced-stream rule; it is superseded, with the rule carried forward through ADR-0054 (`docs/architecture/decisions/0054-inception-development-profile.md:22-26`) and subsequent decisions. ADR-0155 limits current relocation to stopped full copy; this property can use stop/start or relocation only after the corresponding committed execution transition. Decision text and source contracts are claims to test.

## Fault history, independent effect and progress witness

Create an owned synthetic VM with guest recorder A; admit a private stream through Audi and prove nonce A1 arrived at the physical guest boot ID. Execute stop/restart or stopped-only relocation through real Marshall/Lilly intent. Reconcile uncertain Control replies to the committed operation and wait for Lilly to adopt the changed local execution view, then independently observe the old guardian's termination. Keep the old socket/client object, perturb View/Runtime/actor supervision in actual order, drop hints and queue connector traffic. Send a new nonce A2 on the *old* stream after the guardian-death barrier. The guest recorder bound to old boot must never receive A2. Admit a fresh stream for the current execution and require nonce B1 at that execution's physical boot ID. Read Lilly Store/journal and physical guest process identity to classify which execution produced each effect. An API refusal, closed socket, or missing log is not the effect witness.

Value menu: stop/start same placement versus stopped relocation; epoch change versus generation-only restart; connector opened before/after fence; old socket idle/under backpressure; Runtime/View/actor restart in actual application supervision order; old/new guest process alive/dead. Never substitute a fake View row for retained physical custody. Add SUT-side replay markers at `Lilly.Ingress.Guardian.probe/2` for changed authority and `Lilly.Ingress.Server.pump/3` for guardian DOWN, with fixed IDs and no payload; these are guidance, while the guest recorder is oracle. Hosted real service plus TCG guest can establish software-emulated guest behavior. Firecracker jail/cgroup and native relocation require a separate machine campaign.

## Open Questions

- How can the workload correlate one old client stream with Lilly's observed guardian DOWN and closed relay before injecting a new nonce? `(partial: server monitors guardian and stops pumping on DOWN, but exposes no external per-stream death receipt)`
- Can hosted TCG retain independently identifiable old and current boot recorders while preserving the actual stop/restart or stopped relocation semantics? `(partial: the topology proposes one retained overlay/boot observer, but no composed two-boot recorder fixture exists)`

### Investigation Log

#### What forms the safe old-execution fence barrier?

- Examined: `marshall/lib/marshall/compute/lifecycle.ex:69-123,226-244`, `relocation_coordinator.ex:174-225`, `lilly/lib/lilly/control/runtime.ex:25-52`, `lilly/lib/lilly/ingress/guardian.ex:31-95`, and `lilly/lib/lilly/ingress/server.ex:260-285`.
- Found: Marshall commits a changed generation or placement/epoch first. Lilly ingress checks its current local view, and the guardian exits after it detects changed/absent authority or its independent probe timer expires. The server monitors that guardian and stops relay on DOWN. Thus the immediate post-Marshall-commit boundary is too strong; guardian death after local withdrawal is the safe byte-effect barrier.
- Not found: an existing external harness observation of the exact per-stream guardian death. A future workload may need a bounded, non-sensitive SUT checkpoint or process monitor paired with the guest recorder.
- Conclusion: property narrowed; the remaining harness observation question is partial, not a product-policy question.

#### 2026-10-13 follow-up: How can the workload observe guardian death for its old stream?

- Examined: `lilly/lib/lilly/ingress/guardian.ex:10-95`, `lilly/lib/lilly/ingress/server.ex:203-285`, `audi/lib/audi/http/proxy.ex:82-140`, and Lilly's ingress event catalog.
- Found: the server starts and monitors the guardian before relay; `pump/3` exits on guardian DOWN, then its socket close ends the old relay. There is no catalogued event carrying a per-stream guardian-death receipt. A test-only, bounded monitor of the actual server/guardian pair could acknowledge the DOWN and relay close; a closed client socket alone is only a secondary symptom. Send the probe nonce after the monitor barrier, and read the old guest recorder independently.
- Not found: an existing external API mapping a client handle to the exact guardian PID and DOWN signal.
- Conclusion: partial harness observation. Withdrawal plus guardian death and relay close are the relevant causal barrier; Marshall commit alone is earlier than that barrier.

#### Can TCG retain distinguishable old and new boot recorders?

- Examined: `../deployment-topology.md` guest-vmm design and the stop/restart versus stopped-relocation scenario in this evidence file.
- Found: the proposed TCG executor keeps an overlay and records QEMU/backend/boot identity, which can distinguish sequential boots. A single old guest process is normally stopped before the next boot; the old recorder must be persisted outside that process (for example on its retained guest disk or in a separate owned recorder) and read after the new boot. Keeping two simultaneously live guests would alter the stopped-only relocation contract.
- Not found: an assembled TCG fixture with an external old-boot ledger and verified retained client handle.
- Conclusion: partial. Require sequential physical boot IDs and a durable old-effect ledger; do not simulate two live owners to make the probe easier.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: post-fence guest nonce and current authority/lease/boot ledger; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
