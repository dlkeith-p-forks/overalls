# lilly-async-result-keeps-command-identity

P0; high confidence; safety. Planned `Always` message: **"Lilly asynchronous result retains its original command generation"**. A completion for command `(placement, epoch, generation)` must never publish a newer command's live row, capacity proof or outcome; after a committed replacement, only a reconcile of that replacement may establish its proof. Check the durable Store and Journal beside published Execution rows and physical effect receipts. The [fresh assertion scan](../existing-assertions.md) marks every proposed SDK call **missing**. `Always` fits each observed completion and settled exchange.

Source: `lilly/lib/lilly/vm/actor.ex:222-242` binds task result to `task_command`, rereads Store, and discards a superseded result. `:272-312` writes the attempted identity before starting one executor task; `:345-385` records outcome; `:463-480` binds capacity proof to an exact outcome. `lilly/lib/lilly/execution.ex:64-75,106-117` publishes and joins exact command rows. The source contract claims behavior; it does not prove a composed race always closes.

Workload and independent oracle: pause a real actor's executor after attempt persistence, commit a newer start/stop/delete generation via Runtime, then release the old executor completion amid actor restart and control exchange. Record workload-issued command identities and an independent physical-effect marker; read Store and Journal on disk and subscribe to the real Execution/Control output. A stale physical effect may need later cleanup, but it cannot be relabeled as newer authority. A timed-out control call is unproven until Store is reread. SUT `Reachable` message **"Lilly discarded superseded asynchronous executor result"** is a useful replay anchor at `Actor.handle_info/2`'s newer-command branch.

Value menu: same epoch newer generation versus newer epoch; start/stop/delete; old result running/stopped/retry; complete before/after new Store commit; actor death before/after result; one versus two overlapping Control exchanges. Hosted real Runtime/Store/actor with a lower executor seam can establish identity handling, while physical Firecracker/ZFS outcomes need native machinery. Open questions: None.

Answer: The existing ActorTest executor reports the command and Task PID to the test owner, then waits for a release message. Tests commit a replacement while the old reconcile task remains held and assert only the replacement generation is published. This preserves the production Actor Task and journal path, though the executor is a test double and establishes no native effect.

### Investigation Log

#### Which existing executor pause seam preserves production actor/journal timing?

- Examined: `lilly/test/vm/actor_test.exs:10-28,434-470; lilly/lib/lilly/vm/actor.ex:222-242,272-312`.
- Found: The existing ActorTest executor reports the command and Task PID to the test owner, then waits for a release message. Tests commit a replacement while the old reconcile task remains held and assert only the replacement generation is published. This preserves the production Actor Task and journal path, though the executor is a test double and establishes no native effect.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: resolved; Remove pause-seam question; cite actor test as model-level schedule only.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: caller key/committed rows correlated with exact physical boot, disk or capacity sample; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
